import Foundation
import SimbiKit
import Testing

@testable import SimbiAudio

@Suite("Speaker relabel")
struct SpeakerRelabelTests {
    private typealias Cue = SpeakerAssignment.Cue

    /// Per-frame levels: loud microphone or call audio in the given spans,
    /// faint microphone room noise everywhere else.
    private func levels(frames: Int, microphone: [ClosedRange<Double>], system: [ClosedRange<Double>]) -> [SourceLevel]
    {
        (0..<frames).map { frame in
            let time = (Double(frame) + 0.5) * CutConstants.frameSeconds
            return SourceLevel(
                microphone: microphone.contains { $0.contains(time) } ? 0.2 : 0.002,
                system: system.contains { $0.contains(time) } ? 0.2 : 0)
        }
    }

    @Test("lines heard only through the microphone become You, whatever number the model gave them")
    func localVoiceOnCall() {
        let cues = [
            Cue(index: 1, start: 0, end: 4, speaker: "Speaker 1"),
            Cue(index: 2, start: 4, end: 8, speaker: "Speaker 2"),
            Cue(index: 3, start: 8, end: 12, speaker: "Speaker 3"),
            Cue(index: 4, start: 12, end: 16, speaker: "Speaker 2"),
        ]
        let sources = levels(frames: 200, microphone: [0...4, 8...12], system: [4...8, 12...16])
        #expect(SpeakerAssignment.localSpeakerLabels(cues: cues, levels: sources) == [1: "You", 3: "You"])
    }

    @Test("an in-room meeting with only microphone audio is left alone")
    func inRoomMeeting() {
        let cues = [
            Cue(index: 1, start: 0, end: 5, speaker: "Speaker 1"),
            Cue(index: 2, start: 5, end: 10, speaker: "Speaker 2"),
        ]
        let sources = levels(frames: 130, microphone: [0...10], system: [])
        #expect(SpeakerAssignment.localSpeakerLabels(cues: cues, levels: sources).isEmpty)
    }

    @Test("overlapping speech and recordings without levels are left alone")
    func ambiguousOrUnknown() {
        let cues = [
            Cue(index: 1, start: 0, end: 4, speaker: "Speaker 1"),
            Cue(index: 2, start: 4, end: 8, speaker: "Speaker 2"),
        ]
        // Cue 1 has both sources at once; cue 2 is the call.
        let sources = levels(frames: 100, microphone: [0...4], system: [0...8])
        #expect(SpeakerAssignment.localSpeakerLabels(cues: cues, levels: sources).isEmpty)
        #expect(SpeakerAssignment.localSpeakerLabels(cues: cues, levels: []).isEmpty)
    }

    @Test("a name the user gave their own voice is kept for all of their lines")
    func keepsUserName() {
        let cues = [
            Cue(index: 1, start: 0, end: 6, speaker: "Veera"),
            Cue(index: 2, start: 6, end: 10, speaker: "Speaker 3"),
            Cue(index: 3, start: 10, end: 14, speaker: "Speaker 2"),
        ]
        let sources = levels(frames: 200, microphone: [0...10], system: [10...14])
        #expect(SpeakerAssignment.localSpeakerLabels(cues: cues, levels: sources) == [1: "Veera", 2: "Veera"])
    }

    @Test("source levels are stored per frame at their note-timeline position")
    func levelsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "levels-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: url) }
        let frame = CutConstants.frameSamples

        var writer = try #require(SourceLevelsWriter(url: url, startSample: 0))
        // Batches that do not align with frames, then a batch without sources.
        writer.append(
            count: frame + frame / 2,
            sources: SourceSamples(
                microphone: .init(repeating: 0.5, count: frame + frame / 2),
                system: .init(repeating: 0, count: frame + frame / 2)))
        writer.append(
            count: frame / 2,
            sources: SourceSamples(
                microphone: .init(repeating: 0, count: frame / 2), system: .init(repeating: 0.5, count: frame / 2)))
        writer.append(count: frame, sources: nil)
        writer.finish()

        // A resumed session starts at its own offset.
        writer = try #require(SourceLevelsWriter(url: url, startSample: 3 * frame))
        writer.append(
            count: frame,
            sources: SourceSamples(
                microphone: .init(repeating: 0, count: frame), system: .init(repeating: 0.25, count: frame)))
        writer.finish()

        let levels = SourceLevelsWriter.read(url: url)
        #expect(levels.count == 4)
        #expect(levels[0] == SourceLevel(microphone: 0.5, system: 0))
        #expect(abs(Double(levels[1].microphone) - 0.5.squareRoot() * 0.5) < 1e-5)
        #expect(abs(Double(levels[1].system) - 0.5.squareRoot() * 0.5) < 1e-5)
        #expect(levels[2] == SourceLevel(microphone: 0, system: 0))
        #expect(levels[3] == SourceLevel(microphone: 0, system: 0.25))
    }

    @Test("the relabeler rewrites only changed speakers through the outbox and keeps a backup")
    func relabelerAppliesEdits() throws {
        let note = FileManager.default.temporaryDirectory.appending(path: "relabel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: note, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: note) }

        var vtt = VTT.header(noteName: "n")
        vtt += VTT.render(.cue(index: 1, start: 0, end: 4, speaker: "Speaker 3", text: "hello", continuation: false))
        vtt += VTT.render(.cue(index: 2, start: 4, end: 8, speaker: "Speaker 2", text: "hi", continuation: false))
        try vtt.write(to: VTT.fileURL(noteFolder: note), atomically: true, encoding: .utf8)
        var levelData = Data()
        for level in levels(frames: 100, microphone: [0...4], system: [4...8]) {
            withUnsafeBytes(of: level.microphone) { levelData.append(contentsOf: $0) }
            withUnsafeBytes(of: level.system) { levelData.append(contentsOf: $0) }
        }
        try FileManager.default.createDirectory(
            at: NoteLayout.stateDirURL(noteFolder: note), withIntermediateDirectories: true)
        try levelData.write(to: NoteLayout.sourceLevelsURL(noteFolder: note))

        let outbox = TranscriptOutbox(fileURL: VTT.fileURL(noteFolder: note), noteName: "n")
        let changed = try SpeakerRelabeler.relabel(noteFolderURL: note, outbox: outbox)

        let speakers = try VTTParser.parse(String(contentsOf: VTT.fileURL(noteFolder: note), encoding: .utf8))
            .entries.compactMap { entry -> String? in
                if case .cue(_, _, _, let speaker, _, _) = entry { return speaker }
                return nil
            }
        #expect(changed == 1)
        #expect(speakers == ["You", "Speaker 2"])
        let backup = try String(contentsOf: SpeakerRelabeler.backupURL(noteFolder: note), encoding: .utf8)
        #expect(backup == vtt)
    }
}
