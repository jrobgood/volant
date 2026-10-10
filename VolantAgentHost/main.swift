import Foundation
import Security
import VolantCore

/// Local Herdr discovery and typed ACP conversations. No shell or arbitrary-command API.
/// This service intentionally runs outside App Sandbox to reach the user's Herdr socket.
final class AgentHost: NSObject, VolantAgentHostProtocol {
    private let shortcutsHost = AppleShortcutsHost()
    private let shortcutsQueue = DispatchQueue(label: "com.mysticcoders.volant.shortcuts")
    func listAppleShortcuts(reply: @escaping (Data?, String?) -> Void) {
        shortcutsQueue.async {
            do { reply(try AppleShortcutsHost.list(), nil) }
            catch { reply(nil, "Couldn’t read Apple Shortcuts. Open Shortcuts and try again.") }
        }
    }
    func runAppleShortcut(id: String, reply: @escaping (String?) -> Void) {
        shortcutsQueue.async { self.shortcutsHost.run(id: id, reply: reply) }
    }
    private let acp = ACPConnection()
    func acpStart(provider: String, project: String, reply: @escaping (String?) -> Void) {
        acp.queue.async { do { try self.acp.start(provider: provider, project: project); reply(nil) } catch { reply(error.localizedDescription) } }
    }
    func acpResume(provider: String, project: String, session: String, reply: @escaping (String?) -> Void) {
        acp.queue.async { do { try self.acp.start(provider: provider, project: project, resume: session); reply(nil) } catch { reply(error.localizedDescription) } }
    }
    func acpRead(after revision: Int, reply: @escaping (Data?, Int, String?) -> Void) {
        acp.queue.async {
            do { let (data, current) = try self.acp.snapshot(after: revision); reply(data, current, nil) }
            catch { reply(nil, -1, error.localizedDescription) }
        }
    }
    func acpPrompt(text: String, reply: @escaping (String?) -> Void) {
        acp.queue.async { do { try self.acp.prompt(text); reply(nil) } catch { reply(error.localizedDescription) } }
    }
    func acpPromptWithContext(text: String, attachments data: Data, reply: @escaping (String?) -> Void) {
        acp.queue.async {
            do {
                guard data.count <= 512_000 else { throw CocoaError(.fileReadTooLarge) }
                try self.acp.prompt(text, attachments: try JSONDecoder().decode([ChatAttachment].self, from: data))
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }
    func acpCancel(reply: @escaping (String?) -> Void) { acp.queue.async { self.acp.cancel(); reply(nil) } }
    func acpPermission(request: String, option: String, reply: @escaping (String?) -> Void) {
        acp.queue.async { do { try self.acp.choose(request: request, option: option); reply(nil) } catch { reply(error.localizedDescription) } }
    }
    func acpStop(reply: @escaping () -> Void) { acp.queue.async { self.acp.stop(); reply() } }
    func invalidate() { acp.queue.async { self.acp.stop() } }
    private let inspectionQueue = DispatchQueue(label: "com.mysticcoders.volant.inspection")
    func detectACPAgents(reply: @escaping (Data?, String?) -> Void) {
        inspectionQueue.async {
            do { reply(try JSONEncoder().encode(ACPAgentResolver.system.detectAll()), nil) }
            catch { reply(nil, "Couldn’t check for installed agents.") }
        }
    }
    func repositoryStates(paths data: Data, reply: @escaping (Data?, String?) -> Void) {
        inspectionQueue.async {
            do {
                guard data.count <= 64_000 else { throw CocoaError(.fileReadTooLarge) }
                let paths = try JSONDecoder().decode([String].self, from: data)
                reply(try JSONEncoder().encode(RepositoryInspector.states(for: paths)), nil)
            } catch {
                reply(nil, "Couldn’t read repository changes.")
            }
        }
    }
    private let queue = DispatchQueue(label: "com.mysticcoders.volant.agent-host")
    private let localInventoryQueue = DispatchQueue(label: "com.mysticcoders.volant.herdr-local")
    private let catalogQueue = DispatchQueue(label: "com.mysticcoders.volant.herdr-catalog")
    private let remoteInventoryQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    private var machines: HerdrMachineRouter { HerdrMachineRouter(run: { [unowned self] in try self.run($0) }) }
    private func run(_ arguments: [String]) throws -> Data {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [home + "/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "VolantAgents", code: 1, userInfo: [NSLocalizedDescriptionKey: "Herdr was not found. Install Herdr, start a local session, then reconnect."])
        }
        return try HerdrProcess.run(executable: URL(fileURLWithPath: executable), arguments: arguments, home: home)
    }

    func listHerdrMachines(reply: @escaping (Data?, String?) -> Void) {
        catalogQueue.async {
            do { reply(try JSONEncoder().encode(self.machines.profiles()), nil) }
            catch { reply(nil, "Couldn’t read saved machines. Check Herdr 0.9.1 or later is installed.") }
        }
    }
    func setHerdrMachine(machine data: Data, enabled: Bool, reply: @escaping (Data?, String?) -> Void) {
        catalogQueue.async {
            do {
                guard data.count <= 32_000 else { throw CocoaError(.fileReadCorruptFile) }
                let machine = try JSONDecoder().decode(HerdrMachine.self, from: data)
                reply(try JSONEncoder().encode(self.machines.setEnabled(machine, enabled)), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }
    func listAgents(machine data: Data?, reply: @escaping (Data?, String?) -> Void) {
        let work = {
            do {
                guard (data?.count ?? 0) <= 32_000 else { throw CocoaError(.fileReadCorruptFile) }
                let machine = try data.map { try JSONDecoder().decode(HerdrMachine.self, from: $0) }
                reply(try JSONEncoder().encode(self.machines.agents(on: machine)), nil)
            } catch {
                reply(nil, data == nil ? "Start the local default Herdr session." :
                    "Check SSH access and Herdr 0.9.1 or later on this machine.")
            }
        }
        // Remote queue saturation and catalog reads must never delay Local.
        if data == nil { localInventoryQueue.async(execute: work) }
        else { remoteInventoryQueue.addOperation(work) }
    }
    private lazy var herdrResponses = HerdrResponseController(runOnMachine: { [unowned self] in try self.machines.execute($0, $1) })
    private func currentTarget(_ data: Data, blocked: Bool = false) throws -> AgentSession {
        guard data.count <= 32_000 else { throw CocoaError(.fileReadCorruptFile) }
        let requested = try JSONDecoder().decode(AgentSession.self, from: data)
        guard let target = try machines.agents(on: requested.machine).first(where: {
            $0.id == requested.id && $0.sessionIdentity == requested.sessionIdentity && (!blocked || $0.agentStatus == "blocked")
        }) else { throw CocoaError(.fileReadNoSuchFile) }
        return target
    }
    func readAgentAttention(target: Data, reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                reply(try JSONEncoder().encode(self.herdrResponses.read(self.currentTarget(target, blocked: true))), nil)
            } catch { reply(nil, "This question or machine changed or could not be read. Open Herdr to review it.") }
        }
    }
    func answerAgentQuestion(token: String, choice: Int, reply: @escaping (String?, String?) -> Void) {
        queue.async {
            do { reply(try self.herdrResponses.respond(token: token, choice: choice), nil) }
            catch { reply(nil, (error as NSError).domain == "VolantHerdrResponse" ? error.localizedDescription : "Couldn’t confirm delivery. Review the pane before retrying.") }
        }
    }
    func focusAgent(target: Data, reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                let current = try self.currentTarget(target)
                guard !current.paneID.isEmpty, !current.paneID.hasPrefix("-"), current.paneID.count < 128 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                _ = try self.machines.execute(current.machine, ["agent", "focus", current.paneID])
                reply(nil)
            } catch { reply("This pane or machine changed or is unavailable. Refresh before continuing.") }
        }
    }

}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only the signed Volant application from this team may request local automation.
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"com.mysticcoders.volant\" and certificate leaf[subject.OU] = \"REMBT6JY4N\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        connection.exportedInterface = NSXPCInterface(with: VolantAgentHostProtocol.self)
        let host = AgentHost()
        connection.exportedObject = host
        connection.invalidationHandler = { host.invalidate() }
        connection.interruptionHandler = { host.invalidate() }
        connection.resume()
        return true
    }
}
let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
