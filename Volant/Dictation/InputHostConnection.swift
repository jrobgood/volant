import Foundation
import VolantCore

/// The XPC connection to `VolantInputHost`. It is created on the first call, never at launch, and
/// the app makes that first call only after the owner chooses Type at the cursor, so until then
/// the helper never runs and nothing asks macOS about Accessibility. `disconnect` invalidates the
/// connection and the helper exits. Replies are decoded here and delivered on the main queue; a
/// helper that fails, refuses the connection or does not answer within `timeout` yields nil.
final class InputHostConnection: InputHostClient {
    static let timeout: TimeInterval = 10
    private var connection: NSXPCConnection?

    func status(prompt: Bool, completion: @escaping (InputHostStatus?) -> Void) {
        call(completion) { proxy, reply in proxy.accessibilityStatus(prompt: prompt, reply: reply) }
    }

    func beginSession(completion: @escaping (InputSessionStart?) -> Void) {
        call(completion) { proxy, reply in proxy.beginSession(reply: reply) }
    }

    func insert(phrase: String, token: Data, completion: @escaping (InputInsertion?) -> Void) {
        call(completion) { proxy, reply in proxy.insert(phrase: phrase, token: token, reply: reply) }
    }

    func endSession(token: Data) {
        guard let connection else { return }
        (connection.remoteObjectProxyWithErrorHandler { _ in } as? VolantInputHostProtocol)?.endSession(token: token)
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    /// The current connection, made on first use. An invalidated connection is replaced on the
    /// next call, so a crashed helper starts again the next time typing is used.
    private func current() -> NSXPCConnection {
        if let connection { return connection }
        let made = NSXPCConnection(serviceName: InputHostService.name)
        made.remoteObjectInterface = NSXPCInterface(with: VolantInputHostProtocol.self)
        made.invalidationHandler = { [weak self, weak made] in
            DispatchQueue.main.async { if self?.connection === made { self?.connection = nil } }
        }
        made.resume()
        connection = made
        return made
    }

    /// Sends one request and delivers exactly one decoded reply, or nil on error or timeout.
    private func call<T: Decodable>(_ completion: @escaping (T?) -> Void,
                                    _ send: (VolantInputHostProtocol, @escaping (Data) -> Void) -> Void) {
        var delivered = false
        let deliver: (T?) -> Void = { value in
            DispatchQueue.main.async {
                guard !delivered else { return }
                delivered = true
                completion(value)
            }
        }
        let proxy = current().remoteObjectProxyWithErrorHandler { _ in deliver(nil) }
        guard let host = proxy as? VolantInputHostProtocol else { deliver(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { deliver(nil) }
        send(host) { data in
            deliver(data.count <= 4096 ? try? JSONDecoder().decode(T.self, from: data) : nil)
        }
    }
}
