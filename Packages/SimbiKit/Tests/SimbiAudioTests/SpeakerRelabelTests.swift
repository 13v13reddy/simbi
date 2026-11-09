import Foundation
import SimbiKit
import Testing

@testable import SimbiAudio

@Suite("Speaker relabel")
struct SpeakerRelabelTests {
    private typealias Cue = SpeakerAssignment.Cue

    /// Four probabilities per 80 ms frame; `spans` marks which slot speaks when.
    private func probabilities(frames: Int, _ spans: [(ClosedRange<Double>, Int)]) -> [Float] {
        var values = [Float](repeating: 0, count: frames * 4)
        for frame in 0..<frames {
            let time = (Double(frame) + 0.5) * CutConstants.frameSeconds
            for (range, slot) in spans where range.contains(time) { values[frame * 4 + slot] = 0.9 }
        }
        return values
    }

    private func levels(frames: Int, microphone: [ClosedRange<Double>], system: [ClosedRange<Double>]) -> [SourceLevel]
    {
        (0..<frames).map { frame in
            let time = (Double(frame) + 0.5) * CutConstants.frameSeconds
            return SourceLevel(
                microphone: microphone.contains { $0.contains(time) } ? 0.2 : 0.002,
                system: system.contains { $0.contains(time) } ? 0.2 : 0)
        }
    }

    @Test("one voice keeps one label across sessions, numbered by first appearance")
    func consistentAcrossSessions() {
        // The live model numbered the same two people differently after Resume.
        let cues = [
            Cue(index: 1, start: 0, end: 4, speaker: "Speaker 2"),
            Cue(index: 2, start: 4, end: 8, speaker: "Speaker 1"),
            Cue(index: 3, start: 20, end: 24, speaker: "Speaker 1"),
            Cue(index: 4, start: 24, end: 28, speaker: "Speaker 2"),
        ]
        let probs = probabilities(frames: 400, [(0...4, 3), (4...8, 1), (20...24, 3), (24...28, 1)])
        let labels = SpeakerAssignment.labels(cues: cues, probabilities: probs, levels: [])
        #expect(labels == [1: "Speaker 1", 2: "Speaker 2", 3: "Speaker 1", 4: "Speaker 2"])
    }

    @Test("the microphone voice is You and cues are split by source on a call")
    func localVoiceOnCall() {
        let cues = [
            Cue(index: 1, start: 0, end: 4, speaker: "Speaker 1"),
            Cue(index: 2, start: 4, end: 8, speaker: "Speaker 1"),
            Cue(index: 3, start: 8, end: 12, speaker: "Speaker 1"),
            Cue(index: 4, start: 12, end: 16, speaker: "Speaker 1"),
        ]
        // The model merged the local voice into the remote speaker for cue 3.
        let probs = probabilities(frames: 200, [(0...4, 0), (4...8, 1), (8...12, 1), (12...16, 1)])
        let sources = levels(frames: 200, microphone: [0...4, 8...12], system: [4...8, 12...16])
        let labels = SpeakerAssignment.labels(cues: cues, probabilities: probs, levels: sources)
        #expect(labels == [1: "You", 2: "Speaker 1", 3: "You", 4: "Speaker 1"])
    }

    @Test("a call-only cue is moved off the local speaker")
    func remoteCueLeavesLocalSpeaker() {
        let cues = [
            Cue(index: 1, start: 0, end: 4, speaker: "Speaker 1"),
            Cue(index: 2, start: 4, end: 8, speaker: "Speaker 2"),
            Cue(index: 3, start: 8, end: 12, speaker: "Speaker 1"),
        ]
        let probs = probabilities(frames: 150, [(0...4, 0), (4...8, 2), (8...12, 0)])
        let sources = levels(frames: 150, microphone: [0...4], system: [4...12])
        let labels = SpeakerAssignment.labels(cues: cues, probabilities: probs, levels: sources)
        #expect(labels == [1: "You", 2: "Speaker 1", 3: "Speaker 1"])
    }

    @Test("an in-room meeting with only microphone audio never invents You")
    func inRoomMeeting() {
        let cues = [
            Cue(index: 1, start: 0, end: 5, speaker: "Speaker 1"),
            Cue(index: 2, start: 5, end: 10, speaker: "Speaker 2"),
        ]
        let probs = probabilities(frames: 130, [(0...5, 0), (5...10, 1)])
        let sources = levels(frames: 130, microphone: [0...10], system: [])
        let labels = SpeakerAssignment.labels(cues: cues, probabilities: probs, levels: sources)
        #expect(labels == [1: "Speaker 1", 2: "Speaker 2"])
    }

    @Test("names given by the user follow their speaker; unresolved cues keep their label")
    func keepsRenamesAndUnresolved() {
        let cues = [
            Cue(index: 1, start: 0, end: 4, speaker: "Dana"),
            Cue(index: 2, start: 4, end: 8, speaker: "Speaker 3"),
            Cue(index: 3, start: 8, end: 12, speaker: "Speaker 2"),
            Cue(index: 4, start: 30, end: 34, speaker: "Speaker 2"),
        ]
        // Cue 3 is the same voice as Dana; cue 4 has no speech in the model.
        let probs = probabilities(frames: 450, [(0...4, 2), (4...8, 0), (8...12, 2)])
        let labels = SpeakerAssignment.labels(cues: cues, probabilities: probs, levels: [])
        #expect(labels == [1: "Dana", 2: "Speaker 1", 3: "Dana"])
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

    @Test("the relabeler rewrites only changed speakers through the outbox")
    func relabelerAppliesEdits() async throws {
        let note = FileManager.default.temporaryDirectory.appending(path: "relabel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: note, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: note) }

        let encoder = try OpusWebMEncoder(fileURL: NoteLayout.audioURL(noteFolder: note), mode: .create)
        try encoder.append(samples: [Float](repeating: 0, count: CutConstants.sampleRate * 8))
        _ = try encoder.finish()
        var vtt = VTT.header(noteName: "n")
        vtt += VTT.render(.cue(index: 1, start: 0, end: 4, speaker: "Speaker 2", text: "hello", continuation: false))
        vtt += VTT.render(.cue(index: 2, start: 4, end: 8, speaker: "Speaker 2", text: "hi", continuation: false))
        try vtt.write(to: VTT.fileURL(noteFolder: note), atomically: true, encoding: .utf8)

        let probs = probabilities(frames: 100, [(0...4, 1), (4...8, 0)])
        let relabeler = SpeakerRelabeler { samples in
            #expect(samples.count >= CutConstants.sampleRate * 7)
            return probs
        }
        let outbox = TranscriptOutbox(fileURL: VTT.fileURL(noteFolder: note), noteName: "n")
        let changed = try await relabeler.relabel(noteFolderURL: note, outbox: outbox)

        let entries = try VTTParser.parse(String(contentsOf: VTT.fileURL(noteFolder: note), encoding: .utf8))
            .entries
        let speakers = entries.compactMap { entry -> String? in
            if case .cue(_, _, _, let speaker, _, _) = entry { return speaker }
            return nil
        }
        #expect(changed == 1)
        #expect(speakers == ["Speaker 1", "Speaker 2"])
    }
}
