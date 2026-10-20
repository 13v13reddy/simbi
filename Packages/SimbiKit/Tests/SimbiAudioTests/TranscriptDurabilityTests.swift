import Foundation
import Testing

@testable import SimbiAudio
@testable import SimbiKit

@Suite("Transcript durability")
struct TranscriptDurabilityTests {
    @Test("Quit flushes the final speech segment durably without waiting for its upload")
    func quitPreservesFinalSegment() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "transcript-quit-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcriber = HeldTranscript()
        let pipeline = RecordingPipeline(
            noteFolderURL: folder, transcriber: transcriber,
            diarizer: FakeDiarizer { _ in .speech(slot: 0) }, vad: FakeVad { _ in true })
        try await pipeline.start()
        try await pipeline.ingest(samples: [Float](repeating: 0.1, count: 32_000))
        try await pipeline.stop(runFixer: false)
        let state = try NoteRecordingState.load(noteFolder: folder)
        #expect(state.activeSession == nil)
        #expect(state.totalSamples == 32_000)
        let pending = NoteLayout.pendingDirURL(noteFolder: folder)
        let segment = try JSONDecoder().decode(
            PendingSegment.self, from: Data(contentsOf: pending.appending(path: "1.json")))
        #expect(segment.endSec == 2)
        #expect(try OpusWebMDecoder(fileURL: pending.appending(path: "1.webm")).endMilliseconds >= 2_000)
        #expect(await !pipeline.isTranscriptDrained)
        for _ in 0..<100 {
            if await transcriber.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await transcriber.complete()
        for _ in 0..<100 {
            if await pipeline.isTranscriptDrained { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await pipeline.isTranscriptDrained)
    }
    @Test("an import waits for its saved cues behind a stopped recording's outstanding upload")
    func recordingAndImportOverlap() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "transcript-overlap-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outbox = TranscriptOutbox.shared(noteFolderURL: folder)
        let transcriber = HeldTranscript()
        let recording = RecordingPipeline(
            noteFolderURL: folder, transcriber: transcriber,
            diarizer: FakeDiarizer { _ in .speech(slot: 0) }, vad: FakeVad { _ in true }, outbox: outbox)
        try await recording.start()
        try await recording.ingest(samples: [Float](repeating: 0.1, count: 32_000))
        try await recording.stop()
        let importing = ImportPipeline(
            noteFolderURL: folder, transcriber: FakeTranscriber(text: "imported result"),
            decoder: DurabilityDecoder(), analyzer: DurabilityAnalyzer(), outbox: outbox)
        let run = Task { try await importing.run(fileURL: folder.appending(path: "fixture.wav")) }
        for _ in 0..<100 {
            if try outbox.hasResult(index: 2) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try outbox.hasResult(index: 2))
        try #require(await transcriber.entered)
        #expect(await importing.isImporting)
        #expect(!outbox.isDrained)
        let anotherController = RecordingPipeline(
            noteFolderURL: folder, transcriber: transcriber,
            diarizer: FakeDiarizer { _ in .silence }, vad: FakeVad { _ in false }, outbox: outbox)
        await anotherController.retryTranscriptSaving()
        #expect(await transcriber.calls == 1)
        await transcriber.complete()
        try await run.value
        #expect(outbox.isDrained)
        let document = try VTTParser.parse(String(contentsOf: VTT.fileURL(noteFolder: folder), encoding: .utf8))
        let indices = document.entries.compactMap { entry -> Int? in
            if case .cue(let index, _, _, _, _, _) = entry { return index }
            return nil
        }
        #expect(indices == [1, 2])
    }

    @Test("transcript write failures leave healthy audio recording active")
    func recordingContinuesDuringTranscriptFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "transcript-live-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcriber = HeldTranscript()
        let pipeline = RecordingPipeline(
            noteFolderURL: folder, transcriber: transcriber,
            diarizer: FakeDiarizer { $0 < 25 ? .speech(slot: 0) : .silence },
            vad: FakeVad { $0 < 8 })
        try await pipeline.start()
        try await pipeline.ingest(samples: [Float](repeating: 0.1, count: 160_000))
        for _ in 0..<100 {
            if await transcriber.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await transcriber.entered)
        let transcript = VTT.fileURL(noteFolder: folder)
        let backup = folder.appending(path: "before.vtt")
        try FileManager.default.moveItem(at: transcript, to: backup)
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        await transcriber.complete()
        for _ in 0..<100 {
            if await pipeline.transcriptSaveFailed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await pipeline.transcriptSaveFailed)
        let saved = pipeline.writeProgress.snapshot.writtenSamples
        try await pipeline.ingest(samples: [Float](repeating: 0, count: 16_000))
        #expect(await pipeline.isRecording)
        #expect(pipeline.writeProgress.snapshot.writtenSamples > saved)
        try await pipeline.stop()
        #expect(try NoteRecordingState.load(noteFolder: folder).activeSession == nil)
        try FileManager.default.removeItem(at: transcript)
        try FileManager.default.moveItem(at: backup, to: transcript)
        await pipeline.retryTranscriptSaving()
        #expect(await !pipeline.transcriptSaveFailed)
    }

    @Test("an imported transcript write failure is reported and its saved result survives relaunch")
    func importRecovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "transcript-import-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcriber = HeldTranscript()
        func makePipeline() -> ImportPipeline {
            ImportPipeline(
                noteFolderURL: folder, transcriber: transcriber,
                decoder: DurabilityDecoder(), analyzer: DurabilityAnalyzer())
        }
        let pipeline = makePipeline()
        let run = Task { try await pipeline.run(fileURL: folder.appending(path: "fixture.wav")) }
        for _ in 0..<100 {
            if await transcriber.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await transcriber.entered)
        let transcript = VTT.fileURL(noteFolder: folder)
        let backup = folder.appending(path: "before.vtt")
        try FileManager.default.moveItem(at: transcript, to: backup)
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        await transcriber.complete()
        await #expect(throws: (any Error).self) { try await run.value }
        #expect(try NoteRecordingState.load(noteFolder: folder).activeImport?.phase == 2)
        let pending = NoteLayout.pendingDirURL(noteFolder: folder)
        #expect(FileManager.default.fileExists(atPath: pending.appending(path: "1.webm").path))
        try FileManager.default.removeItem(at: transcript)
        try FileManager.default.moveItem(at: backup, to: transcript)
        try await makePipeline().resumePhase2()
        #expect(try NoteRecordingState.load(noteFolder: folder).activeImport == nil)
        #expect(try String(contentsOf: transcript, encoding: .utf8).contains("result preserved through failure"))
        #expect(await transcriber.calls == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: pending.path).isEmpty)
    }

    @Test(
        "a failed transcript write retains audio and recovers saved text without another upload",
        arguments: [false, true])
    func failedWriteAndRecovery(reopen: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "transcript-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcriber = HeldTranscript()
        func makePipeline() -> RecordingPipeline {
            RecordingPipeline(
                noteFolderURL: folder, transcriber: transcriber,
                diarizer: FakeDiarizer { _ in .speech(slot: 0) }, vad: FakeVad { _ in true })
        }
        let pipeline = makePipeline()
        try await pipeline.start()
        try await pipeline.ingest(samples: [Float](repeating: 0.1, count: 32_000))
        try await pipeline.stop()
        for _ in 0..<100 {
            if await transcriber.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await transcriber.entered)
        let transcript = VTT.fileURL(noteFolder: folder)
        let backup = folder.appending(path: "transcript-before-failure.vtt")
        try FileManager.default.moveItem(at: transcript, to: backup)
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        await transcriber.complete()
        for _ in 0..<100 {
            if await pipeline.transcriptSaveFailed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await pipeline.transcriptSaveFailed)
        #expect(await !pipeline.isTranscriptDrained)
        let pending = NoteLayout.pendingDirURL(noteFolder: folder)
        #expect(FileManager.default.fileExists(atPath: pending.appending(path: "1.webm").path))
        #expect(FileManager.default.fileExists(atPath: pending.appending(path: "1.json").path))
        try FileManager.default.removeItem(at: transcript)
        try FileManager.default.moveItem(at: backup, to: transcript)
        let recovered = reopen ? makePipeline() : pipeline
        await recovered.retryTranscriptSaving()
        #expect(await !recovered.transcriptSaveFailed)
        #expect(await recovered.isTranscriptDrained)
        let document = try VTTParser.parse(String(contentsOf: transcript, encoding: .utf8))
        #expect(document.entries.filter { if case .cue = $0 { true } else { false } }.count == 1)
        #expect(String(describing: document).contains("result preserved through failure"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: pending.path).isEmpty)
        #expect(await transcriber.calls == 1)
    }
}

private struct DurabilityDecoder: MediaDecoding {
    func decode(url: URL) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream {
            $0.yield([Float](repeating: 0.1, count: 32_000))
            $0.finish()
        }
    }
}

private struct DurabilityAnalyzer: OfflineAnalyzing {
    func prepare() async throws {}
    func analyze(_ samples: [Float]) async throws -> [ImportFrameRecord] {
        [ImportFrameRecord](repeating: .init(vadActive: true, dominantSlot: 0), count: 25)
    }
}

private actor HeldTranscript: Transcriber {
    var entered = false
    var calls = 0
    private var result: CheckedContinuation<String, Never>?

    func transcribe(webmFile: URL) async throws -> String {
        calls += 1
        return await withCheckedContinuation {
            result = $0
            entered = true
        }
    }

    func complete() {
        result?.resume(returning: "result preserved through failure")
        result = nil
    }
}
