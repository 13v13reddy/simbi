import Foundation

/// Monotonic deadlines. Shorter policies let fault tests exercise the real timers.
public struct RecordingHealthPolicy: Sendable {
    public var startupTimeout: TimeInterval
    public var sourceTimeout: TimeInterval
    public var writeTimeout: TimeInterval
    public var retryDelay: TimeInterval
    public var maxRecoveryAttempts: Int
    public var checkInterval: TimeInterval
    public var preparationTimeout: TimeInterval

    public init(
        startupTimeout: TimeInterval = 5, sourceTimeout: TimeInterval = 3,
        writeTimeout: TimeInterval = 5, retryDelay: TimeInterval = 0.5,
        maxRecoveryAttempts: Int = 3, checkInterval: TimeInterval = 0.25,
        preparationTimeout: TimeInterval = 30
    ) {
        self.startupTimeout = startupTimeout
        self.sourceTimeout = sourceTimeout
        self.writeTimeout = writeTimeout
        self.retryDelay = retryDelay
        self.maxRecoveryAttempts = maxRecoveryAttempts
        self.checkInterval = checkInterval
        self.preparationTimeout = preparationTimeout
    }
}

public enum RecordingSource: String, Codable, Sendable, CaseIterable {
    case microphone
    case systemAudio

    public var name: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System audio"
        }
    }
}

public struct CaptureSourceHealth: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case starting, active, recovering, unavailable
    }

    public let source: RecordingSource
    public let state: State
    public let receivedSamples: Int
    public let lastSampleTime: TimeInterval?
    public let recoveryAttempts: Int
    /// Completed recoveries survive brief state transitions between UI checks.
    public let recoveryCount: Int
}

/// Provenance survives zero filling: real, quiet input counts as captured audio;
/// samples synthesized for a missing source never do.
public struct CapturedAudioBatch: Sendable {
    public let samples: [Float]
    public let microphoneSamples: Int
    public let systemAudioSamples: Int

    public var capturedSampleCount: Int { max(microphoneSamples, systemAudioSamples) }
}

public protocol RecordingCapturing: Sendable {
    func startBatches(config: MixedCapture.Config) throws -> AsyncStream<CapturedAudioBatch>
    func stop()
    func retryUnavailableSources()
    var sourceHealth: [CaptureSourceHealth] { get }
    var producedSamples: Int { get }
}

public protocol MicrophoneCapturing: Sendable {
    func start(deviceUID: String?) throws -> AsyncStream<[Float]>
    func stop()
}

extension MicCapture: MicrophoneCapturing {}

public protocol SystemCapturing: Sendable {
    func start() throws -> AsyncStream<[Float]>
    func stop()
}

@available(macOS 14.4, *)
extension SystemAudioCapture: SystemCapturing {}
