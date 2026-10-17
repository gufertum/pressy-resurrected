import AudioToolbox
import CoreAudio
import Foundation
import PressyCore

struct AudioHardwareError: Error, CustomStringConvertible {
    let description: String
}

/// Thin CoreAudio wrapper: device list, defaults, mute and volume.
enum AudioHardware {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func snapshot() -> [AudioDeviceSnapshot] {
        deviceIDs().map { id in
            AudioDeviceSnapshot(id: id, name: name(of: id),
                                outputSource: dataSource(of: id, scope: kAudioObjectPropertyScopeOutput),
                                inputSource: dataSource(of: id, scope: kAudioObjectPropertyScopeInput))
        }
    }

    static func defaultDevice(_ role: AudioRole) -> AudioObjectID? {
        getUInt32(system, selector(for: role), kAudioObjectPropertyScopeGlobal).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func setDefaultDevice(_ role: AudioRole, to id: AudioObjectID) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector(for: role), mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = id
        return AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
    }

    /// Toggles mute of the default output or input device and returns the new state.
    static func toggleMute(input: Bool) throws(AudioHardwareError) -> (device: String, muted: Bool) {
        let role: AudioRole = input ? .input : .output
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        guard let device = defaultDevice(role) else { throw AudioHardwareError(description: "no default \(role.rawValue) device") }
        guard let muted = getUInt32(device, kAudioDevicePropertyMute, scope) else {
            throw AudioHardwareError(description: "\"\(name(of: device))\" has no mute control")
        }
        let status = setUInt32(device, kAudioDevicePropertyMute, scope, muted == 0 ? 1 : 0)
        guard status == noErr else { throw AudioHardwareError(description: "setting mute on \"\(name(of: device))\" failed: OSStatus \(status)") }
        return (name(of: device), muted == 0)
    }

    /// Changes the output volume by `delta` (0...1 scale); turning it up also unmutes, like the volume keys do.
    static func changeOutputVolume(by delta: Float32) throws(AudioHardwareError) -> (device: String, volume: Float32) {
        guard let device = defaultDevice(.output) else { throw AudioHardwareError(description: "no default output device") }
        let scope = kAudioObjectPropertyScopeOutput
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else {
            throw AudioHardwareError(description: "\"\(name(of: device))\" has no volume control")
        }
        volume = min(1, max(0, volume + delta))
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &volume)
        guard status == noErr else { throw AudioHardwareError(description: "setting volume on \"\(name(of: device))\" failed: OSStatus \(status)") }
        if delta > 0, getUInt32(device, kAudioDevicePropertyMute, scope) == 1 {
            _ = setUInt32(device, kAudioDevicePropertyMute, scope, 0)
        }
        return (name(of: device), volume)
    }

    static func name(of id: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return "device \(id)" }
        return name.takeRetainedValue() as String
    }

    static func selector(for role: AudioRole) -> AudioObjectPropertySelector {
        switch role {
        case .output: kAudioHardwarePropertyDefaultOutputDevice
        case .systemOutput: kAudioHardwarePropertyDefaultSystemOutputDevice
        case .input: kAudioHardwarePropertyDefaultInputDevice
        }
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func dataSource(of id: AudioObjectID, scope: AudioObjectPropertyScope) -> String? {
        getUInt32(id, kAudioDevicePropertyDataSource, scope).flatMap(fourCC)
    }

    private static func fourCC(_ value: UInt32) -> String? {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func getUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                                  _ value: UInt32) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = value
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

/// Watches the device list and the default devices and applies `AudioRoutePolicy`.
@MainActor
final class AudioRouteGuard {
    private var policy = AudioRoutePolicy()

    func start() {
        let selectors = [kAudioHardwarePropertyDevices] + AudioRole.allCases.map(AudioHardware.selector)
        for selector in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            if status != noErr { Log.error("audio listener failed", ["selector": selector, "status": status]) }
        }
        evaluate()
    }

    private func evaluate() {
        let devices = AudioHardware.snapshot()
        var defaults: [AudioRole: UInt32] = [:]
        for role in AudioRole.allCases { defaults[role] = AudioHardware.defaultDevice(role) }
        let switches = policy.evaluate(now: ProcessInfo.processInfo.systemUptime, devices: devices, defaults: defaults)
        for role in AudioRole.allCases {
            guard let target = switches[role] else { continue }
            let from = defaults[role].map(AudioHardware.name) ?? "?"
            let to = AudioHardware.name(of: target)
            let status = AudioHardware.setDefaultDevice(role, to: target)
            if status == noErr {
                Log.info("audio route restored", ["role": role.rawValue, "from": from, "to": to])
            } else {
                Log.error("audio route restore failed", ["role": role.rawValue, "from": from, "to": to, "status": status])
            }
        }
    }
}
