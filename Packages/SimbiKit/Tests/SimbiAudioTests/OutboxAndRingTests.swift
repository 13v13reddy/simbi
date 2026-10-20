import Foundation
import Testing

@testable import SimbiAudio
@testable import SimbiKit

@Suite("SampleRingBuffer")
struct SampleRingBufferTests {
    @Test("slices by absolute index across evictions")
    func absoluteSlicing() {
        var ring = SampleRingBuffer(targetCapacity: 1000)
        ring.append([Float](repeating: 1, count: 500))
        ring.append((0..<500).map(Float.init))
        #expect(ring.writeHead == 1000)
        #expect(ring.slice(500..<503) == [0, 1, 2])

        // Floor at 800: with target 1000 nothing evicts yet (retention
        // would drop below target only above writeHead - target).
        ring.setEvictionFloor(800)
        #expect(ring.oldestRetained == 0)

        ring.append([Float](repeating: 2, count: 600))  // writeHead 1600
        // Eviction keeps min(floor, writeHead - target) = min(800, 600).
        #expect(ring.oldestRetained == 600)
        #expect(ring.slice(800..<802) == [300, 301])
    }

    @Test("never evicts above the floor even past target capacity")
    func floorWins() {
        var ring = SampleRingBuffer(targetCapacity: 100)
        ring.append([Float](repeating: 0, count: 1000))
        ring.setEvictionFloor(50)
        #expect(ring.oldestRetained == 50)  // grew past target, floor wins
        ring.append([Float](repeating: 1, count: 500))
        #expect(ring.oldestRetained == 50)
        #expect(ring.slice(50..<51) == [0])
        ring.setEvictionFloor(1400)
        #expect(ring.oldestRetained == 1400)  // target keeps trailing 100
        #expect(ring.retainedCount == 100)
    }
}

@Suite("TranscriptOutbox")
struct TranscriptOutboxTests {
    private func makeFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "vtt-\(UUID().uuidString).vtt")
    }

    @Test("recording and import completions share one ordered transcript writer")
    func sharedProducerCompletions() async throws {
        let folder = makeFile().deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = TranscriptOutbox.shared(noteFolderURL: folder)
        let importing = TranscriptOutbox.shared(noteFolderURL: folder)
        #expect(recording === importing)
        for index in 1...30 {
            try recording.reserveCue(
                index: index, start: Double(index), end: Double(index + 1), speaker: "Speaker 1", continuation: false)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in (1...30).reversed() {
                let writer = index.isMultiple(of: 2) ? recording : importing
                group.addTask { try writer.fulfillCue(index: index, text: "cue \(index)") }
            }
            try await group.waitForAll()
        }
        let document = try VTTParser.parse(String(contentsOf: VTT.fileURL(noteFolder: folder), encoding: .utf8))
        let indices = document.entries.compactMap { entry -> Int? in
            if case .cue(let index, _, _, _, _, _) = entry { return index }
            return nil
        }
        #expect(indices == Array(1...30))
        #expect(recording.isDrained)
    }

    @Test("a failed transcript write keeps its cue available for retry")
    func failedWriteRetainsCue() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let outbox = TranscriptOutbox(fileURL: url, noteName: "Test")
        try outbox.reserveCue(index: 1, start: 0, end: 2, speaker: "Speaker 1", continuation: false)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try outbox.fulfillCue(index: 1, text: "preserve this text") }
        #expect(!outbox.isDrained)
        try FileManager.default.removeItem(at: url)
        try outbox.fulfillCue(index: 1, text: "preserve this text")
        let document = try VTTParser.parse(String(contentsOf: url, encoding: .utf8))
        #expect(document.entries.count == 1)
        #expect(outbox.isDrained)
    }

    @Test("completed results survive reopening while an earlier cue is pending")
    func completedResultsSurviveReopening() throws {
        let folder = makeFile().deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "transcript.vtt")
        let journal = folder.appending(path: "outbox.json")
        let first = TranscriptOutbox(fileURL: url, noteName: "Test", journalURL: journal)
        try first.reserveCue(index: 1, start: 0, end: 2, speaker: "Speaker 1", continuation: false)
        try first.reserveCue(index: 2, start: 2, end: 4, speaker: "Speaker 2", continuation: false)
        try first.fulfillCue(index: 2, text: "already transcribed")
        let reopened = TranscriptOutbox(fileURL: url, noteName: "Test", journalURL: journal)
        try reopened.fulfillCue(index: 1, text: "first")
        let document = try VTTParser.parse(String(contentsOf: url, encoding: .utf8))
        #expect(
            document.entries == [
                .cue(index: 1, start: 0, end: 2, speaker: "Speaker 1", text: "first", continuation: false),
                .cue(
                    index: 2, start: 2, end: 4, speaker: "Speaker 2", text: "already transcribed", continuation: false),
            ])
        #expect(reopened.isDrained)
    }

    @Test("replaying a cue committed before a crash keeps later edits and never duplicates it")
    func replayAfterCommitBeforeAcknowledgment() throws {
        let folder = makeFile().deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "transcript.vtt")
        let journal = folder.appending(path: "outbox.json")
        let outbox = TranscriptOutbox(fileURL: url, noteName: "Test", journalURL: journal)
        try outbox.reserveCue(index: 1, start: 0, end: 2, speaker: "Speaker 1", continuation: false)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try outbox.fulfillCue(index: 1, text: "original result") }
        let unacknowledged = try Data(contentsOf: journal)
        try FileManager.default.removeItem(at: url)
        try outbox.retry()
        let edited = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(
            of: "original result", with: "user edit")
        try edited.write(to: url, atomically: true, encoding: .utf8)
        try unacknowledged.write(to: journal, options: .atomic)
        let recovered = TranscriptOutbox(fileURL: url, noteName: "Test", journalURL: journal)
        try recovered.retry()
        #expect(try String(contentsOf: url, encoding: .utf8) == edited)
        #expect(recovered.isDrained)
    }

    @Test("cues append strictly in order regardless of completion order")
    func ordering() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let outbox = TranscriptOutbox(fileURL: url, noteName: "Test")

        try outbox.append(.sessionStart(n: 1, wallClock: .now, offset: 0))
        try outbox.reserveCue(index: 1, start: 0, end: 4, speaker: "Speaker 1", continuation: false)
        try outbox.reserveCue(index: 2, start: 5, end: 9, speaker: "Speaker 2", continuation: false)
        try outbox.append(.gap(start: 9, end: 12))

        // Cue 2 completes first — nothing beyond the session note may
        // appear until cue 1 is terminal.
        try outbox.fulfillCue(index: 2, text: "second")
        var document = try VTTParser.parse(String(contentsOf: url, encoding: .utf8))
        #expect(document.entries.count == 1)

        try outbox.fulfillCue(index: 1, text: "first")
        document = try VTTParser.parse(String(contentsOf: url, encoding: .utf8))
        #expect(document.entries.count == 4)
        if case .cue(let index, _, _, _, let text, _) = document.entries[1] {
            #expect(index == 1)
            #expect(text == "first")
        } else {
            Issue.record("expected cue at entry 1")
        }
        #expect(outbox.isDrained)
    }

    @Test("file is valid WebVTT after every append")
    func alwaysValid() throws {
        let url = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let outbox = TranscriptOutbox(fileURL: url, noteName: "Test")

        try outbox.append(.sessionStart(n: 1, wallClock: .now, offset: 0))
        _ = try VTTParser.parse(String(contentsOf: url, encoding: .utf8))

        try outbox.reserveCue(index: 1, start: 0, end: 2, speaker: "Speaker 1", continuation: false)
        try outbox.fulfillCue(index: 1, text: "hello")
        _ = try VTTParser.parse(String(contentsOf: url, encoding: .utf8))

        try outbox.append(.sessionEnd(n: 1, wallClock: .now, offset: 2))
        let document = try VTTParser.parse(String(contentsOf: url, encoding: .utf8))
        #expect(document.entries.count == 3)
    }
}
