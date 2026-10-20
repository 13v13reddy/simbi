import Foundation
import Testing

@testable import CodexKit
@testable import SimbiAudio
@testable import SimbiKit

@Suite("Transcription retry")
struct TranscriptionRetryTests {
    @Test("failed uploads retain audio and retry once, including after relaunch", arguments: [false, true])
    func retainsFailedAudio(reopen: Bool) async throws {
        let note = FileManager.default.temporaryDirectory.appending(path: "transcription-retry-\(UUID())")
        try FileManager.default.createDirectory(at: note, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: note) }
        let transcriber = RetryTranscriber()
        func makePipeline() -> RecordingPipeline {
            RecordingPipeline(
                noteFolderURL: note, transcriber: transcriber,
                diarizer: FakeDiarizer { _ in .speech(slot: 0) }, vad: FakeVad { _ in true })
        }
        let pipeline = makePipeline()
        try await pipeline.start()
        try await pipeline.ingest(samples: [Float](repeating: 0.1, count: 32_000))
        try await pipeline.stop()
        for _ in 0..<800 {
            if await transcriber.calls >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        let pending = NoteLayout.pendingDirURL(noteFolder: note)
        #expect(FileManager.default.fileExists(atPath: pending.appending(path: "1.webm").path))
        #expect(FileManager.default.fileExists(atPath: pending.appending(path: "1.json").path))
        #expect(!(try String(contentsOf: VTT.fileURL(noteFolder: note), encoding: .utf8)).contains("[inaudible]"))
        #expect(await !pipeline.isTranscriptDrained)
        #expect(await pipeline.transcriptionFailed)
        let stateBefore = NoteRecordingState.current(noteFolder: note)
        let audioBefore = try Data(contentsOf: NoteLayout.audioURL(noteFolder: note))
        let recovering = reopen ? makePipeline() : pipeline
        await recovering.retryTranscriptSaving()
        #expect(await recovering.transcriptionFailed)
        #expect(await transcriber.calls == 3)
        await transcriber.succeed()
        await recovering.retryTranscription()
        await recovering.retryTranscription()
        for _ in 0..<300 {
            if await recovering.isTranscriptDrained { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recovering.isTranscriptDrained)
        #expect(await !recovering.transcriptionFailed)
        #expect(await !recovering.isRecording)
        #expect(await transcriber.calls == 4)
        #expect(try Data(contentsOf: NoteLayout.audioURL(noteFolder: note)) == audioBefore)
        #expect(NoteRecordingState.current(noteFolder: note) == stateBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: pending.path).isEmpty)
        let document = try VTTParser.parse(String(contentsOf: VTT.fileURL(noteFolder: note), encoding: .utf8))
        #expect(document.entries.filter { if case .cue = $0 { true } else { false } }.count == 1)
    }

    @Test("authentication failure is visible and manual retry resumes the paused queue immediately")
    func retriesAuthentication() async throws {
        let note = FileManager.default.temporaryDirectory.appending(path: "transcription-auth-\(UUID())")
        try FileManager.default.createDirectory(at: note, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: note) }
        let transcriber = RetryTranscriber(authenticationFailure: true)
        let pipeline = RecordingPipeline(
            noteFolderURL: note, transcriber: transcriber,
            diarizer: FakeDiarizer { _ in .speech(slot: 0) }, vad: FakeVad { _ in true })
        try await pipeline.start()
        try await pipeline.ingest(samples: [Float](repeating: 0.1, count: 32_000))
        try await pipeline.stop(runFixer: false)
        for _ in 0..<200 {
            if await pipeline.transcriptionFailed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await pipeline.transcriptionFailed)
        #expect(await transcriber.calls == 1)
        await transcriber.succeed()
        await pipeline.retryTranscription()
        for _ in 0..<200 {
            if await pipeline.isTranscriptDrained { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await pipeline.isTranscriptDrained)
        #expect(await !pipeline.transcriptionFailed)
        #expect(await transcriber.calls == 2)
    }
}

private actor RetryTranscriber: Transcriber {
    var calls = 0
    private var succeeds = false
    private let authenticationFailure: Bool

    init(authenticationFailure: Bool = false) { self.authenticationFailure = authenticationFailure }
    func succeed() { succeeds = true }

    func transcribe(webmFile: URL) async throws -> String {
        calls += 1
        if succeeds {
            try await Task.sleep(for: .milliseconds(80))
            return "Recovered transcription"
        }
        if authenticationFailure { throw TranscriptionClient.TranscriptionError.authUnavailable }
        throw TranscriptionClient.TranscriptionError.requestFailed("offline")
    }
}
