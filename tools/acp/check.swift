import Foundation
import VolantCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
func frame(_ object: [String: Any]) -> Data {
    var data = try! JSONSerialization.data(withJSONObject: object); data.append(10); return data
}
let client = ACPConnection()
var sent: [[String: Any]] = []
client.testSend = { sent.append($0) }
try client.queue.sync {
    client.beginHandshake(project: "/tmp/fictional-project")
    require(sent.last?["method"] as? String == "initialize", "initialization")
    let initial = frame(["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": 1, "agentCapabilities": ["loadSession": true]]])
    client.receive(initial.prefix(12)); require(sent.count == 1, "partial frames wait")
    client.receive(initial.dropFirst(12)); require(sent.last?["method"] as? String == "session/new", "new session after handshake")
    client.receive(frame(["jsonrpc": "2.0", "id": 2, "result": ["sessionId": "fictional-session"]]))
    require(client.state.phase == "ready", "ready after session ID")
    try client.prompt("Hello fixture")
    do { try client.prompt("duplicate"); fatalError("duplicate accepted") } catch {}
    let update: (String, String) -> [String: Any] = { session, text in ["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": session, "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text]]]] }
    client.receive(frame(update("wrong-session", "must ignore")))
    require(client.state.messages.count == 1, "ignore other session")
    client.receive(frame(update("fictional-session", "Hello ")) + frame(update("fictional-session", "world")))
    require(client.state.messages.last?.text == "Hello world", "coalesced streaming")
    let permission: (Int) -> [String: Any] = { id in ["jsonrpc": "2.0", "id": id, "method": "session/request_permission", "params": ["sessionId": "fictional-session", "toolCall": ["toolCallId": "tool-1"], "options": [["optionId": "once", "name": "Allow once", "kind": "allow_once"], ["optionId": "deny", "name": "Reject", "kind": "reject_once"]]]] }
    client.receive(frame(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "fictional-session", "update": ["sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": "Read fixture", "rawInput": ["path": "fixture.txt"]]]]))
    let count = sent.count
    client.receive(frame(permission(91)))
    require(sent.count == count && client.state.permissions.count == 1, "no automatic approval")
    require(client.state.permissions[0].detail.contains("fixture.txt"), "permissions retain earlier operation details")
    let key = client.state.permissions[0].id
    do { try client.choose(request: key, option: "forged"); fatalError("invalid option accepted") } catch {}
    try client.choose(request: key, option: "deny")
    require(client.state.permissions.isEmpty, "permission resolved")
    do { try client.choose(request: key, option: "once"); fatalError("stale permission accepted") } catch {}
    client.receive(frame(permission(92)))
    client.cancel()
    require(client.state.permissions.isEmpty && client.state.phase == "cancelling", "cancellation clears approvals")
    let cancelled = sent.contains { ($0["id"] as? Int == 92) && (($0["result"] as? [String: Any])?["outcome"] as? [String: Any])?["outcome"] as? String == "cancelled" }
    require(cancelled, "cancel sends required permission outcome")
    client.receive(frame(permission(93)))
    require(client.state.permissions.isEmpty, "late approval while cancelling is cancelled")
    client.receive(frame(["jsonrpc": "2.0", "id": 3, "result": ["stopReason": "cancelled"]]))
    require(client.state.phase == "ready", "cancellation waits for prompt response")
    client.receive(frame(["jsonrpc": "2.0", "id": "extension-request", "method": "terminal/create", "params": [:]]))
    require((sent.last?["error"] as? [String: Any])?["code"] as? Int == -32601, "unsupported methods fail explicitly")
    client.receive(Data("invalid json\n".utf8))
    require(client.state.phase == "failed", "invalid JSON terminates")
}
let version = ACPConnection()
version.testSend = { _ in }
version.queue.sync {
    version.beginHandshake(project: "/tmp/fixture")
    version.receive(frame(["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": 999]]))
    require(version.state.phase == "failed", "version mismatch")
}
print("Passed ACP checks: framing, negotiation, session routing, streaming, duplicate sends, explicit/rejected/stale permissions, cancellation, unsupported methods, invalid JSON.")

let oversized = ACPConnection()
oversized.testSend = { _ in }
oversized.queue.sync {
    oversized.receive(Data(repeating: 65, count: 2_000_001))
    require(oversized.state.phase == "failed", "unterminated frame limit")
}
print("Passed: retained approval details and oversized unterminated frame rejection.")

/// Attachments are shaped by what the agent advertised and re-checked here, not trusted from the app.
func contextSession(_ capabilities: [String: Any]) -> (ACPConnection, () -> [String: Any]?) {
    let connection = ACPConnection()
    var log: [[String: Any]] = []
    connection.testSend = { log.append($0) }
    connection.queue.sync {
        connection.beginHandshake(project: "/tmp/fictional-project")
        connection.receive(frame(["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": 1, "agentCapabilities": capabilities]]))
        connection.receive(frame(["jsonrpc": "2.0", "id": 2, "result": ["sessionId": "context-session"]]))
    }
    return (connection, { log.last })
}
let note = ChatAttachment(id: "Plan.md", kind: .note, title: "Plan", detail: "Note", text: "Ship the fixture.")
let (embedded, lastEmbedded) = contextSession(["promptCapabilities": ["embeddedContext": true]])
try embedded.queue.sync {
    try embedded.prompt("Summarize", attachments: [note])
    let blocks = (lastEmbedded()?["params"] as? [String: Any])?["prompt"] as? [[String: Any]] ?? []
    require(blocks.count == 2 && blocks[0]["type"] as? String == "resource", "embedded context sends a resource block")
    require(((blocks[0]["resource"] as? [String: Any])?["text"] as? String) == "Ship the fixture.", "resource carries the snapshot text")
    require(blocks[1]["text"] as? String == "Summarize", "prompt follows its attachments")
    require(embedded.state.messages.last?.text == "Summarize" && embedded.state.messages.last?.attachments == ["Plan"], "transcript shows the prompt and titles only")
}
let (plain, lastPlain) = contextSession(["loadSession": true])
try plain.queue.sync {
    try plain.prompt("Summarize", attachments: [note])
    let blocks = (lastPlain()?["params"] as? [String: Any])?["prompt"] as? [[String: Any]] ?? []
    require(blocks.count == 1 && blocks[0]["type"] as? String == "text", "agents without embedded context get one text block")
    require((blocks[0]["text"] as? String)?.contains("<attachment kind=\"note\" title=\"Plan\">") == true, "inline form labels the note")
}
let (limited, lastLimited) = contextSession(["promptCapabilities": ["embeddedContext": true]])
limited.queue.sync {
    let huge = ChatAttachment(id: "big", kind: .clipboard, title: "Big", detail: "", text: String(repeating: "x", count: ChatAttachmentLimits.perItem + 1))
    do { try limited.prompt("Too much", attachments: [huge]); fatalError("oversized attachment accepted") } catch {}
    require(lastLimited()?["method"] as? String == "session/new" && limited.state.phase == "ready", "refused prompts send nothing")
}
print("Passed: attachments follow embeddedContext, keep the transcript short, and are re-checked before sending.")

/// Resume loads the recorded session by ID, replays its history, and never falls back to a new one.
func resumeSession(_ capabilities: [String: Any]) -> (ACPConnection, () -> [[String: Any]]) {
    let connection = ACPConnection()
    var log: [[String: Any]] = []
    connection.testSend = { log.append($0) }
    connection.queue.sync {
        connection.beginHandshake(project: "/tmp/fictional-project", resume: "fictional-resumed")
        connection.receive(frame(["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": 1, "agentCapabilities": capabilities]]))
    }
    return (connection, { log })
}
let chunk: (String, String) -> [String: Any] = { kind, text in ["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "fictional-resumed", "update": ["sessionUpdate": kind, "content": ["type": "text", "text": text]]]] }
let (resumed, resumedLog) = resumeSession(["loadSession": true])
try resumed.queue.sync {
    let load = resumedLog().last
    require(load?["method"] as? String == "session/load", "resume sends session/load, not session/new")
    let params = load?["params"] as? [String: Any]
    require(params?["sessionId"] as? String == "fictional-resumed" && params?["cwd"] as? String == "/tmp/fictional-project", "load names the recorded session and folder")
    require(!resumedLog().contains { $0["method"] as? String == "session/new" }, "no new session during a resume")
    require(resumed.state.phase == "starting" && resumed.state.status == "Restoring conversation…", "restoring until the load answers")
    resumed.receive(frame(chunk("user_message_chunk", "Earlier ")) + frame(chunk("user_message_chunk", "question")))
    resumed.receive(frame(chunk("agent_message_chunk", "Earlier answer")))
    resumed.receive(frame(["jsonrpc": "2.0", "id": 77, "method": "session/request_permission", "params": ["sessionId": "fictional-resumed", "toolCall": ["toolCallId": "old"], "options": [["optionId": "once", "name": "Allow once", "kind": "allow_once"]]]]))
    let replayRefused = resumedLog().contains { ($0["id"] as? Int == 77) && (($0["result"] as? [String: Any])?["outcome"] as? [String: Any])?["outcome"] as? String == "cancelled" }
    require(replayRefused && resumed.state.permissions.isEmpty, "no approval is offered while history replays")
    require(resumed.state.messages.map(\.role) == ["You", "Agent"], "replayed history keeps both sides")
    require(resumed.state.messages.map(\.text) == ["Earlier question", "Earlier answer"], "replayed chunks coalesce per turn")
    resumed.receive(frame(["jsonrpc": "2.0", "id": 2, "result": [:]]))
    require(resumed.state.phase == "ready" && resumed.state.sessionID == "fictional-resumed", "ready on the resumed session")
    try resumed.prompt("Follow-up")
    resumed.receive(frame(chunk("user_message_chunk", "echo must not duplicate")))
    require(resumed.state.messages.filter { $0.role == "You" }.map(\.text) == ["Earlier question", "Follow-up"], "live turns ignore user echoes")
    require((resumedLog().last?["params"] as? [String: Any])?["sessionId"] as? String == "fictional-resumed", "prompts go to the resumed session")
}
let (unsupported, unsupportedLog) = resumeSession(["promptCapabilities": ["embeddedContext": true]])
unsupported.queue.sync {
    require(unsupported.state.phase == "failed", "an agent without loadSession cannot be resumed")
    require(!unsupportedLog().contains { ["session/new", "session/load"].contains($0["method"] as? String ?? "") }, "and gets neither a load nor a silent new session")
    require(unsupported.state.status.contains("can’t resume"), "the reason is stated")
}
let (missing, _) = resumeSession(["loadSession": true])
missing.queue.sync {
    missing.receive(frame(["jsonrpc": "2.0", "id": 2, "error": ["code": -32002, "message": "Session not found."]]))
    require(missing.state.phase == "failed" && missing.state.sessionID == nil, "a failed load ends the connection")
    require(missing.state.status.hasPrefix("Couldn’t resume this conversation: Session not found."), "load errors name the resume")
}
let fresh = ACPConnection()
var freshLog: [[String: Any]] = []
fresh.testSend = { freshLog.append($0) }
fresh.queue.sync {
    fresh.beginHandshake(project: "/tmp/fictional-project")
    fresh.receive(frame(["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": 1, "agentCapabilities": ["loadSession": true]]]))
    fresh.receive(frame(["jsonrpc": "2.0", "id": 2, "result": ["sessionId": "fresh-session"]]))
    fresh.receive(frame(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "fresh-session", "update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "not a replay"]]]]))
    require(fresh.state.messages.isEmpty, "user chunks outside a resume are ignored")
}
let refused = ACPConnection()
do { try refused.start(provider: "claude", project: "", resume: "bad id"); fatalError("invalid resume ID accepted") } catch {}
require(refused.state.phase == "disconnected", "an invalid resume ID starts nothing")
print("Passed: resume loads by recorded ID, replays both sides, refuses approvals during replay, and never falls back to a new session.")

let (long, _) = resumeSession(["loadSession": true])
long.queue.sync {
    let turn = String(repeating: "fictional history ", count: 1_000)
    for index in 0..<200 {
        long.receive(frame(chunk("user_message_chunk", "Question \(index)")) + frame(chunk("agent_message_chunk", turn)))
        long.receive(frame(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "fictional-resumed", "update": ["sessionUpdate": "tool_call", "toolCallId": "old-\(index)", "title": "Fictional tool", "rawInput": ["text": turn]]]]))
    }
    require(long.state.phase == "starting", "a long history keeps replaying instead of hitting the live limits")
    require(long.state.messages.last?.role.hasPrefix("Tool") == true && long.state.messages.count <= ACPConnection.replayEventLimit, "replay keeps the newest entries")
    require(!long.state.messages.contains { $0.text == "Question 0" }, "the oldest replayed turns are dropped")
    long.receive(frame(["jsonrpc": "2.0", "id": 2, "result": [:]]))
    require(long.state.phase == "ready" && long.state.status == "Ready. Earlier history isn’t shown.", "a trimmed replay says so")
    require(long.state.messages.reduce(0) { $0 + $1.text.utf8.count } <= ACPConnection.replayTextLimit, "room remains for new turns")
}
let (rejectedLoad, _) = resumeSession(["loadSession": true])
rejectedLoad.queue.sync {
    rejectedLoad.receive(frame(["jsonrpc": "2.0", "id": 2, "error": ["code": -32603, "message": "Fictional load failure."]]))
    require(rejectedLoad.state.resumeRejected == true, "a refused load tells the app to stop offering it")
}
require(unsupported.state.resumeRejected == true, "an agent without loadSession stops offering resume")
print("Passed: long replays keep their newest history, and refused loads clear the resume offer.")

/// Reads skip the snapshot only while the reader holds the current revision; every visible change advances it.
let polled = ACPConnection()
polled.testSend = { _ in }
try polled.queue.sync {
    let decode: (Data?) -> ACPState? = { $0.flatMap { try? JSONDecoder().decode(ACPState.self, from: $0) } }
    let peek: (Int) -> Data? = { try! polled.snapshot(after: $0).0 }
    let (initial, start) = try polled.snapshot(after: -1)
    require(decode(initial) == polled.state, "a reader without a revision gets the full state")
    let (repeated, same) = try polled.snapshot(after: start)
    require(repeated == nil && same == start, "an unchanged conversation sends no snapshot")
    require(peek(start + 1) != nil, "any other revision gets the full state")
    polled.beginHandshake(project: "/tmp/fictional-project")
    polled.receive(frame(["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": 1, "agentCapabilities": [:]]]))
    polled.receive(frame(["jsonrpc": "2.0", "id": 2, "result": ["sessionId": "polled-session"]]))
    var known = start
    let advances: (String) throws -> Void = { reason in
        let (data, revision) = try polled.snapshot(after: known)
        require(revision != known && decode(data) == polled.state, reason)
        known = revision
        require(peek(known) == nil, reason + " and then stays unchanged")
    }
    try advances("the handshake advances the revision")
    try polled.prompt("Fictional question")
    try advances("a prompt advances the revision")
    let update: (String, String) -> [String: Any] = { session, text in ["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": session, "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text]]]] }
    polled.receive(frame(update("polled-session", "Hello ")))
    try advances("a new agent message advances the revision")
    polled.receive(frame(update("polled-session", "world")))
    try advances("text appended in place advances the revision")
    require(decode(peek(-1))?.messages.last?.text == "Hello world", "the snapshot carries the appended text")
    polled.receive(frame(update("other-session", "ignored")))
    require(peek(known) == nil, "an update for another session changes nothing")
    polled.receive(frame(["jsonrpc": "2.0", "id": 40, "method": "session/request_permission", "params": ["sessionId": "polled-session", "toolCall": ["toolCallId": "tool-1"], "options": [["optionId": "once", "name": "Allow once", "kind": "allow_once"]]]]))
    try advances("a permission request advances the revision")
    try polled.choose(request: polled.state.permissions[0].id, option: "once")
    try advances("an answered permission advances the revision")
    polled.cancel()
    try advances("cancelling advances the revision")
    polled.receive(frame(["jsonrpc": "2.0", "id": 3, "result": ["stopReason": "cancelled"]]))
    try advances("the end of a turn advances the revision")
    polled.stop()
    try advances("stopping advances the revision")
}
print("Passed: revisions skip unchanged snapshots and advance on every change, including in-place text.")

// The helper counts conversations across connections and refuses one past the limit before it
// resolves or launches anything.
let full = ACPConversationSlots(limit: 0)
let refusedAtLimit = ACPConnection(slots: full)
do {
    try refusedAtLimit.queue.sync { try refusedAtLimit.start(provider: "qwen", project: "/tmp/fictional-missing-project") }
    fatalError("a start past the conversation limit was accepted")
} catch {
    let message = error.localizedDescription
    require(message.contains("up to 0 conversations"), "the refusal names the limit, saw: " + message)
    require(!message.contains("not found") && !message.contains("folder"), "the refusal comes before the provider or folder is resolved")
}
require(refusedAtLimit.state.phase == "disconnected" && full.inUse == 0, "a refused start takes no slot and starts nothing")
let one = ACPConversationSlots(limit: 1)
let unknownProvider = ACPConnection(slots: one)
do { try unknownProvider.queue.sync { try unknownProvider.start(provider: "fictional-provider", project: "") }; fatalError("an unknown provider was accepted") } catch {}
require(one.inUse == 0, "a start that fails after taking a slot returns it")
let holder = ACPConnection(slots: one)
try holder.queue.sync { try holder.takeSlot() }
require(one.inUse == 1, "a running conversation holds a slot")
let second = ACPConnection(slots: one)
do { try second.queue.sync { try second.start(provider: "qwen", project: "") }; fatalError("a second conversation past a limit of one was accepted") } catch {
    require(error.localizedDescription.contains("up to 1 conversations"), "the second start is refused at the limit")
}
holder.queue.sync { holder.stop() }
require(one.inUse == 0, "stopping returns the slot")
holder.queue.sync { holder.stop("Agent process exited.", failed: true) }
require(one.inUse == 0, "a second stop returns nothing more")
print("Passed: the helper refuses a conversation past its limit before launching anything, and every stop or failed start returns its slot.")
