import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import SimbiAudio

@Suite("CaptureSessionMicrophone", .serialized)
struct CaptureSessionMicrophoneTests {
    // Opt in only with permission granted to the runner. This creates and
    // destroys a private route; it never changes the system's default devices.
    @Test(
        "captures real microphone samples after the engine's device disappears",
        .enabled(if: ProcessInfo.processInfo.environment["SIMBI_TEST_MICROPHONE"] == "1"))
    func recoversDestroyedEngineRoute() async throws {
        let route = try TemporaryAudioRoute()
        let engine = AVAudioMicInputEngine()
        let (input, _) = try engine.configureInput(deviceUID: nil)
        let outputUnit = try #require(input.engine?.outputNode.audioUnit)
        var device = route.deviceID
        try #require(
            AudioUnitSetProperty(
                outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr)
        try route.invalidate()

        let primary = MicCapture(engine: engine, notificationCenter: .default)
        let capture = MixedCapture(
            makeMicrophoneCapture: { primary },
            makeMicrophoneRecoveryCapture: { CaptureSessionMicrophone() },
            policy: RecordingHealthPolicy(sourceTimeout: 0.5, retryDelay: 0.05))
        _ = try capture.startBatches(config: .init(systemAudioEnabled: false))
        defer { capture.stop() }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let health = capture.sourceHealth.first,
                health.state == .active, health.recoveryCount > 0, health.receivedSamples > 0
            {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The independent backend never delivered microphone samples after route loss")
    }

    @Test(
        "fallback can restart and use the default when a saved microphone is disconnected",
        .enabled(if: ProcessInfo.processInfo.environment["SIMBI_TEST_MICROPHONE"] == "1"))
    func restartsFallback() async throws {
        let capture = CaptureSessionMicrophone()
        defer { capture.stop() }
        let selectedUID = try #require(AVCaptureDevice.default(for: .audio)?.uniqueID)
        for uid in [selectedUID, "simbi-test-disconnected-microphone", nil] as [String?] {
            let stream = try capture.start(deviceUID: uid)
            let batch = await withTaskGroup(of: [Float]?.self) { group in
                group.addTask {
                    for await batch in stream where !batch.isEmpty { return batch }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    return nil
                }
                let batch = await group.next() ?? nil
                group.cancelAll()
                return batch
            }
            #expect(batch?.isEmpty == false)
            capture.stop()
        }
    }

    @Test("converts capture-session PCM and renegotiates when the input format changes")
    func convertsPCMWithFormatChanges() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        let target = try #require(AudioResampling.pipelineFormat)
        let receiver = CaptureSessionMicrophone.SampleReceiver(targetFormat: target, continuation: continuation)
        for rate in [48_000.0, 44_100.0] {
            let format = try #require(
                AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 2, interleaved: true))
            for _ in 0..<3 {
                receiver.receive(try sampleBuffer(format: format))
            }
        }
        continuation.finish()
        var batches = [[Float]]()
        for await batch in stream { batches.append(batch) }
        #expect(batches.count == 6)
        #expect(batches.allSatisfy { $0.count > 200 && $0.count < 400 })
        #expect(batches.allSatisfy { $0.allSatisfy { $0.isFinite } })
        // Sample-rate conversion has a short filter transient at startup
        // and after the format change. Check the settled PCM amplitude.
        #expect(batches.allSatisfy { $0.dropFirst(64).allSatisfy { abs($0 - 0.25) < 0.01 } })
    }

    private func sampleBuffer(format: AVAudioFormat) throws -> CMSampleBuffer {
        let frames = 1_024
        let values = [Int16](repeating: 8_192, count: frames * Int(format.channelCount))
        let byteCount = values.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        #expect(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr)
        let data = try #require(block)
        let status = values.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: byteCount)
        }
        #expect(status == noErr)
        var sample: CMSampleBuffer?
        #expect(
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: format.formatDescription,
                sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil,
                sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
}

private final class TemporaryAudioRoute {
    private(set) var deviceID = AudioDeviceID(kAudioObjectUnknown)

    init() throws {
        let input = try #require(AudioInputDevices.defaultDeviceID())
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var output = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try #require(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &output) == noErr)
        let outputUID = try Self.uid(output)
        let inputUID = try Self.uid(input)
        var subdevices: [[String: Any]] = [
            [kAudioSubDeviceUIDKey: inputUID, kAudioSubDeviceDriftCompensationKey: true]
        ]
        if outputUID != inputUID { subdevices.append([kAudioSubDeviceUIDKey: outputUID]) }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Simbi Microphone Recovery Test",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
        ]
        try #require(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID) == noErr)
    }

    deinit {
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
    }

    func invalidate() throws {
        try #require(AudioHardwareDestroyAggregateDevice(deviceID) == noErr)
        deviceID = AudioDeviceID(kAudioObjectUnknown)
    }

    private static func uid(_ device: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        try #require(status == noErr)
        return try #require(value) as String
    }
}
