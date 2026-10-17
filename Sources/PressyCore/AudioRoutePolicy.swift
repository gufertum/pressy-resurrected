import Foundation

public enum AudioRole: String, CaseIterable, Sendable {
    case output, systemOutput, input
}

/// What pressy needs to know about one CoreAudio device. Sources are the device's current
/// data-source FourCCs, e.g. "hdpn" (jack headphones), "ispk" (built-in speakers), "emic", "imic".
public struct AudioDeviceSnapshot: Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let outputSource: String?
    public let inputSource: String?

    public init(id: UInt32, name: String, outputSource: String? = nil, inputSource: String? = nil) {
        self.id = id
        self.name = name
        self.outputSource = outputSource
        self.inputSource = inputSource
    }

    func source(for role: AudioRole) -> String? { role == .input ? inputSource : outputSource }
}

/// Decides when to undo the automatic switch macOS performs when something is plugged into the jack.
/// The Pressy looks like a headset, so macOS routes sound to silent "headphones" and takes the
/// microphone from a mic that does not exist. Only a switch to a jack device that appeared within
/// `window` is undone; picking the jack device by hand later is left alone.
public struct AudioRoutePolicy: Sendable {
    static let jackSource: [AudioRole: String] = [.output: "hdpn", .systemOutput: "hdpn", .input: "emic"]
    static let builtinSource: [AudioRole: String] = [.output: "ispk", .systemOutput: "ispk", .input: "imic"]

    public var window: TimeInterval
    private var known: Set<UInt32> = []
    private var appearedAt: [UInt32: TimeInterval] = [:]
    private var lastGood: [AudioRole: UInt32] = [:]

    public init(window: TimeInterval = 5) { self.window = window }

    /// Returns the default device to set per role; empty when nothing needs to change.
    /// Devices present on the first call count as just appeared, so a Pressy already plugged in at start is handled too.
    public mutating func evaluate(now: TimeInterval, devices: [AudioDeviceSnapshot], defaults: [AudioRole: UInt32]) -> [AudioRole: UInt32] {
        let ids = Set(devices.map(\.id))
        for id in ids.subtracting(known) { appearedAt[id] = now }
        for id in known.subtracting(ids) { appearedAt[id] = nil }
        known = ids

        var switches: [AudioRole: UInt32] = [:]
        for role in AudioRole.allCases {
            guard let current = defaults[role], let device = devices.first(where: { $0.id == current }) else { continue }
            guard device.source(for: role) == Self.jackSource[role] else {
                lastGood[role] = current
                continue
            }
            guard let appeared = appearedAt[current], now - appeared <= window else { continue }
            let previous = lastGood[role].flatMap { id in devices.first { $0.id == id } }
            let fallback = devices.first { $0.source(for: role) == Self.builtinSource[role] }
            if let target = previous ?? fallback, target.id != current {
                switches[role] = target.id
            }
        }
        return switches
    }
}
