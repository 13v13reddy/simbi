import Foundation
import os

public protocol RecordingAudioWriting: AnyObject {
    func append(samples: [Float]) throws
    func flush() throws
    @discardableResult func finish() throws -> UInt64
}

extension OpusWebMEncoder: RecordingAudioWriting {}

/// Observed without awaiting the pipeline actor: a stuck model or write must
/// not block the health check that reports the stall.
public final class RecordingWriteProgress: Sendable {
    public struct Snapshot: Sendable {
        public var baseSamples = 0
        public var writtenSamples = 0
        public var capturedSamples = 0
        public var initialBytes: UInt64 = 0
        public var fileBytes: UInt64 = 0
        public var lastWriteTime: TimeInterval?
        public var lastCapturedWriteTime: TimeInterval?

        public var elapsed: TimeInterval {
            Double(baseSamples + writtenSamples) / Double(CutConstants.sampleRate)
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    public init() {}

    public var snapshot: Snapshot { state.withLock { $0 } }

    func reset(baseSamples: Int) {
        state.withLock { $0 = Snapshot(baseSamples: baseSamples) }
    }

    func opened(bytes: UInt64) {
        state.withLock {
            $0.initialBytes = bytes
            $0.fileBytes = bytes
        }
    }

    func wrote(samples: Int, capturedSamples: Int, fileBytes: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock {
            $0.writtenSamples += samples
            $0.capturedSamples += capturedSamples
            if fileBytes > $0.fileBytes {
                $0.lastWriteTime = now
                if capturedSamples > 0 { $0.lastCapturedWriteTime = now }
            }
            $0.fileBytes = fileBytes
        }
    }
}
