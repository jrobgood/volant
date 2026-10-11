import Foundation
import VolantCore

/// Types dictation at the cursor for Volant. This is the only Volant code that uses Accessibility
/// or posts events, and it runs outside App Sandbox because a sandboxed process cannot. It starts
/// only when the owner has chosen Type at the cursor and Volant connects, and exits when Volant
/// disconnects. Everything it does is in `InputSessionController`; this file only checks the
/// caller and moves JSON across the connection on one serial queue.
final class InputHost: NSObject, VolantInputHostProtocol {
    private let queue = DispatchQueue(label: "com.mysticcoders.volant.input-host")
    private let controller: InputSessionController

    init(callerPID: Int32) {
        controller = InputSessionController(system: SystemInput(), callerPID: callerPID)
    }

    func accessibilityStatus(prompt: Bool, reply: @escaping (Data) -> Void) {
        queue.async { reply(Self.encode(self.controller.status(prompt: prompt))) }
    }

    func beginSession(reply: @escaping (Data) -> Void) {
        queue.async { reply(Self.encode(self.controller.begin())) }
    }

    func insert(phrase: String, token: Data, reply: @escaping (Data) -> Void) {
        queue.async { reply(Self.encode(self.controller.insert(phrase, token: token))) }
    }

    func endSession(token: Data) {
        queue.async { self.controller.end(token: token) }
    }

    /// The reply as JSON; the types are plain values, so encoding cannot fail in practice.
    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}

/// Accepts only the signed Volant app from this team, and exits once no connection is left so
/// the helper never lingers after the owner turns typing off.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private var connections = 0

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(InputHostService.callerRequirement)
        connection.exportedInterface = NSXPCInterface(with: VolantInputHostProtocol.self)
        connection.exportedObject = InputHost(callerPID: connection.processIdentifier)
        connection.invalidationHandler = { [weak self] in self?.connectionEnded() }
        DispatchQueue.main.async { self.connections += 1 }
        connection.resume()
        return true
    }

    /// Exits shortly after the last connection ends, unless a new one arrived in the meantime.
    private func connectionEnded() {
        DispatchQueue.main.async {
            self.connections -= 1
            guard self.connections <= 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if self.connections <= 0 { exit(0) }
            }
        }
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
