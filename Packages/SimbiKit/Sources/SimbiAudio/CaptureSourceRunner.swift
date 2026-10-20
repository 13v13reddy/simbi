import Foundation
import SimbiKit
import os

/// Hardware start/stop runs off the mixing clock and main actor. A successful
/// start never establishes health; only real converted buffers do.
final class CaptureSourceRunner: @unchecked Sendable {
    struct Handle: Sendable {
        let stream: AsyncStream<[Float]>
        let stop: @Sendable () -> Void
    }

    private struct State {
        var active = true
        var generation = 0
        var phase: CaptureSourceHealth.State = .starting
        var receivedSamples = 0
        var lastSampleTime: TimeInterval?
        var attemptStarted: TimeInterval
        var nextRetry: TimeInterval
        var attempts = 0
        var opening = true
        var ended = false
    }

    private let source: RecordingSource
    private let policy: RecordingHealthPolicy
    private let state: OSAllocatedUnfairLock<State>
    private let queue: DispatchQueue
    private let makeHandle: @Sendable () throws -> Handle
    private let onSamples: @Sendable ([Float]) -> Void
    // Owned exclusively by the hardware queue.
    private var handle: Handle?
    private var consumer: Task<Void, Never>?

    init(
        source: RecordingSource, policy: RecordingHealthPolicy,
        makeHandle: @escaping @Sendable () throws -> Handle,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) {
        self.source = source
        self.policy = policy
        self.makeHandle = makeHandle
        self.onSamples = onSamples
        let now = ProcessInfo.processInfo.systemUptime
        state = OSAllocatedUnfairLock(initialState: State(attemptStarted: now, nextRetry: now))
        queue = DispatchQueue(label: "app.getsimbi.mac.capture.\(source.rawValue)")
        queue.async { [self] in open(generation: 0) }
    }

    var snapshot: CaptureSourceHealth {
        state.withLock {
            CaptureSourceHealth(
                source: source, state: $0.phase, receivedSamples: $0.receivedSamples,
                lastSampleTime: $0.lastSampleTime, recoveryAttempts: $0.attempts)
        }
    }

    func poll(now: TimeInterval) {
        let (generation, exhausted): (Int?, Bool) = state.withLock { value in
            guard value.active, value.phase != .unavailable else { return (nil, false) }
            let reference = max(value.lastSampleTime ?? value.attemptStarted, value.attemptStarted)
            guard value.ended || now - reference >= policy.sourceTimeout else { return (nil, false) }
            value.phase = .recovering
            guard !value.opening, now >= value.nextRetry else { return (nil, false) }
            value.generation += 1
            if value.attempts >= policy.maxRecoveryAttempts {
                value.phase = .unavailable
                return (nil, true)
            }
            value.attempts += 1
            value.opening = true
            value.ended = false
            value.attemptStarted = now
            value.nextRetry = now + policy.retryDelay
            return (value.generation, false)
        }
        if exhausted {
            RecordingDiagnostics.error("\(source.name) unavailable after bounded recovery attempts")
            queue.async { [self] in closeHandle() }
        } else if let generation {
            RecordingDiagnostics.warning("\(source.name) stopped delivering buffers; restarting capture")
            queue.async { [self] in open(generation: generation) }
        }
    }

    func retry() {
        let generation: Int? = state.withLock { value in
            guard value.active, value.phase != .active else { return nil }
            value.generation += 1
            value.attempts = 0
            value.phase = .recovering
            value.opening = true
            value.ended = false
            value.attemptStarted = ProcessInfo.processInfo.systemUptime
            return value.generation
        }
        if let generation { queue.async { [self] in open(generation: generation) } }
    }

    func stop() {
        state.withLock {
            $0.active = false
            $0.generation += 1
        }
        // Do not block the UI or the healthy source on a stuck hardware API.
        queue.async { [self] in closeHandle() }
    }

    private func closeHandle() {
        consumer?.cancel()
        consumer = nil
        handle?.stop()
        handle = nil
    }

    private func open(generation: Int) {
        closeHandle()
        guard state.withLock({ $0.active && $0.generation == generation }) else { return }
        do {
            let opened = try makeHandle()
            guard state.withLock({ $0.active && $0.generation == generation }) else {
                opened.stop()
                return
            }
            handle = opened
            state.withLock { if $0.generation == generation { $0.opening = false } }
            consumer = Task(priority: .userInitiated) { [weak self] in
                for await samples in opened.stream {
                    guard !Task.isCancelled, let self else { break }
                    receive(samples, generation: generation)
                }
                self?.streamEnded(generation: generation)
            }
        } catch {
            RecordingDiagnostics.warning("\(source.name) capture could not start: \(error)")
            streamEnded(generation: generation)
        }
    }

    private func receive(_ samples: [Float], generation: Int) {
        guard !samples.isEmpty else { return }
        let (accepted, recovered) = state.withLock { value in
            guard value.active, value.generation == generation else { return (false, false) }
            let recovered = value.phase != .active && value.attempts > 0
            value.phase = .active
            value.receivedSamples += samples.count
            value.lastSampleTime = ProcessInfo.processInfo.systemUptime
            value.attempts = 0
            value.ended = false
            return (true, recovered)
        }
        guard accepted else { return }
        if recovered { RecordingDiagnostics.info("\(source.name) is delivering audio again") }
        onSamples(samples)
    }

    private func streamEnded(generation: Int) {
        state.withLock { value in
            guard value.active, value.generation == generation else { return }
            value.opening = false
            value.ended = true
            value.phase = .recovering
            value.nextRetry = ProcessInfo.processInfo.systemUptime + policy.retryDelay
        }
    }
}
