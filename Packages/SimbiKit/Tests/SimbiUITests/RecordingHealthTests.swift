import AppKit
import FluidAudio
import Foundation
import SimbiAudio
import SimbiKit
import SwiftUI
import Testing

@testable import SimbiUI

@Suite("Recording health", .serialized)
@MainActor
struct RecordingHealthTests {
    private let activity = RecordingActivity()
    private let policy = RecordingHealthPolicy(
        startupTimeout: 0.7, sourceTimeout: 0.4, writeTimeout: 0.4,
        retryDelay: 0.02, maxRecoveryAttempts: 1, checkInterval: 0.02)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "simbi-health-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func controller(
        folder: URL, source: HealthInput, notices: HealthNotices, system: HealthInput? = nil,
        diarizer: any DiarizerStream = HealthDiarizer(), healthPolicy: RecordingHealthPolicy? = nil,
        microphonePermission: Bool = true,
        makeWriter: @escaping @Sendable (URL, OpusWebMEncoder.Mode) throws -> any RecordingAudioWriting = {
            try OpusWebMEncoder(fileURL: $0, mode: $1)
        }
    ) -> (RecordingController, RecordingPipeline) {
        let policy = healthPolicy ?? self.policy
        let pipeline = RecordingPipeline(
            noteFolderURL: folder, transcriber: HealthTranscriber(),
            diarizer: diarizer, vad: HealthVad(), makeEncoder: makeWriter)
        let controller = RecordingController(
            noteFolderURL: folder, pipeline: pipeline,
            makeCapture: { [policy] in
                MixedCapture(
                    makeMicrophoneCapture: { source }, makeSystemCapture: { system ?? source }, policy: policy)
            },
            requestMicrophoneAccess: { microphonePermission }, healthPolicy: policy, notifier: notices,
            activity: activity)
        controller.systemAudioEnabled = system != nil
        controller.micEnabled = true
        return (controller, pipeline)
    }

    @Test("saved transcript failures remain visible after reopening and Retry never starts capture")
    func retrySavedTranscriptWithoutRecording() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = VTT.fileURL(noteFolder: folder)
        let outbox = TranscriptOutbox(
            fileURL: transcript, noteName: "Test",
            journalURL: NoteLayout.stateDirURL(noteFolder: folder).appending(path: "transcript-outbox.json"))
        try outbox.reserveCue(index: 1, start: 0, end: 2, speaker: "Speaker 1", continuation: false)
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try outbox.fulfillCue(index: 1, text: "saved result") }
        let source = HealthInput()
        let notices = HealthNotices()
        let (recorder, _) = controller(folder: folder, source: source, notices: notices)
        try await waitUntil { recorder.problem == .transcriptSaveFailed }
        #expect(recorder.status == .idle)
        #expect(source.startCount == 0)
        #expect(activity.problem?.problem == .transcriptSaveFailed)
        #expect(notices.posted.contains(.transcriptSaveFailed))
        try await waitUntil { StoredRecordingProblem.load(noteFolder: folder) == .transcriptSaveFailed }
        try renderBannerIfRequested(recorder, name: "transcript-save-failed")
        try FileManager.default.removeItem(at: transcript)
        recorder.retryRecording()
        try await waitUntil { recorder.problem == nil }
        #expect(recorder.status == .idle)
        #expect(source.startCount == 0)
        let text = try String(contentsOf: transcript, encoding: .utf8)
        #expect(text.contains("saved result"))
    }

    @Test("microphone permission denial preserves healthy system audio")
    func deniedMicrophonePreservesSystemAudio() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = HealthInput()
        mic.paused = true
        let system = HealthInput()
        let (recorder, pipeline) = controller(
            folder: folder, source: mic, notices: HealthNotices(), system: system,
            microphonePermission: false)
        recorder.startRecording()
        try await waitUntil { recorder.status == .recording && recorder.problem == .microphonePermissionFallback }
        #expect(pipeline.writeProgress.snapshot.capturedSamples > 0)
        mic.paused = false
        recorder.retryRecording()
        try await waitUntil { recorder.problem == .sourceRecovered(.microphone) }
        recorder.dismissProblem()
        #expect(recorder.status == .recording)
        await recorder.stopRecording()
    }

    @Test("a saved upload failure is visible and Retry Transcription never opens capture")
    func retriesTranscriptionWithoutRecording() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pending = NoteLayout.pendingDirURL(noteFolder: folder)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let encoder = try OpusWebMEncoder(fileURL: pending.appending(path: "1.webm"), mode: .create)
        try encoder.append(samples: [Float](repeating: 0.1, count: 16_000))
        try encoder.finish()
        let sidecar: [String: Any] = [
            "cueIndex": 1, "startSec": 0, "endSec": 1, "speaker": 0,
            "continuation": false, "transcriptionFailed": true,
        ]
        try JSONSerialization.data(withJSONObject: sidecar).write(to: pending.appending(path: "1.json"))
        let source = HealthInput()
        let notices = HealthNotices()
        let (recorder, pipeline) = controller(folder: folder, source: source, notices: notices)
        try await waitUntil { recorder.problem == .transcriptionFailed }
        #expect(notices.posted.contains(.transcriptionFailed))
        #expect(activity.problem?.problem == .transcriptionFailed)
        #expect(RecordingProblem.transcriptionFailed.retryTitle(isCapturing: false) == "Retry Transcription")
        try renderBannerIfRequested(recorder, name: "transcription-failed")
        recorder.retryRecording()
        try await waitUntil { recorder.problem == nil }
        #expect(source.startCount == 0)
        #expect(recorder.status == .idle)
        #expect(await pipeline.isTranscriptDrained)
    }

    @Test("Quit finalizes an active recording without firing post-recording AI jobs")
    func quitFinalizesRecording() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (recorder, _) = controller(folder: folder, source: HealthInput(), notices: HealthNotices())
        var generated = false
        recorder.onRecordingStopped = { generated = true }
        recorder.startRecording()
        try await waitUntil { recorder.status == .recording }
        #expect(await recorder.finishForQuit())
        #expect(recorder.status == .idle)
        #expect(NoteRecordingState.current(noteFolder: folder).activeSession == nil)
        #expect(try OpusWebMDecoder(fileURL: NoteLayout.audioURL(noteFolder: folder)).endMilliseconds > 0)
        #expect(!generated)
    }

    @Test("Quit cancels preparation without allowing a late ghost recording")
    func quitDuringPreparation() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = HealthInput()
        let (recorder, pipeline) = controller(
            folder: folder, source: source, notices: HealthNotices(), diarizer: DelayedHealthDiarizer())
        recorder.startRecording()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.finishForQuit())
        try await Task.sleep(for: .milliseconds(450))
        #expect(source.startCount == 0)
        #expect(await !pipeline.isRecording)
        #expect(NoteRecordingState.current(noteFolder: folder).activeSession == nil)
    }

    @Test("late preparation cannot start a ghost recording after its deadline")
    func preparationDeadlineAndLateCompletion() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = HealthInput()
        let notices = HealthNotices()
        var short = policy
        short.preparationTimeout = 0.2
        let (recorder, pipeline) = controller(
            folder: folder, source: source, notices: notices,
            diarizer: DelayedHealthDiarizer(), healthPolicy: short)
        recorder.startRecording()
        try await waitUntil { notices.posted.contains(.startupFailed) }
        #expect(source.startCount == 0)
        try await waitUntil { if case .failed = recorder.status { true } else { false } }
        #expect(await pipeline.isRecording == false)
        #expect(source.startCount == 0)
        recorder.startRecording()
        try await waitUntil { recorder.status == .recording }
        await recorder.stopRecording()
    }

    @Test("a writer that makes slow progress still fails when its audio backlog grows")
    func detectsGrowingWriteBacklog() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fault = WriterFault()
        let notices = HealthNotices()
        let (recorder, _) = controller(
            folder: folder, source: HealthInput(), notices: notices,
            makeWriter: { try FaultWriter(url: $0, mode: $1, fault: fault) })
        recorder.startRecording()
        try await waitUntil { recorder.status == .recording }
        fault.delaySeconds = 0.06  // Continues to write, but falls behind 20 ms input batches.
        try await waitUntil { if case .failed = recorder.status { true } else { false } }
        #expect(recorder.problem == .writeStalled)
        #expect(notices.posted.contains(.writeStalled))
    }

    private func renderBannerIfRequested(_ recorder: RecordingController, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SIMBI_RECORDING_UI_ARTIFACTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for width in [480.0, 720.0] {
            let view = NSHostingView(
                rootView: RecordingProblemBanner(recorder: recorder)
                    .frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
            let height = max(100, view.fittingSize.height)
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(
                contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: root.appending(path: "\(name)-\(Int(width)).png"))
            window.contentView = nil
        }
    }

    @Test("a missing microphone remains visible while system audio is saved and recovers on retry")
    func degradedRecordingPreservesHealthySource() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = HealthInput()
        mic.paused = true
        let system = HealthInput()
        let notices = HealthNotices()
        let (recorder, pipeline) = controller(folder: folder, source: mic, notices: notices, system: system)
        recorder.startRecording()
        try await waitUntil { recorder.status == .recording && recorder.problem?.source == .microphone }
        let saved = pipeline.writeProgress.snapshot.writtenSamples
        try await Task.sleep(for: .milliseconds(80))
        #expect(pipeline.writeProgress.snapshot.writtenSamples > saved)
        #expect(recorder.problem?.isFatal == false)
        #expect(system.startCount == 1)
        try renderBannerIfRequested(recorder, name: "source-unavailable")
        mic.paused = false
        recorder.retryRecording()
        try await waitUntil { recorder.problem == .sourceRecovered(.microphone) }
        try await waitUntil { StoredRecordingProblem.load(noteFolder: folder) == .sourceRecovered(.microphone) }
        recorder.dismissProblem()
        #expect(recorder.status == .recording)
        #expect(system.startCount == 1)
        await recorder.stopRecording()
    }

    @Test("no file growth cannot be mistaken for a verified recording")
    func requiresActualFileGrowth() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fault = WriterFault()
        fault.discardWrites = true
        let (recorder, _) = controller(
            folder: folder, source: HealthInput(), notices: HealthNotices(),
            makeWriter: { try FaultWriter(url: $0, mode: $1, fault: fault) })
        recorder.startRecording()
        try await waitUntil { if case .failed = recorder.status { true } else { false } }
        #expect(!recorder.hasRecording)
        #expect(recorder.problem == .writeStalled)
    }

    @Test("the watchdog reports blocked disk IO without awaiting the pipeline actor")
    func detectsBlockedWriter() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fault = WriterFault()
        let notices = HealthNotices()
        let (recorder, _) = controller(
            folder: folder, source: HealthInput(), notices: notices,
            makeWriter: { try FaultWriter(url: $0, mode: $1, fault: fault) })
        recorder.startRecording()
        try await waitUntil { recorder.status == .recording }
        fault.delaySeconds = 0.8
        try await waitUntil { notices.posted.contains(.writeStalled) }
        #expect(recorder.isFinalizing)
        try await waitUntil { if case .failed = recorder.status { true } else { false } }
        #expect(recorder.problem == .writeStalled)
        #expect(NoteRecordingState.current(noteFolder: folder).activeSession == nil)
    }

    @Test("startup stays preparing until real quiet samples are written")
    func startupRequiresSavedAudio() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = HealthInput()
        input.paused = true
        let (recorder, pipeline) = controller(folder: folder, source: input, notices: HealthNotices())
        recorder.startRecording()
        try await waitUntil { input.startCount > 0 }
        #expect(recorder.status == .preparing)
        #expect(pipeline.writeProgress.snapshot.capturedSamples == 0)
        input.paused = false  // Emits zeros: a quiet room is valid input.
        try await waitUntil { recorder.status == .recording }
        #expect(pipeline.writeProgress.snapshot.capturedSamples > 0)
        #expect(try Data(contentsOf: NoteLayout.audioURL(noteFolder: folder)).count > 163)
        await recorder.stopRecording()
        #expect(recorder.status == .idle)
    }

    @Test("a no-buffer startup fails visibly, cleans up, and can be retried after reopening")
    func missingBuffersAreNotSilent() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = HealthInput()
        input.paused = true
        let notices = HealthNotices()
        let (recorder, pipeline) = controller(folder: folder, source: input, notices: notices)
        recorder.startRecording()
        try await waitUntil { if case .failed = recorder.status { true } else { false } }
        #expect(recorder.problem == .noAudio)
        #expect(notices.posted == [.noAudio])
        #expect(activity.problem?.noteFolderURL == folder)
        #expect(activity.problem?.problem == .noAudio)
        #expect(await pipeline.isRecording == false)
        #expect(NoteRecordingState.current(noteFolder: folder).activeSession == nil)
        try await waitUntil { StoredRecordingProblem.load(noteFolder: folder) == .noAudio }
        try renderBannerIfRequested(recorder, name: "no-audio")
        let reopened = controller(folder: folder, source: HealthInput(), notices: HealthNotices()).0
        #expect(reopened.problem == .noAudio)

        reopened.retryRecording()
        try await waitUntil { reopened.status == .recording }
        #expect(reopened.problem == nil)
        await reopened.stopRecording()
        #expect(reopened.status == .idle)
    }

    @Test("an unannounced mid-recording stall is reported and partial audio remains valid")
    func detectsUnannouncedStall() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = HealthInput()
        let notices = HealthNotices()
        let (recorder, _) = controller(folder: folder, source: input, notices: notices)
        recorder.startRecording()
        try await waitUntil { recorder.status == .recording }
        input.paused = true
        try await waitUntil { if case .failed = recorder.status { true } else { false } }
        #expect(recorder.problem == .noAudio)
        #expect(notices.posted.contains(.noAudio))
        let decoder = try OpusWebMDecoder(fileURL: NoteLayout.audioURL(noteFolder: folder))
        #expect(decoder.endMilliseconds > 0)
        #expect(NoteRecordingState.current(noteFolder: folder).activeSession == nil)
    }

    @Test("writer failure is reported without leaving a live session behind")
    func detectsWriteFailureAndRetries() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = HealthInput()
        let notices = HealthNotices()
        let fault = WriterFault()
        let (recorder, pipeline) = controller(
            folder: folder, source: input, notices: notices,
            makeWriter: { try FaultWriter(url: $0, mode: $1, fault: fault) })
        recorder.startRecording()
        try await waitUntil { recorder.status == .recording }
        fault.enabled = true
        try await waitUntil { if case .failed = recorder.status { true } else { false } }
        #expect(recorder.problem == .recordingFailed)
        #expect(notices.posted.contains(.recordingFailed))
        #expect(await pipeline.isRecording == false)
        #expect(NoteRecordingState.current(noteFolder: folder).activeSession == nil)
        fault.enabled = false
        recorder.startRecording()
        try await waitUntil { recorder.status == .recording }
        await recorder.stopRecording()
        #expect(recorder.status == .idle)
    }

    @Test("a late capture error reaches the menubar without a one-second poll")
    func reportsLateFailure() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = HealthInput()
        let notices = HealthNotices()
        let (recorder, _) = controller(folder: folder, source: input, notices: notices)
        recorder.startRecording()
        try await waitUntil { recorder.status == .recording }
        try await Task.sleep(for: .milliseconds(1_050))
        input.paused = true
        try await waitUntil { if case .failed = recorder.status { true } else { false } }
        #expect(activity.problem?.problem == .noAudio)
        #expect(notices.posted.contains(.noAudio))
    }
}

@MainActor
private final class HealthNotices: RecordingNotifying {
    var posted: [RecordingProblem] = []
    func prepare() {}
    func post(problem: RecordingProblem, noteFolderURL: URL) { posted.append(problem) }
    func clear(noteFolderURL: URL) {}
}

private final class HealthInput: MicrophoneCapturing, SystemCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var pause = false
    private var starts = 0
    var startCount: Int { lock.withLock { starts } }
    var paused: Bool {
        get { lock.withLock { pause } }
        set { lock.withLock { pause = newValue } }
    }
    func start(deviceUID: String?) throws -> AsyncStream<[Float]> { try start() }
    func start() throws -> AsyncStream<[Float]> {
        lock.withLock {
            starts += 1
            let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
            self.continuation = continuation
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                lock.withLock {
                    if !pause { self.continuation?.yield([Float](repeating: 0, count: 320)) }
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

private final class WriterFault: @unchecked Sendable {
    private let lock = NSLock()
    private var fault = false
    private var discard = false
    private var delay: TimeInterval = 0
    var enabled: Bool {
        get { lock.withLock { fault } }
        set { lock.withLock { fault = newValue } }
    }
    var discardWrites: Bool {
        get { lock.withLock { discard } }
        set { lock.withLock { discard = newValue } }
    }
    var delaySeconds: TimeInterval {
        get { lock.withLock { delay } }
        set { lock.withLock { delay = newValue } }
    }
}

private final class FaultWriter: RecordingAudioWriting {
    private let actual: OpusWebMEncoder
    private let fault: WriterFault
    init(url: URL, mode: OpusWebMEncoder.Mode, fault: WriterFault) throws {
        actual = try OpusWebMEncoder(fileURL: url, mode: mode)
        self.fault = fault
    }
    func append(samples: [Float]) throws {
        if fault.delaySeconds > 0 { Thread.sleep(forTimeInterval: fault.delaySeconds) }
        if fault.enabled { throw OpusWebMError.muxWriteFailed }
        if fault.discardWrites { return }
        try actual.append(samples: samples)
    }
    func flush() throws { try actual.flush() }
    func finish() throws -> UInt64 { try actual.finish() }
}

private struct HealthTranscriber: Transcriber {
    func transcribe(webmFile: URL) async throws -> String { "" }
}
private final class HealthDiarizer: DiarizerStream, @unchecked Sendable {
    func prepare() async throws {}
    func resetSession() {}
    func addAudio(_ samples: [Float]) {}
    func process() throws -> DiarizerChunkResult? { nil }
    func finalizeSession() throws -> DiarizerChunkResult? { nil }
}

private final class DelayedHealthDiarizer: DiarizerStream, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func prepare() async throws {
        let first = lock.withLock {
            calls += 1
            return calls == 1
        }
        if first {
            // Deliberately ignores cancellation until a late result arrives.
            await Task.detached { try? await Task.sleep(for: .milliseconds(400)) }.value
        }
    }
    func resetSession() {}
    func addAudio(_ samples: [Float]) {}
    func process() throws -> DiarizerChunkResult? { nil }
    func finalizeSession() throws -> DiarizerChunkResult? { nil }
}
private final class HealthVad: VadStream, @unchecked Sendable {
    func prepare() async throws {}
    func resetSession() {}
    func addAudio(_ samples: [Float]) async throws -> [Bool] { [] }
}
