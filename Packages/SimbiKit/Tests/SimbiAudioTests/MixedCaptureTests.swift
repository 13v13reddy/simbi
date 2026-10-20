import Foundation
import SimbiAudio
import Testing

@Suite("MixedCapture")
struct MixedCaptureTests {
    private let fastPolicy = RecordingHealthPolicy(
        startupTimeout: 0.3, sourceTimeout: 0.08, writeTimeout: 0.2,
        retryDelay: 0.01, maxRecoveryAttempts: 2, checkInterval: 0.01)

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test("a stalled microphone is retried without restarting healthy system audio")
    func recoversUnannouncedMicrophoneStall() async throws {
        let mic = ControlledAudioSource(value: 0.1)
        let system = ControlledAudioSource(value: 0.2)
        let capture = MixedCapture(
            makeMicrophoneCapture: { mic }, makeSystemCapture: { system }, policy: fastPolicy)
        _ = try capture.startBatches(config: .init())
        defer { capture.stop() }
        try await waitUntil { capture.sourceHealth.allSatisfy { $0.state == .active } }
        mic.paused = true  // No device-change notification; start still reports success.
        try await waitUntil {
            capture.sourceHealth.contains { $0.source == .microphone && $0.state == .unavailable }
        }
        #expect(capture.sourceHealth.contains { $0.source == .systemAudio && $0.state == .active })
        #expect(system.startCount == 1)
        #expect(mic.startCount == 3)
        try await Task.sleep(for: .milliseconds(100))
        #expect(mic.startCount == 3)

        mic.paused = false
        capture.retryUnavailableSources()
        try await waitUntil { capture.sourceHealth.allSatisfy { $0.state == .active } }
        #expect(system.startCount == 1)
    }

    @Test("real zero-valued buffers are healthy; synthesized timing silence is not")
    func distinguishesQuietInputFromMissingBuffers() async throws {
        let quiet = ControlledAudioSource(value: 0)
        let capture = MixedCapture(
            makeMicrophoneCapture: { quiet }, policy: fastPolicy)
        let stream = try capture.startBatches(config: .init(systemAudioEnabled: false))
        let collector = ProvenanceCollector()
        let task = Task { for await batch in stream { await collector.append(batch) } }
        try await waitUntil { capture.sourceHealth.first?.receivedSamples ?? 0 > 0 }
        try await Task.sleep(for: .milliseconds(80))
        #expect(capture.sourceHealth.first?.state == .active)
        capture.stop()
        await task.value
        #expect(await collector.captured > 0)
        #expect(await collector.hasNonzero == false)

        let missing = MixedCapture(makeMicrophoneCapture: { QuietMicrophone() }, policy: fastPolicy)
        let emptyStream = try missing.startBatches(config: .init(systemAudioEnabled: false))
        let empty = ProvenanceCollector()
        let emptyTask = Task { for await batch in emptyStream { await empty.append(batch) } }
        try await Task.sleep(for: .milliseconds(100))
        missing.stop()
        await emptyTask.value
        #expect(await empty.captured == 0)
        #expect(await empty.generated > 0)
    }

    @Test("system audio keeps flowing when microphone startup succeeds without any buffers")
    func systemAudioSurvivesSilentMicrophone() async throws {
        let microphone = QuietMicrophone()
        let system = FakeSystemCapture(samples: [Float](repeating: 0.25, count: 1_600))
        let capture = MixedCapture(
            makeMicrophoneCapture: { microphone }, makeSystemCapture: { system })
        let stream = try capture.start(config: .init())
        let collector = MixedBatchCollector()
        let task = Task {
            for await batch in stream { await collector.append(batch) }
        }
        try await Task.sleep(for: .milliseconds(150))
        capture.stop()
        await task.value

        #expect(await collector.hasAudio)
    }

    /// Silent injected system source (no real tap, no audible audio).
    final class FakeSystemCapture: SystemCapturing, @unchecked Sendable {
        private let samples: [Float]
        private var continuation: AsyncStream<[Float]>.Continuation?

        init(samples: [Float]) {
            self.samples = samples
        }

        func start() throws -> AsyncStream<[Float]> {
            let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
            continuation.yield(samples)
            self.continuation = continuation
            return stream
        }

        func stop() {
            continuation?.finish()
            continuation = nil
        }
    }

    @Test("system-only config streams the system source without the mic")
    func systemOnly() async throws {
        let fake = FakeSystemCapture(samples: [0.1, 0.2])
        let capture = MixedCapture(makeSystemCapture: { fake })
        let stream = try capture.start(
            config: .init(micEnabled: false, systemAudioEnabled: true))

        var received: [Float] = []
        for await batch in stream {
            received += batch
            break
        }
        capture.stop()
        #expect(received.count >= 2)
        #expect(abs(received[0] - tanhf(0.1)) < 0.0001)
        #expect(abs(received[1] - tanhf(0.2)) < 0.0001)
        #expect(!capture.systemAudioActive)
    }

    @Test("all sources disabled is refused")
    func noSources() {
        let capture = MixedCapture()
        #expect(throws: MixedCapture.MixedCaptureError.self) {
            _ = try capture.start(
                config: .init(micEnabled: false, systemAudioEnabled: false))
        }
    }
}

private actor ProvenanceCollector {
    var captured = 0
    var generated = 0
    var hasNonzero = false

    func append(_ batch: CapturedAudioBatch) {
        captured += batch.capturedSampleCount
        generated += batch.samples.count - batch.capturedSampleCount
        hasNonzero = hasNonzero || batch.samples.contains { $0 != 0 }
    }
}

private final class ControlledAudioSource: MicrophoneCapturing, SystemCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "simbi.test-audio-source")
    private var timer: DispatchSourceTimer?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var shouldPause = false
    private var starts = 0
    private let value: Float

    init(value: Float) { self.value = value }

    var startCount: Int { lock.withLock { starts } }
    var paused: Bool {
        get { lock.withLock { shouldPause } }
        set { lock.withLock { shouldPause = newValue } }
    }

    func start(deviceUID: String?) throws -> AsyncStream<[Float]> { try start() }

    func start() throws -> AsyncStream<[Float]> {
        lock.withLock {
            starts += 1
            let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
            self.continuation = continuation
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                lock.withLock {
                    if !shouldPause { self.continuation?.yield([Float](repeating: value, count: 320)) }
                }
            }
            self.timer = timer
            timer.resume()
            return stream
        }
    }

    func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
            continuation?.finish()
            continuation = nil
        }
    }
}

private final class QuietMicrophone: MicrophoneCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<[Float]>.Continuation?

    func start(deviceUID: String?) throws -> AsyncStream<[Float]> {
        lock.withLock {
            let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
            self.continuation = continuation
            return stream
        }
    }

    func stop() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }
}

private actor MixedBatchCollector {
    var hasAudio = false

    func append(_ batch: [Float]) {
        hasAudio = hasAudio || batch.contains { $0 != 0 }
    }
}
