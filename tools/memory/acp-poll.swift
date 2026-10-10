// ACP polling fixture: the real helper ACPConnection and app ACPModel, a fictional agent, no provider.
import Foundation
import VolantCore

@objc protocol ACPPollHost {
    func read(after revision: Int, legacy: Bool, reply: @escaping (Data?, Int, String?) -> Void)
}

/// The agent helper's ACP read, served over an in-process anonymous XPC connection. `legacy`
/// reproduces the read before revisions: the full state encoded on every poll.
final class ACPPollHelper: NSObject, ACPPollHost, NSXPCListenerDelegate {
    let acp: ACPConnection

    init(acp: ACPConnection) { self.acp = acp }

    func read(after revision: Int, legacy: Bool, reply: @escaping (Data?, Int, String?) -> Void) {
        acp.queue.async {
            if legacy { reply(try! JSONEncoder().encode(self.acp.state), -1, nil); return }
            let (data, current) = try! self.acp.snapshot(after: revision)
            reply(data, current, nil)
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ACPPollHost.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

/// Builds a fictional transcript through the helper's own ACP frame handling, then polls it the
/// way ACPModel does: a read over XPC, a hop to the main queue, and `ACPModel.receive`.
final class ACPPollFixture {
    let acp = ACPConnection()
    let model: ACPModel
    private static let suite = "com.mysticcoders.volant.memoryprofile.acp"
    private let helper: ACPPollHelper
    private let listener = NSXPCListener.anonymous()
    private let connection: NSXPCConnection
    private var lastRequest = 0
    private var chunks = 0
    /// Polls answered without data because the app already held the helper revision.
    private(set) var unchanged = 0

    init() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        model = ACPModel(resumeStore: UserDefaults(suiteName: Self.suite)!)
        helper = ACPPollHelper(acp: acp)
        listener.delegate = helper
        listener.resume()
        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: ACPPollHost.self)
        connection.resume()
        acp.testSend = { [unowned self] message in
            if message["method"] != nil, let id = message["id"] as? Int { self.lastRequest = id }
        }
        acp.queue.sync {
            acp.beginHandshake(project: "/tmp/volant-memory-fixture")
            acp.receive(Self.frame(["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": 1, "agentCapabilities": [:], "agentInfo": ["name": "Fixture agent"]]]))
            acp.receive(Self.frame(["jsonrpc": "2.0", "id": 2, "result": ["sessionId": "fixture-session"]]))
            precondition(acp.state.phase == "ready", "fixture session ready")
        }
    }

    static func frame(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object)
        data.append(10)
        return data
    }

    private func update(_ update: [String: Any]) {
        acp.receive(Self.frame(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "fixture-session", "update": update]]))
    }

    private static func text(_ label: String, bytes: Int) -> String {
        let sentence = " Fictional profiling sentence about a sample project and its tests."
        var text = label
        while text.utf8.count + sentence.utf8.count <= bytes { text += sentence }
        return text
    }

    /// Each turn is a ~150-byte prompt, a ~4.8 KB reply streamed in 1 KB chunks, and three tool
    /// calls that start pending and complete, as a coding agent reports them.
    func build(turns: Int) {
        acp.queue.sync {
            for turn in 0..<turns {
                beginTurn(turn)
                let reply = Self.text("Answer \(turn):", bytes: 4_800)
                var offset = reply.startIndex
                while offset < reply.endIndex {
                    let end = reply.index(offset, offsetBy: 1_000, limitedBy: reply.endIndex) ?? reply.endIndex
                    update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": String(reply[offset..<end])]])
                    offset = end
                }
                for tool in 0..<3 {
                    let id = "tool-\(turn)-\(tool)"
                    update(["sessionUpdate": "tool_call", "toolCallId": id, "title": "Read Sources/Fixture\(tool).swift", "kind": "read", "status": "pending",
                            "rawInput": ["path": "/tmp/volant-memory-fixture/Sources/Fixture\(tool).swift"]])
                    update(["sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed"])
                }
                finishTurn()
            }
        }
    }

    private func beginTurn(_ turn: Int) {
        try! acp.prompt(Self.text("Question \(turn):", bytes: 150))
        precondition(acp.state.phase == "working", "fixture turn started")
    }

    private func finishTurn() {
        acp.receive(Self.frame(["jsonrpc": "2.0", "id": lastRequest, "result": ["stopReason": "end_turn"]]))
        precondition(acp.state.phase == "ready", "fixture turn finished")
    }

    func startTurn() { uncounted { acp.queue.sync { beginTurn(10_000) } } }
    func endTurn() { uncounted { acp.queue.sync { finishTurn() } } }

    /// Four 48-byte chunks between polls, about 770 bytes a second at the 0.25 s poll interval.
    /// Feeding the helper is not counted; the poll that follows is.
    func stream() {
        uncounted {
            acp.queue.sync {
                for _ in 0..<4 {
                    chunks += 1
                    update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": String(format: "Streamed fixture chunk %05d with filler text.\n", chunks)]])
                }
            }
        }
    }

    /// One poll: what ACPModel.read sends, the helper's reply, and the main-queue receive.
    func round(legacy: Bool) {
        var done = false
        let proxy = connection.remoteObjectProxyWithErrorHandler { fatalError("Fixture XPC failed: \($0)") } as! ACPPollHost
        let known = legacy ? -1 : model.helperRevision
        proxy.read(after: known, legacy: legacy) { data, revision, error in
            DispatchQueue.main.async {
                let result = self.model.receive(data, revision: revision, after: known)
                precondition(error == nil && result != .invalid, "fixture snapshot applied")
                if result == .unchanged { self.unchanged += 1 }
                done = true
            }
        }
        while !done { _ = RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    func describe() -> String {
        let state = acp.queue.sync { acp.state }
        let text = state.messages.reduce(0) { $0 + $1.text.utf8.count }
        let tools = state.messages.filter { $0.role.hasPrefix("Tool") }.count
        let snapshot = (try? JSONEncoder().encode(state).count) ?? 0
        return "\(state.messages.count) messages, \(text) bytes of text, \(tools) tool entries, \(snapshot)-byte snapshot"
    }

    func close() {
        connection.invalidate()
        listener.invalidate()
        acp.queue.sync { acp.stop() }
        UserDefaults().removePersistentDomain(forName: Self.suite)
    }
}
