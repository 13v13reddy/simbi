@preconcurrency import AVFoundation
import Foundation

/// Recovery backend independent of AVAudioEngine's cached input/output route.
/// Opened by the source watchdog only after the primary mic stops delivering
/// samples. Each attempt resolves the selected device again; later stalls use
/// the same bounded recovery as every other recording source.
final class CaptureSessionMicrophone: MicrophoneCapturing, @unchecked Sendable {
    private enum CaptureError: Error {
        case configurationUnavailable
    }

    // Lifecycle is confined to CaptureSourceRunner's hardware queue. Sample
    // conversion belongs to a separate receiver on the serial delegate queue.
    private let session = AVCaptureSession()
    private let sampleQueue = DispatchQueue(label: "app.getsimbi.mac.mic-session-samples")
    private var output: AVCaptureAudioDataOutput?
    private var receiver: SampleReceiver?
    private var continuation: AsyncStream<[Float]>.Continuation?

    deinit { stop() }

    func start(deviceUID: String?) throws -> AsyncStream<[Float]> {
        stop()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MicCapture.CaptureError.permissionDenied
        }
        let device: AVCaptureDevice?
        if let deviceUID, AudioInputDevices.deviceID(forUID: deviceUID) != nil {
            device = AVCaptureDevice(uniqueID: deviceUID)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device,
            device.isConnected, device.hasMediaType(.audio)
        else { throw MicCapture.CaptureError.inputUnavailable }
        let input = try AVCaptureDeviceInput(device: device)
        guard let targetFormat = AudioResampling.pipelineFormat else {
            throw MicCapture.CaptureError.converterUnavailable
        }
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        let receiver = SampleReceiver(targetFormat: targetFormat, continuation: continuation)
        self.receiver = receiver
        let output = AVCaptureAudioDataOutput()
        self.output = output
        output.setSampleBufferDelegate(receiver, queue: sampleQueue)

        do {
            try configure(input: input, output: output)
            session.startRunning()
            guard session.isRunning else { throw CaptureError.configurationUnavailable }
        } catch {
            stop()
            throw error
        }
        return stream
    }

    private func configure(input: AVCaptureDeviceInput, output: AVCaptureAudioDataOutput) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw CaptureError.configurationUnavailable }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw CaptureError.configurationUnavailable }
        session.addOutput(output)
    }

    func stop() {
        output?.setSampleBufferDelegate(nil, queue: nil)
        session.stopRunning()
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
        // Late delegate callbacks can only yield into this finished stream;
        // they cannot touch a subsequent attempt's receiver or converter.
        continuation?.finish()
        continuation = nil
        receiver = nil
        output = nil
    }

    final class SampleReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        private let targetFormat: AVAudioFormat
        private let continuation: AsyncStream<[Float]>.Continuation
        private var converter: AVAudioConverter?

        init(targetFormat: AVAudioFormat, continuation: AsyncStream<[Float]>.Continuation) {
            self.targetFormat = targetFormat
            self.continuation = continuation
        }

        func captureOutput(
            _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            receive(sampleBuffer)
        }

        // Runs only on the delegate queue. The device can change its PCM
        // format mid-session, so rebuild the converter when that happens.
        func receive(_ sampleBuffer: CMSampleBuffer) {
            let count = sampleBuffer.numSamples
            guard count > 0, count <= Int(Int32.max),
                let description = sampleBuffer.formatDescription,
                let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                let format = AVAudioFormat(streamDescription: streamDescription),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
            else { return }
            buffer.frameLength = AVAudioFrameCount(count)
            guard
                CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sampleBuffer, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList) == noErr
            else { return }
            if converter?.inputFormat != format {
                converter = AVAudioConverter(from: format, to: targetFormat)
            }
            guard let converter,
                let samples = AudioResampling.convert(buffer, using: converter, to: targetFormat)
            else { return }
            continuation.yield(samples)
        }
    }
}
