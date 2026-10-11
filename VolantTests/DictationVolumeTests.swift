import CoreAudio
import XCTest

@testable import Volant

/// Fictional outputs for the dictation volume duck. Nothing here touches real audio hardware.
private final class FakeOutputs: AudioHardwareAccess {
    struct Device {
        var uid: String
        var name: String
        var volumes: [(channel: UInt32, value: Float32)]
        var canSetVolume = true
        var muted: Bool? = false
    }
    var devices: [AudioDeviceID: Device] = [:]
    var current: AudioDeviceID = 1
    var failingChannels: Set<UInt32> = []
    var rounding: Float32?
    var writes: [(device: AudioDeviceID, channel: UInt32, value: Float32)] = []

    /// Reads one device as CoreAudio would report it.
    func state(_ id: AudioDeviceID) throws -> AudioOutputState {
        guard let device = devices[id] else { throw VolumeFailure(message: "gone") }
        return AudioOutputState(device: id, name: device.name, volumes: device.volumes, canSetVolume: device.canSetVolume,
                                muted: device.muted, canSetMute: true, uid: device.uid)
    }
    func output() throws -> AudioOutputState { try state(current) }
    func output(of device: AudioDeviceID) throws -> AudioOutputState { try state(device) }

    /// Applies a write, optionally rounding to a hardware step, unless the channel is set to fail.
    func setVolume(_ value: Float32, channel: UInt32, device: AudioDeviceID) throws {
        guard !failingChannels.contains(channel), var entry = devices[device], entry.canSetVolume else {
            throw VolumeFailure(message: "write failed")
        }
        writes.append((device, channel, value))
        let stored = rounding.map { (value / $0).rounded() * $0 } ?? value
        if let index = entry.volumes.firstIndex(where: { $0.channel == channel }) { entry.volumes[index].value = stored }
        devices[device] = entry
    }
    func setMute(_ value: Bool, device: AudioDeviceID) throws { XCTFail("Ducking must never write mute") }

    /// Values for a device's channels, in channel order.
    func levels(_ id: AudioDeviceID) -> [Float32] { devices[id]?.volumes.map(\.value) ?? [] }
}

private final class FakeMonitor: AudioOutputChangeMonitoring {
    var onChange: (() -> Void)?
    var starts = 0
    var stops = 0
    func start(_ onChange: @escaping () -> Void) { starts += 1; self.onChange = onChange }
    func stop() { stops += 1; onChange = nil }
}

final class DictationVolumeTests: XCTestCase {
    private var outputs: FakeOutputs!
    private var monitor: FakeMonitor!
    private var duck: DictationVolumeDuck!

    override func setUp() {
        outputs = FakeOutputs()
        outputs.devices[1] = .init(uid: "speakers", name: "Fixture Speakers", volumes: [(1, 0.8), (2, 0.4)])
        outputs.devices[2] = .init(uid: "headphones", name: "Fixture Headphones", volumes: [(0, 0.6)])
        monitor = FakeMonitor()
        duck = DictationVolumeDuck(hardware: outputs, monitor: monitor)
    }

    private func assertLevels(_ actual: [Float32], _ expected: [Float32], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (lhs, rhs) in zip(actual, expected) { XCTAssertEqual(lhs, rhs, accuracy: 0.0001, file: file, line: line) }
    }

    func testLowersToAFifthKeepingBalanceAndRestoresExactly() {
        XCTAssertNil(duck.lower())
        XCTAssertTrue(duck.isLowered)
        assertLevels(outputs.levels(1), [0.16, 0.08])
        XCTAssertEqual(monitor.starts, 1)
        XCTAssertNil(duck.restore())
        assertLevels(outputs.levels(1), [0.8, 0.4])
        XCTAssertFalse(duck.isLowered)
        XCTAssertEqual(monitor.stops, 1)
        let count = outputs.writes.count
        XCTAssertNil(duck.restore())
        XCTAssertEqual(outputs.writes.count, count, "A second restore must not write")
    }

    func testLoweringTwiceDoesNotCompound() {
        duck.lower()
        duck.lower()
        assertLevels(outputs.levels(1), [0.16, 0.08])
        duck.restore()
        assertLevels(outputs.levels(1), [0.8, 0.4])
    }

    func testHardwareRoundingStillCountsAsUnchanged() {
        outputs.rounding = 0.0625
        duck.lower()
        XCTAssertNil(duck.restore())
        XCTAssertEqual(outputs.writes.suffix(2).map(\.value), [0.8, 0.4])
    }

    func testVolumeTheUserChangedDuringDictationIsKept() {
        duck.lower()
        outputs.devices[1]?.volumes = [(1, 0.5), (2, 0.25)]
        let count = outputs.writes.count
        XCTAssertNil(duck.restore())
        XCTAssertEqual(outputs.writes.count, count)
        assertLevels(outputs.levels(1), [0.5, 0.25])
    }

    func testMutedOutputIsNeverTouched() {
        outputs.devices[1]?.muted = true
        XCTAssertNil(duck.lower())
        XCTAssertFalse(duck.isLowered)
        XCTAssertTrue(outputs.writes.isEmpty)
    }

    func testMutingDuringDictationRestoresLevelButStaysMuted() {
        duck.lower()
        outputs.devices[1]?.muted = true
        XCTAssertNil(duck.restore())
        assertLevels(outputs.levels(1), [0.8, 0.4])
        XCTAssertEqual(outputs.devices[1]?.muted, true)
    }

    func testOutputWithoutSoftwareVolumeIsSkippedSilently() {
        outputs.devices[1]?.canSetVolume = false
        XCTAssertNil(duck.lower())
        XCTAssertNil(duck.restore())
        XCTAssertTrue(outputs.writes.isEmpty)
        XCTAssertEqual(monitor.starts, 0)
    }

    func testNearlySilentOutputIsLeftAlone() {
        outputs.devices[1]?.volumes = [(1, 0.02), (2, 0)]
        XCTAssertNil(duck.lower())
        XCTAssertFalse(duck.isLowered)
        XCTAssertTrue(outputs.writes.isEmpty)
    }

    func testMissingOutputIsSkippedSilently() {
        outputs.devices = [:]
        XCTAssertNil(duck.lower())
        XCTAssertFalse(duck.isLowered)
    }

    func testDeviceSwitchRestoresOriginalImmediatelyAndNeverTouchesTheNewOne() {
        var problems: [String] = []
        duck.onProblem = { problems.append($0) }
        duck.lower()
        outputs.current = 2
        monitor.onChange?()
        assertLevels(outputs.levels(1), [0.8, 0.4])
        assertLevels(outputs.levels(2), [0.6])
        XCTAssertFalse(outputs.writes.contains { $0.device == 2 })
        XCTAssertFalse(duck.isLowered)
        XCTAssertTrue(problems.isEmpty)
        XCTAssertNil(duck.restore())
        XCTAssertFalse(outputs.writes.contains { $0.device == 2 })
    }

    func testOutputChangeNotificationForTheSameDeviceKeepsItLowered() {
        duck.lower()
        duck.outputChanged()
        XCTAssertTrue(duck.isLowered)
        assertLevels(outputs.levels(1), [0.16, 0.08])
    }

    func testDisconnectedOriginalIsReportedAndNewOutputUntouched() {
        var problems: [String] = []
        duck.onProblem = { problems.append($0) }
        duck.lower()
        outputs.devices[1] = nil
        outputs.current = 2
        duck.outputChanged()
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("Fixture Speakers"))
        XCTAssertFalse(outputs.writes.contains { $0.device == 2 })
    }

    func testRecycledDeviceIDIsNotRestored() {
        duck.lower()
        outputs.devices[1] = .init(uid: "other", name: "Other Output", volumes: [(1, 0.16), (2, 0.08)])
        XCTAssertNotNil(duck.restore())
        assertLevels(outputs.levels(1), [0.16, 0.08])
    }

    func testFailedRestoreIsReported() {
        duck.lower()
        outputs.failingChannels = [2]
        let problem = duck.restore()
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("Fixture Speakers") == true)
        XCTAssertEqual(outputs.levels(1)[0], 0.8, accuracy: 0.0001, "Channels that can be restored still are")
    }

    func testPartialLowerFailureRollsBackQuietly() {
        outputs.failingChannels = [2]
        XCTAssertNil(duck.lower())
        XCTAssertFalse(duck.isLowered)
        assertLevels(outputs.levels(1), [0.8, 0.4])
        XCTAssertEqual(monitor.starts, 0)
    }

    func testPartialLowerFailureThatCannotRollBackIsReported() {
        let failing = FailingAfterFirstWrite(outputs)
        let duck = DictationVolumeDuck(hardware: failing, monitor: nil)
        XCTAssertNotNil(duck.lower())
        XCTAssertFalse(duck.isLowered)
    }
}

/// Lets the first channel lower and then refuses every write, so a rollback cannot complete.
private final class FailingAfterFirstWrite: AudioHardwareAccess {
    private let base: FakeOutputs
    private var allowed = 1
    init(_ base: FakeOutputs) { self.base = base }
    func output() throws -> AudioOutputState { try base.output() }
    func output(of device: AudioDeviceID) throws -> AudioOutputState { try base.output(of: device) }

    /// Forwards one write, then fails all later ones.
    func setVolume(_ value: Float32, channel: UInt32, device: AudioDeviceID) throws {
        guard allowed > 0 else { throw VolumeFailure(message: "write failed") }
        allowed -= 1
        try base.setVolume(value, channel: channel, device: device)
    }
    func setMute(_ value: Bool, device: AudioDeviceID) throws {}
}
