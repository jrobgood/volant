import Foundation
import CoreAudio

enum VolumeCommand: Hashable {
    case up, down, mute, unmute, set(Int)
    var id: String {
        switch self {
        case .up: return "up"
        case .down: return "down"
        case .mute: return "mute"
        case .unmute: return "unmute"
        case .set(let value): return "set-\(value)"
        }
    }
    var title: String {
        switch self {
        case .up: return "Volume Up"
        case .down: return "Volume Down"
        case .mute: return "Mute Output"
        case .unmute: return "Unmute Output"
        case .set(let value): return "Set Volume to \(value)%"
        }
    }
    static func matches(_ query: String) -> Bool {
        let head = query.lowercased().split(whereSeparator: \.isWhitespace).first ?? ""
        return ["vol", "volume", "mute", "unmute"].contains(String(head))
    }
    static func parse(_ query: String, muted: Bool?) -> [Self] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if words == ["mute"] { return [.mute] }
        if words == ["unmute"] { return [.unmute] }
        guard let first = words.first, ["vol", "volume"].contains(first) else { return [] }
        if words.count == 1 { return [.up, .down, muted == true ? .unmute : .mute] }
        guard words.count == 2 else { return [] }
        let argument = words[1]
        if let value = Int(argument.hasSuffix("%") ? String(argument.dropLast()) : argument), (0...100).contains(value) { return [.set(value)] }
        return [Self.up, .down, .mute, .unmute].filter { $0.id.hasPrefix(argument) }
    }
}

struct AudioOutputState {
    let device: AudioDeviceID
    let name: String
    let volumes: [(channel: UInt32, value: Float32)]
    let canSetVolume: Bool
    let muted: Bool?
    let canSetMute: Bool
    var uid: String?
    var level: Float32? { volumes.map(\.value).max() }
    var summary: String {
        let levelText = level.map { "\(Int(($0 * 100).rounded()))%" } ?? "Volume unavailable"
        return name + " · " + levelText + (muted == true ? " · Muted" : "")
    }
}

protocol AudioHardwareAccess {
    func output() throws -> AudioOutputState
    func output(of device: AudioDeviceID) throws -> AudioOutputState
    func setVolume(_ value: Float32, channel: UInt32, device: AudioDeviceID) throws
    func setMute(_ value: Bool, device: AudioDeviceID) throws
}

extension AudioHardwareAccess {
    /// Reads one specific device. Hardware that only knows the default output can answer only for it.
    func output(of device: AudioDeviceID) throws -> AudioOutputState {
        let state = try output()
        guard state.device == device else { throw VolumeFailure(message: "That audio output is no longer available.") }
        return state
    }
}

struct VolumeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class VolumeControl {
    private let hardware: AudioHardwareAccess
    init(hardware: AudioHardwareAccess = CoreAudioHardware()) { self.hardware = hardware }
    func state() throws -> AudioOutputState { try hardware.output() }

    @discardableResult func perform(_ command: VolumeCommand) throws -> AudioOutputState {
        let state = try hardware.output() // Never use the device or level cached by a search result.
        switch command {
        case .mute, .unmute:
            guard state.canSetMute else { throw VolumeFailure(message: "This output doesn’t support software mute. Use its hardware controls.") }
            try hardware.setMute(command == .mute, device: state.device)
        case .up, .down, .set:
            guard state.canSetVolume, let current = state.level else { throw VolumeFailure(message: "This output doesn’t support software volume. Use its hardware controls.") }
            let target: Float32
            switch command {
            case .up: target = min(1, current + 0.05)
            case .down: target = max(0, current - 0.05)
            case .set(let percent):
                guard (0...100).contains(percent) else { throw VolumeFailure(message: "Enter a volume from 0 to 100%.") }
                target = Float32(percent) / 100
            default: return state
            }
            var changed: [(channel: UInt32, value: Float32)] = []
            do {
                for volume in state.volumes {
                    // Scale channels together to preserve the user's stereo balance.
                    let value = current > 0 ? min(1, volume.value * target / current) : target
                    try hardware.setVolume(value, channel: volume.channel, device: state.device)
                    changed.append(volume)
                }
            } catch {
                var restored = true
                for volume in changed {
                    do { try hardware.setVolume(volume.value, channel: volume.channel, device: state.device) }
                    catch { restored = false }
                }
                throw VolumeFailure(message: restored ? "Couldn’t change output volume. Try again." : "Only part of the volume change succeeded. Check your output’s channel levels.")
            }
        }
        let updated = try hardware.output()
        guard updated.device == state.device else { throw VolumeFailure(message: "The output changed during this action. Check the current output and try again.") }
        // Some devices apply writes asynchronously. Display the actual readback, not an assumed value.
        return updated
    }
}

struct CoreAudioHardware: AudioHardwareAccess {
    private func address(_ selector: AudioObjectPropertySelector, channel: UInt32 = 0, global: Bool = false) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: global ? kAudioObjectPropertyScopeGlobal : kAudioDevicePropertyScopeOutput, mElement: channel)
    }
    private func read<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, into value: inout T) -> Bool {
        var property = property
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0) == noErr && size == MemoryLayout<T>.size }
    }
    private func writable(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) -> Bool {
        var property = property
        var result = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(object, &property, &result) == noErr && result.boolValue
    }
    func output() throws -> AudioOutputState {
        var device = AudioDeviceID(kAudioObjectUnknown)
        guard read(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice, global: true), into: &device), device != kAudioObjectUnknown else {
            throw VolumeFailure(message: "No audio output is available. Connect an output and try again.")
        }
        return state(of: device)
    }
    /// Reads a specific device, which must still be connected. Used to restore a device that is no
    /// longer the default without touching whichever output replaced it.
    func output(of device: AudioDeviceID) throws -> AudioOutputState {
        var alive: UInt32 = 0
        guard device != kAudioObjectUnknown, read(device, address(kAudioDevicePropertyDeviceIsAlive, global: true), into: &alive), alive != 0 else {
            throw VolumeFailure(message: "That audio output is no longer available.")
        }
        return state(of: device)
    }
    /// Reads name, UID, channel volumes and mute for a device the caller has already resolved.
    private func state(of device: AudioDeviceID) -> AudioOutputState {
        var name: CFString = "Audio Output" as CFString
        _ = read(device, address(kAudioObjectPropertyName, global: true), into: &name)
        var uid: CFString = "" as CFString
        let hasUID = read(device, address(kAudioDevicePropertyDeviceUID, global: true), into: &uid)
        var channels: [UInt32] = [0]
        var volume: Float32 = 0
        if !read(device, address(kAudioDevicePropertyVolumeScalar), into: &volume) {
            var stereo: [UInt32] = [1, 2]
            var property = address(kAudioDevicePropertyPreferredChannelsForStereo)
            var size = UInt32(2 * MemoryLayout<UInt32>.size)
            let status = stereo.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0.baseAddress!) }
            channels = status == noErr ? Array(Set(stereo)).sorted() : []
        }
        var volumes: [(channel: UInt32, value: Float32)] = []
        var canSetVolume = !channels.isEmpty
        for channel in channels {
            var value: Float32 = 0
            let property = address(kAudioDevicePropertyVolumeScalar, channel: channel)
            if read(device, property, into: &value), value.isFinite, (0...1).contains(value) { volumes.append((channel, value)) }
            else { canSetVolume = false }
            canSetVolume = canSetVolume && writable(device, property)
        }
        var mute: UInt32 = 0
        let muteProperty = address(kAudioDevicePropertyMute)
        let hasMute = read(device, muteProperty, into: &mute)
        return AudioOutputState(device: device, name: name as String, volumes: volumes, canSetVolume: canSetVolume, muted: hasMute ? mute != 0 : nil, canSetMute: hasMute && writable(device, muteProperty), uid: hasUID && !(uid as String).isEmpty ? uid as String : nil)
    }
    private func write<T>(_ value: T, device: AudioDeviceID, property: AudioObjectPropertyAddress) throws {
        var property = property
        guard writable(device, property) else { throw VolumeFailure(message: "This output control is unavailable.") }
        var value = value
        let status = withUnsafePointer(to: &value) { AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
        guard status == noErr else {
            throw VolumeFailure(message: "Couldn’t change this output. It may have disconnected or become unavailable.")
        }
    }
    func setVolume(_ value: Float32, channel: UInt32, device: AudioDeviceID) throws {
        try write(value, device: device, property: address(kAudioDevicePropertyVolumeScalar, channel: channel))
    }
    func setMute(_ value: Bool, device: AudioDeviceID) throws {
        try write(UInt32(value ? 1 : 0), device: device, property: address(kAudioDevicePropertyMute))
    }
}
