import PressyCore
import Testing

/// Device ids and data sources as observed on a MacBook Pro M5 (macOS 27) with and without the Pressy plugged in.
struct AudioRoutePolicyTests {
    let speakers = AudioDeviceSnapshot(id: 91, name: "MacBook Pro Speakers", outputSource: "ispk")
    let internalMic = AudioDeviceSnapshot(id: 98, name: "MacBook Pro Microphone", inputSource: "imic")
    let display = AudioDeviceSnapshot(id: 103, name: "PHL 346E2C")
    let jackHeadphones = AudioDeviceSnapshot(id: 161, name: "External Headphones", outputSource: "hdpn")
    let jackMic = AudioDeviceSnapshot(id: 176, name: "External Microphone", inputSource: "emic")

    var base: [AudioDeviceSnapshot] { [speakers, internalMic, display] }
    var normal: [AudioRole: UInt32] { [.output: 91, .systemOutput: 91, .input: 98] }

    @Test func plugInIsUndoneForOutputThenInput() {
        var policy = AudioRoutePolicy()
        #expect(policy.evaluate(now: 0, devices: base, defaults: normal).isEmpty)

        // macOS switches output when the headphones appear ...
        let withHeadphones = base + [jackHeadphones]
        #expect(policy.evaluate(now: 78.6, devices: withHeadphones, defaults: [.output: 161, .systemOutput: 161, .input: 98])
            == [.output: 91, .systemOutput: 91])
        #expect(policy.evaluate(now: 78.7, devices: withHeadphones, defaults: normal).isEmpty)

        // ... and the input about 2.5 s later, when the mic is detected.
        let withMic = withHeadphones + [jackMic]
        #expect(policy.evaluate(now: 81.1, devices: withMic, defaults: [.output: 91, .systemOutput: 91, .input: 176]) == [.input: 98])
    }

    @Test func restoresThePreviousDeviceNotJustTheBuiltIn() {
        var policy = AudioRoutePolicy()
        _ = policy.evaluate(now: 0, devices: base, defaults: [.output: 103, .systemOutput: 91, .input: 98])
        let result = policy.evaluate(now: 10, devices: base + [jackHeadphones], defaults: [.output: 161, .systemOutput: 161, .input: 98])
        #expect(result == [.output: 103, .systemOutput: 91])
    }

    @Test func choosingTheJackByHandLaterIsLeftAlone() {
        var policy = AudioRoutePolicy(window: 5)
        _ = policy.evaluate(now: 0, devices: base, defaults: normal)
        _ = policy.evaluate(now: 10, devices: base + [jackHeadphones], defaults: normal)
        #expect(policy.evaluate(now: 30, devices: base + [jackHeadphones], defaults: [.output: 161, .systemOutput: 91, .input: 98]).isEmpty)
    }

    @Test func pressyAlreadyPluggedInAtStartFallsBackToBuiltIn() {
        var policy = AudioRoutePolicy()
        let result = policy.evaluate(now: 0, devices: base + [jackHeadphones, jackMic], defaults: [.output: 161, .systemOutput: 161, .input: 176])
        #expect(result == [.output: 91, .systemOutput: 91, .input: 98])
    }

    @Test func vanishedPreviousDeviceFallsBackToBuiltIn() {
        var policy = AudioRoutePolicy()
        _ = policy.evaluate(now: 0, devices: base, defaults: [.output: 103, .systemOutput: 91, .input: 98])
        let withoutDisplay = [speakers, internalMic, jackHeadphones]
        #expect(policy.evaluate(now: 10, devices: withoutDisplay, defaults: [.output: 161, .systemOutput: 91, .input: 98]) == [.output: 91])
    }

    @Test func rePluggedJackGetsANewIdAndIsHandledAgain() {
        var policy = AudioRoutePolicy()
        _ = policy.evaluate(now: 0, devices: base, defaults: normal)
        _ = policy.evaluate(now: 10, devices: base + [jackHeadphones], defaults: [.output: 161, .systemOutput: 161, .input: 98])
        _ = policy.evaluate(now: 20, devices: base, defaults: normal)
        let replugged = AudioDeviceSnapshot(id: 182, name: "External Headphones", outputSource: "hdpn")
        #expect(policy.evaluate(now: 60, devices: base + [replugged], defaults: [.output: 182, .systemOutput: 91, .input: 98]) == [.output: 91])
    }
}
