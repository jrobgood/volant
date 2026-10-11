import Foundation
import CoreAudio

/// Reports changes to the default output device while a lowered device is waiting to be restored.
protocol AudioOutputChangeMonitoring: AnyObject {
    func start(_ onChange: @escaping () -> Void)
    func stop()
}

/// Lowers the default output while dictation listens and puts it back afterward.
///
/// The level is captured and lowered through `AudioHardwareAccess`, the same reads and writes the
/// volume commands use, so stereo balance is kept by scaling every channel together and mute is
/// never written. Lowering is best effort: an unsupported, muted or nearly silent output is left
/// alone and nothing here can stop dictation. Restoring checks that the lowered device is still
/// connected and still at the level written, so a level the user chose during dictation is kept
/// and an output that replaced the original is never touched. Only a restore that should have
/// happened but could not is reported.
final class DictationVolumeDuck {
    static let quietFraction: Float32 = 0.2
    static let tolerance: Float32 = 0.02

    private struct Lowered {
        let device: AudioDeviceID
        let uid: String?
        let name: String
        let original: [(channel: UInt32, value: Float32)]
        let written: [(channel: UInt32, value: Float32)]
        let readback: [(channel: UInt32, value: Float32)]
    }

    private let hardware: AudioHardwareAccess
    private let monitor: AudioOutputChangeMonitoring?
    private var lowered: Lowered?

    /// Receives a restore problem found outside `restore()`, after the output changed mid-session.
    var onProblem: ((String) -> Void)?
    var isLowered: Bool { lowered != nil }

    init(hardware: AudioHardwareAccess = CoreAudioHardware(), monitor: AudioOutputChangeMonitoring? = DefaultOutputMonitor()) {
        self.hardware = hardware
        self.monitor = monitor
    }

    /// Lowers the current default output to `quietFraction` of its level. Returns a message only
    /// when a partial lowering could not be undone and the output may have been left quieter.
    @discardableResult func lower() -> String? {
        guard lowered == nil, let state = try? hardware.output(), state.canSetVolume, state.muted != true,
              let level = state.level, !state.volumes.isEmpty,
              level - level * Self.quietFraction > Self.tolerance else { return nil }
        let written = state.volumes.map { (channel: $0.channel, value: $0.value * Self.quietFraction) }
        var changed: [(channel: UInt32, value: Float32)] = []
        for (volume, target) in zip(state.volumes, written) {
            do {
                try hardware.setVolume(target.value, channel: volume.channel, device: state.device)
                changed.append(volume)
            } catch {
                guard write(changed, device: state.device) else {
                    return "Couldn’t fully lower \(state.name) for dictation and it may be quieter now. Check its volume."
                }
                return nil
            }
        }
        let readback = (try? hardware.output(of: state.device))?.volumes ?? written
        lowered = Lowered(device: state.device, uid: state.uid, name: state.name, original: state.volumes, written: written, readback: readback)
        monitor?.start { [weak self] in self?.outputChanged() }
        return nil
    }

    /// Puts the lowered device back to its prior level when it is still connected and nobody has
    /// changed its volume since. Returns a message when it should have been restored but was not.
    @discardableResult func restore() -> String? {
        guard let lowered else { return nil }
        self.lowered = nil
        monitor?.stop()
        guard let state = try? hardware.output(of: lowered.device),
              lowered.uid == nil || state.uid == nil || lowered.uid == state.uid else {
            return "\(lowered.name) disconnected during dictation, so its volume wasn’t restored. Check its volume when you reconnect it."
        }
        guard Self.unchanged(state.volumes, since: lowered) else { return nil }
        guard state.canSetVolume, write(lowered.original, device: lowered.device) else {
            return "Couldn’t restore \(lowered.name)’s volume after dictation. Check its volume."
        }
        return nil
    }

    /// Restores the lowered device as soon as sound moves to another output, rather than leaving it
    /// quiet until dictation ends. The new output is never lowered or changed.
    func outputChanged() {
        guard let lowered else { return }
        if let current = try? hardware.output(), current.device == lowered.device,
           lowered.uid == nil || current.uid == nil || lowered.uid == current.uid { return }
        if let problem = restore() { onProblem?(problem) }
    }

    /// Writes every channel, continuing past failures so as much as possible is restored.
    private func write(_ volumes: [(channel: UInt32, value: Float32)], device: AudioDeviceID) -> Bool {
        var succeeded = true
        for volume in volumes {
            do { try hardware.setVolume(volume.value, channel: volume.channel, device: device) } catch { succeeded = false }
        }
        return succeeded
    }

    /// True when each channel still reads as the level written, or as the device reported it just
    /// after the write, since some hardware rounds scalar volume to its own steps.
    private static func unchanged(_ volumes: [(channel: UInt32, value: Float32)], since lowered: Lowered) -> Bool {
        guard volumes.map(\.channel) == lowered.written.map(\.channel) else { return false }
        return volumes.allSatisfy { volume in
            [lowered.written, lowered.readback].contains { expected in
                expected.contains { $0.channel == volume.channel && abs($0.value - volume.value) <= tolerance }
            }
        }
    }
}

/// Listens for default output changes through CoreAudio, delivering them on the main queue.
final class DefaultOutputMonitor: AudioOutputChangeMonitoring {
    private var listener: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)

    /// Registers one listener, replacing any earlier one. A failed registration only means the
    /// lowered device is restored when dictation ends instead of when the output changes.
    func start(_ onChange: @escaping () -> Void) {
        stop()
        let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr else { return }
        self.listener = listener
    }

    /// Removes the listener, if one is registered.
    func stop() {
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        self.listener = nil
    }

    deinit { stop() }
}
