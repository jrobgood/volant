import Foundation
import CoreAudio
import VolantCore

func verify(_ value: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    guard value() else { fputs("FAIL \(line): \(message)\n", stderr); exit(1) }
}
final class HardwareFixture: AudioHardwareAccess {
    var device: AudioDeviceID = 1
    var values: [(channel: UInt32, value: Float32)] = [(1, 0.4), (2, 0.2)]
    var mute = false
    var writable = true
    var muteWritable = true
    var failureChannel: UInt32?
    var writes: [AudioDeviceID] = []
    func output() throws -> AudioOutputState { AudioOutputState(device: device, name: "Fixture Speakers", volumes: values, canSetVolume: writable, muted: mute, canSetMute: muteWritable) }
    func setVolume(_ value: Float32, channel: UInt32, device: AudioDeviceID) throws {
        if channel == failureChannel { throw VolumeFailure(message: "Fixture write failed") }
        writes.append(device)
        if let index = values.firstIndex(where: { $0.channel == channel }) { values[index].value = value }
    }
    func setMute(_ value: Bool, device: AudioDeviceID) throws { writes.append(device); mute = value }
}
for command in ["vol", "volume", "mute", "unmute"] { verify(LauncherRouting.isReserved(command), "Import must recognize reserved volume commands") }
let hardware = HardwareFixture()
let control = VolumeControl(hardware: hardware)
verify(VolumeCommand.parse("VOLUME 40%", muted: false) == [.set(40)], "Case-insensitive percentage")
for invalid in ["volume -1", "volume 101", "volume 40%%", "volume nan", "volume 20 extra", "mute all"] {
    verify(VolumeCommand.parse(invalid, muted: false).isEmpty, "Reject invalid input: \(invalid)")
}
verify(!VolumeCommand.matches("volunteer"), "No prefix hijacking")
verify(VolumeCommand.parse("volume", muted: true).last == .unmute, "Muted output offers unmute")
_ = try control.perform(.set(60))
verify(abs(hardware.values[0].value - 0.6) < 0.001 && abs(hardware.values[1].value - 0.3) < 0.001, "Preserves balance")
_ = try control.perform(.mute)
_ = try control.perform(.up)
verify(hardware.mute, "Volume changes do not unexpectedly unmute")
_ = try control.perform(.unmute)
verify(!hardware.mute, "Explicit unmute")
_ = try control.perform(.set(100)); _ = try control.perform(.up)
verify(hardware.values[0].value == 1, "Clamp upper bound")
_ = try control.perform(.set(0)); _ = try control.perform(.down)
verify(hardware.values[0].value == 0, "Clamp lower bound")
_ = try control.perform(.up)
verify(hardware.values.allSatisfy { abs($0.value - 0.05) < 0.001 }, "Raise silent channels safely")
_ = try control.state()
hardware.device = 2
_ = try control.perform(.down)
verify(hardware.writes.last == 2, "Resolve current device at activation")
hardware.values = [(1, 0.4), (2, 0.2)]
hardware.failureChannel = 2
do { _ = try control.perform(.set(70)); verify(false, "Partial failure must throw") } catch {}
verify(hardware.values[0].value == 0.4, "Roll back completed channels on failure")
hardware.failureChannel = nil
hardware.writable = false
let count = hardware.writes.count
do { _ = try control.perform(.up); verify(false, "Unsupported volume must throw") } catch {}
hardware.muteWritable = false
do { _ = try control.perform(.mute); verify(false, "Unsupported mute must throw") } catch {}
verify(hardware.writes.count == count, "Unsupported controls never write")
hardware.writable = true
do { _ = try control.perform(.set(101)); verify(false, "Invalid programmatic percentage must throw") } catch {}
hardware.values = [(1, 0.5), (2, 0.25)]
hardware.device = 3
hardware.mute = false
let duck = DictationVolumeDuck(hardware: hardware, monitor: nil)
verify(duck.lower() == nil && duck.isLowered, "Dictation lowers a settable output")
verify(abs(hardware.values[0].value - 0.1) < 0.001 && abs(hardware.values[1].value - 0.05) < 0.001, "Dictation lowering preserves balance")
verify(duck.restore() == nil && !duck.isLowered, "Dictation restores its own lowering")
verify(abs(hardware.values[0].value - 0.5) < 0.001 && abs(hardware.values[1].value - 0.25) < 0.001, "Dictation restores the exact prior levels")
duck.lower(); hardware.device = 4
verify(duck.restore() != nil, "A lowered output that disappeared is reported")
verify(hardware.writes.last == 3, "Restoring never writes to the replacement output")
hardware.mute = true
let writesBeforeMuted = hardware.writes.count
duck.lower(); duck.restore()
verify(hardware.writes.count == writesBeforeMuted && hardware.mute, "Muted outputs are never lowered or unmuted")
print("PASS: volume parsing, limits, mute behavior, balance, device change, rollback, unsupported controls, dictation lowering")
