import AVFoundation
import Foundation
import SimbiKit

/// The hardware-facing seam behind `MicCapture`. Keeping route recovery in
/// `MicCapture` lets tests simulate a device disappearing without touching
/// the machine's real microphone.
protocol MicInputEngine: AnyObject {
    var configurationChangeObject: AnyObject { get }
    var isRunning: Bool { get }

    func start(
        deviceUID: String?, onSamples: @escaping @Sendable ([Float]) -> Void
    ) throws
    func stop()
}

/// Microphone capture (SPEC.md §3.1): AVAudioEngine input-node tap,
/// converted to the pipeline format (16 kHz mono Float32) and delivered as
/// an AsyncStream of sample batches. `MixedCapture` mixes this stream with
/// the system-audio tap's.
public final class MicCapture: @unchecked Sendable {
    public enum CaptureError: Error {
        case permissionDenied
        case converterUnavailable
        case inputUnavailable
        /// The requested device UID isn't connected (or refused selection).
        case deviceUnavailable
    }

    private let engine: any MicInputEngine
    private let notificationCenter: NotificationCenter
    private let recoveryQueue = DispatchQueue(label: "app.getsimbi.mac.mic-recovery")
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var configurationObserver: NSObjectProtocol?
    private var retryWorkItem: DispatchWorkItem?
    private var retryAttempt = 0
    private var requestedDeviceUID: String?
    private var active = false

    public convenience init() {
        self.init(engine: AVAudioMicInputEngine(), notificationCenter: .default)
    }

    init(engine: any MicInputEngine, notificationCenter: NotificationCenter) {
        self.engine = engine
        self.notificationCenter = notificationCenter
    }

    /// Starts the tap and returns the 16 kHz mono batch stream. The stream
    /// finishes when `stop()` is called. `deviceUID` selects a specific
    /// input device; nil follows the system default.
    public func start(deviceUID: String? = nil) throws -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        do {
            try recoveryQueue.sync {
                self.continuation = continuation
                requestedDeviceUID = deviceUID
                active = true
                observeConfigurationChanges()
                do {
                    try startEngine()
                } catch {
                    tearDown()
                    throw error
                }
            }
        } catch {
            continuation.finish()
            throw error
        }
        return stream
    }

    /// Stops the tap and finishes the stream (delivering everything already
    /// yielded first — the pipeline drains before its stop sequence).
    public func stop() {
        recoveryQueue.sync { tearDown() }
    }

    private func observeConfigurationChanges() {
        configurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine.configurationChangeObject,
            queue: nil
        ) { [weak self] _ in
            // Apple posts this on an internal audio queue and warns against
            // tearing the engine down there. Hop to our serial queue first.
            self?.recoverAfterConfigurationChange()
        }
    }

    private func recoverAfterConfigurationChange() {
        recoveryQueue.async { [weak self] in
            guard let self, active, !engine.isRunning else { return }
            retryWorkItem?.cancel()
            retryWorkItem = nil
            retryAttempt = 0
            attemptRecovery()
        }
    }

    private func attemptRecovery() {
        guard active, !engine.isRunning else { return }
        engine.stop()
        do {
            try startEngine()
            retryAttempt = 0
            retryWorkItem = nil
            Log.recording.info("microphone capture recovered after audio device change")
        } catch {
            Log.recording.warning(
                "microphone input is not ready after audio device change; retrying: \(error)")
            scheduleRecoveryRetry()
        }
    }

    private func scheduleRecoveryRetry() {
        let exponent = min(retryAttempt, 4)
        let delayMilliseconds = min(100 * (1 << exponent), 1_600)
        retryAttempt += 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            retryWorkItem = nil
            attemptRecovery()
        }
        retryWorkItem?.cancel()
        retryWorkItem = workItem
        recoveryQueue.asyncAfter(
            deadline: .now() + .milliseconds(delayMilliseconds), execute: workItem)
    }

    private func startEngine() throws {
        guard let continuation else { return }
        try engine.start(deviceUID: requestedDeviceUID) { samples in
            continuation.yield(samples)
        }
    }

    private func tearDown() {
        active = false
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryAttempt = 0
        if let configurationObserver {
            notificationCenter.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.stop()
        continuation?.finish()
        continuation = nil
        requestedDeviceUID = nil
    }
}

/// AVAudioEngine implementation used in production. Every start reads the
/// current hardware format again, so a recovered engine gets a fresh tap and
/// converter for the replacement input device.
final class AVAudioMicInputEngine: MicInputEngine, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var tapInstalled = false

    var configurationChangeObject: AnyObject { engine }
    var isRunning: Bool { engine.isRunning }

    /// Selects the device and returns the format used by the tap and converter.
    /// Kept separate from starting capture so format negotiation can be tested
    /// without opening a microphone recording.
    func configureInput(deviceUID: String?) throws -> (AVAudioInputNode, AVAudioFormat) {
        let input = engine.inputNode
        // Must happen before the first format query — selecting the device
        // changes the input node's hardware format. Resolve the default on
        // every start so unplugging headphones moves capture to the built-in
        // microphone instead of retaining the vanished device.
        let deviceID: AudioDeviceID?
        if let deviceUID, let selected = AudioInputDevices.deviceID(forUID: deviceUID) {
            deviceID = selected
        } else {
            deviceID = AudioInputDevices.defaultDeviceID()
        }
        if var deviceID {
            guard let audioUnit = input.audioUnit,
                AudioUnitSetProperty(
                    audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            else {
                throw MicCapture.CaptureError.deviceUnavailable
            }
        }

        // The output scope can retain the previous device's rate after
        // selection (e.g. 96 kHz speakers and a 48 kHz mic). Input nodes
        // cannot convert formats: the tap must match the hardware scope.
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicCapture.CaptureError.inputUnavailable
        }
        return (input, inputFormat)
    }

    func start(
        deviceUID: String?, onSamples: @escaping @Sendable ([Float]) -> Void
    ) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MicCapture.CaptureError.permissionDenied
        }
        let (input, inputFormat) = try configureInput(deviceUID: deviceUID)
        guard
            let targetFormat = AudioResampling.pipelineFormat,
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            throw MicCapture.CaptureError.converterUnavailable
        }

        let block: AVAudioNodeTapBlock = { buffer, _ in
            guard
                let samples = AudioResampling.convert(
                    buffer, using: converter, to: targetFormat)
            else { return }
            onSamples(samples)
        }
        #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                try input.__installTap(
                    onBus: 0, bufferSize: 1024, format: inputFormat, error: (), block: block)
            } else {
                input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat, block: block)
            }
        #else
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat, block: block)
        #endif
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        engine.reset()
    }
}
