import Foundation
import Darwin
import VolantCore

/// Bounded in-memory output. A stalled SSH child cannot hold the helper's pipe read open forever.
enum HerdrProcess {
    static func run(executable: URL, arguments: [String], home: String, timeout: TimeInterval = 8,
                    directory: String? = nil, environment: [String: String]? = nil) throws -> Data {
        let task = Process(), output = Pipe(), capture = HerdrOutput()
        task.executableURL = executable
        task.arguments = arguments
        task.currentDirectoryURL = URL(fileURLWithPath: directory ?? home)
        task.environment = environment ?? ChildProcessEnvironment.herdr(home: home, user: NSUserName(),
                                                                         sshAuthSocket: ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"])
        task.standardInput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; capture.finished.signal() }
            else if !capture.append(chunk), task.isRunning { task.terminate() }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
        }
        try task.run()
        let deadline = DispatchWorkItem {
            if task.isRunning { capture.fail(); task.terminate() }
        }
        let killDeadline = DispatchWorkItem {
            if task.isRunning { capture.fail(); kill(task.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 1, execute: killDeadline)
        defer { deadline.cancel(); killDeadline.cancel() }
        task.waitUntilExit()
        guard capture.finished.wait(timeout: .now() + 1) == .success,
              task.terminationStatus == 0, let data = capture.result() else {
            throw NSError(domain: "VolantHerdrProcess", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Herdr is unavailable or the connection timed out."])
        }
        return data
    }
}

private final class HerdrOutput: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()
    private var failed = false
    func append(_ chunk: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failed, data.count + chunk.count <= 2_000_000 else { failed = true; return false }
        data.append(chunk); return true
    }
    func fail() { lock.lock(); failed = true; lock.unlock() }
    func result() -> Data? { lock.lock(); defer { lock.unlock() }; return failed ? nil : data }
}
