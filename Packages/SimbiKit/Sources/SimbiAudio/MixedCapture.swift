import Foundation
import SimbiKit

/// A wall-clock mixer. Missing sources contribute timing silence without
/// preventing the other source from being recorded. Health counts only actual
/// input buffers, independently of the mixed timeline.
public final class MixedCapture: RecordingCapturing, @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        public var micEnabled: Bool
        public var micDeviceUID: String?
        public var systemAudioEnabled: Bool

        public init(
            micEnabled: Bool = true, micDeviceUID: String? = nil,
            systemAudioEnabled: Bool = true
        ) {
            self.micEnabled = micEnabled
            self.micDeviceUID = micDeviceUID
            self.systemAudioEnabled = systemAudioEnabled
        }
    }

    public enum MixedCaptureError: Error {
        case systemAudioUnsupported
        case noSourcesEnabled
        case alreadyCapturing
    }

    private let queue = DispatchQueue(label: "app.getsimbi.mac.mixing-clock")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let makeMicrophoneCapture: @Sendable () -> any MicrophoneCapturing
    private let makeSystemCapture: @Sendable () throws -> any SystemCapturing
    private let policy: RecordingHealthPolicy
    private var mixer: AudioMixer
    private var sources: [CaptureSourceRunner] = []
    private var timer: DispatchSourceTimer?
    private var continuation: AsyncStream<CapturedAudioBatch>.Continuation?
    private var active = false
    private var clockStartedAt: TimeInterval = 0
    private var emittedSamples = 0

    public init(
        mixer: AudioMixer = AudioMixer(),
        makeMicrophoneCapture: @escaping @Sendable () -> any MicrophoneCapturing = { MicCapture() },
        makeSystemCapture: @escaping @Sendable () throws -> any SystemCapturing = {
            guard #available(macOS 14.4, *) else { throw MixedCaptureError.systemAudioUnsupported }
            return SystemAudioCapture()
        },
        policy: RecordingHealthPolicy = RecordingHealthPolicy()
    ) {
        self.mixer = mixer
        self.makeMicrophoneCapture = makeMicrophoneCapture
        self.makeSystemCapture = makeSystemCapture
        self.policy = policy
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    public var sourceHealth: [CaptureSourceHealth] {
        synchronized { sources.map(\.snapshot) }
    }

    public var producedSamples: Int { synchronized { emittedSamples } }

    public var systemAudioActive: Bool {
        sourceHealth.contains { $0.source == .systemAudio && $0.state == .active }
    }

    public func start(config: Config) throws -> AsyncStream<[Float]> {
        let batches = try startBatches(config: config)
        return AsyncStream { continuation in
            let task = Task {
                for await batch in batches { continuation.yield(batch.samples) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func startBatches(config: Config) throws -> AsyncStream<CapturedAudioBatch> {
        try synchronized {
            guard !active else { throw MixedCaptureError.alreadyCapturing }
            guard config.micEnabled || config.systemAudioEnabled else {
                throw MixedCaptureError.noSourcesEnabled
            }
            let (stream, continuation) = AsyncStream.makeStream(of: CapturedAudioBatch.self)
            self.continuation = continuation
            active = true
            clockStartedAt = ProcessInfo.processInfo.systemUptime
            emittedSamples = 0
            if config.micEnabled {
                let makeMicrophone = makeMicrophoneCapture
                sources.append(
                    CaptureSourceRunner(
                        source: .microphone, policy: policy,
                        makeHandle: {
                            let microphone = makeMicrophone()
                            let stream = try microphone.start(deviceUID: config.micDeviceUID)
                            return .init(stream: stream, stop: { microphone.stop() })
                        },
                        onSamples: { [weak self] in self?.enqueue($0, from: .microphone) }))
            }
            if config.systemAudioEnabled {
                let makeSystem = makeSystemCapture
                sources.append(
                    CaptureSourceRunner(
                        source: .systemAudio, policy: policy,
                        makeHandle: {
                            let system = try makeSystem()
                            let stream = try system.start()
                            return .init(stream: stream, stop: { system.stop() })
                        },
                        onSamples: { [weak self] in self?.enqueue($0, from: .systemAudio) }))
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
            return stream
        }
    }

    private func enqueue(_ samples: [Float], from source: RecordingSource) {
        queue.async { [weak self] in
            guard let self, active else { return }
            switch source {
            case .microphone: mixer.pushMicrophone(samples)
            case .systemAudio: mixer.pushSystem(samples)
            }
        }
    }

    private func tick() {
        guard active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for source in sources { source.poll(now: now) }
        // Catch up coalesced timer events using a monotonic sample clock.
        let frame = OpusWebMFormat.frameSamples
        let expected = Int((now - clockStartedAt) * Double(CutConstants.sampleRate)) / frame * frame
        while emittedSamples < expected {
            let count = min(expected - emittedSamples, CutConstants.sampleRate)
            continuation?.yield(mixer.mix(frameCount: count))
            emittedSamples += count
        }
    }

    public func retryUnavailableSources() {
        synchronized {
            for source in sources { source.retry() }
        }
    }

    public func stop() {
        synchronized {
            guard active else { return }
            active = false
            timer?.cancel()
            timer = nil
            for source in sources { source.stop() }
            sources = []
            if mixer.bufferedSamples > 0 {
                let count = mixer.bufferedSamples
                continuation?.yield(mixer.mix(frameCount: count))
                emittedSamples += count
            }
            continuation?.finish()
            continuation = nil
        }
    }
}
