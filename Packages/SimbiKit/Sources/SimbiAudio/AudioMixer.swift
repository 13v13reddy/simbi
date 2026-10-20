import Foundation
import SimbiKit
import os

/// Bounded per-source FIFOs consumed by the independent mixing clock. Missing
/// input is zero filled; a microphone stall never gates system-audio delivery.
public struct AudioMixer: Sendable {
    public var micGain: Float
    public var systemGain: Float
    public let maxBacklogSamples: Int

    private var microphone: [Float] = []
    private var microphoneStart = 0
    private var fifo: [Float] = []
    /// Read position into `fifo` (compacted lazily, avoids O(n) removeFirst).
    private var fifoStart = 0

    public init(
        micGain: Float = 1, systemGain: Float = 1,
        maxBacklogSamples: Int = CutConstants.sampleRate  // one second
    ) {
        self.micGain = micGain
        self.systemGain = systemGain
        self.maxBacklogSamples = maxBacklogSamples
    }

    /// Test seam: MixedCaptureTests asserts the backlog bound.
    public var backlog: Int { fifo.count - fifoStart }

    public mutating func pushSystem(_ samples: [Float]) {
        fifo.append(contentsOf: samples)
        let excess = backlog - maxBacklogSamples
        if excess > 0 {
            fifoStart += excess
        }
        if fifoStart > maxBacklogSamples {
            fifo.removeFirst(fifoStart)
            fifoStart = 0
        }
    }

    public mutating func pushMicrophone(_ samples: [Float]) {
        microphone.append(contentsOf: samples)
        let excess = microphone.count - microphoneStart - maxBacklogSamples
        if excess > 0 { microphoneStart += excess }
        if microphoneStart > maxBacklogSamples {
            microphone.removeFirst(microphoneStart)
            microphoneStart = 0
        }
    }

    public var bufferedSamples: Int { max(microphone.count - microphoneStart, backlog) }

    public mutating func mix(frameCount: Int) -> CapturedAudioBatch {
        let microphoneCount = min(frameCount, microphone.count - microphoneStart)
        let systemCount = min(frameCount, backlog)
        var output = [Float](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let mic = index < microphoneCount ? microphone[microphoneStart + index] : 0
            let system = index < systemCount ? fifo[fifoStart + index] : 0
            output[index] = Self.softClip(micGain * mic + systemGain * system)
        }
        microphoneStart += microphoneCount
        fifoStart += systemCount
        if microphoneStart > maxBacklogSamples {
            microphone.removeFirst(microphoneStart)
            microphoneStart = 0
        }
        if fifoStart > maxBacklogSamples {
            fifo.removeFirst(fifoStart)
            fifoStart = 0
        }
        return CapturedAudioBatch(
            samples: output, microphoneSamples: microphoneCount, systemAudioSamples: systemCount)
    }

    public mutating func mix(mic: [Float]) -> [Float] {
        pushMicrophone(mic)
        return mix(frameCount: mic.count).samples
    }

    /// tanh soft-clip: bounded to (-1, 1), ~linear for normal speech levels.
    public static func softClip(_ x: Float) -> Float {
        tanhf(x)
    }
}
