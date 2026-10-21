import Foundation
import SimbiAudio
import SimbiKit
import Testing

@testable import SimbiUI

@Suite("Import recovery completion", .serialized)
@MainActor
struct ImportRecoveryTests {
    @Test("recovered imports fire the AI notes trigger once after saving the final state")
    func notifiesAfterRecovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "simbi-import-completion-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Simulate a crash after audio and transcript were committed but
        // before the phase-2 marker could be cleared. No network is needed.
        let encoder = try OpusWebMEncoder(fileURL: NoteLayout.audioURL(noteFolder: folder), mode: .create)
        try encoder.append(samples: [Float](repeating: 0.1, count: 16_000))
        try encoder.finish()
        let savedAudio = try Data(contentsOf: NoteLayout.audioURL(noteFolder: folder))
        let transcript =
            VTT.header(noteName: "Test")
            + VTT.render(
                .cue(index: 1, start: 0, end: 1, speaker: "Speaker 1", text: "Saved text", continuation: false))
        try transcript.write(to: VTT.fileURL(noteFolder: folder), atomically: true, encoding: .utf8)
        try NoteRecordingState(
            sessionCount: 1, totalSamples: 16_000,
            activeImport: .init(fileName: "clip.wav", n: 1, baseSamples: 0, phase: 2),
            imports: ["clip.wav": .init(status: .transcribing)]
        ).save(noteFolder: folder)
        let importer = ImportController.shared(noteFolderURL: folder)
        var triggers = 0
        importer.onImportFinished = {
            triggers += 1
            #expect(importer.status == .idle)
            #expect(NoteRecordingState.current(noteFolder: folder).activeImport == nil)
            #expect(NoteRecordingState.current(noteFolder: folder).imports["clip.wav"]?.status == .done)
        }
        try await waitUntil { importer.status == .idle }
        #expect(triggers == 1)
        #expect(!importer.decodingAudio)
        #expect(!importer.fixingTranscript)
        #expect(try Data(contentsOf: NoteLayout.audioURL(noteFolder: folder)) == savedAudio)
        #expect(try String(contentsOf: VTT.fileURL(noteFolder: folder), encoding: .utf8) == transcript)
        // Retrying an already completed import must not generate again.
        importer.retryTranscriptSaving()
        try await Task.sleep(for: .milliseconds(50))
        #expect(triggers == 1)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
