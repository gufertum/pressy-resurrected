import Foundation
import IOKit.hid

enum HeadsetError: Error, CustomStringConvertible {
    case heldByAnotherProcess
    case openFailed(IOReturn)
    case notFound

    var description: String {
        switch self {
        case .heldByAnotherProcess:
            "the Headset HID device is held by another process; is the LaunchAgent running? "
                + "Stop it first: launchctl bootout gui/\(getuid())/li.sudo.pressy"
        case .openFailed(let code):
            String(format: "opening the Headset HID device failed: IOReturn 0x%08X", code)
        case .notFound:
            "no built-in Headset HID device (Transport=Audio, Product=Headset); this Mac's jack may not decode inline-remote buttons"
        }
    }
}

/// The jack's inline-remote decoder: the built-in "Headset" HID device (CS42L84 "Mikey" on Apple silicon).
/// It is seized, so macOS does not also turn a press into the system Play/Pause key.
@MainActor
final class HeadsetButton {
    private static let exclusiveAccess = IOReturn(bitPattern: 0xE000_02C5)
    private static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    /// Called with `true` on press and `false` on release; the time is in seconds since boot.
    var onEdge: ((_ down: Bool, _ time: TimeInterval) -> Void)?

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    func open() throws(HeadsetError) {
        // One matching dictionary only: a device matching several is reported, and its values delivered, once per match.
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDTransportKey: "Audio", kIOHIDProductKey: "Headset"] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
            Log.info("hid device matched", ["product": HeadsetButton.property(device, kIOHIDProductKey)])
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, device in
            Log.warn("hid device removed", ["product": HeadsetButton.property(device, kIOHIDProductKey)])
        }, nil)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<HeadsetButton>.fromOpaque(context).takeUnretainedValue().handle(value)
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if result == Self.exclusiveAccess { throw .heldByAnotherProcess }
        if result != kIOReturnSuccess { throw .openFailed(result) }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        if devices.isEmpty { throw .notFound }
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_Consumer),
              IOHIDElementGetUsage(element) == UInt32(kHIDUsage_Csmr_PlayOrPause) else { return }
        let seconds = Double(IOHIDValueGetTimeStamp(value)) * Self.nanosPerTick / 1e9
        onEdge?(IOHIDValueGetIntegerValue(value) != 0, seconds)
    }

    nonisolated static func property(_ device: IOHIDDevice, _ key: String) -> String {
        IOHIDDeviceGetProperty(device, key as CFString).map { "\($0)" } ?? "?"
    }
}
