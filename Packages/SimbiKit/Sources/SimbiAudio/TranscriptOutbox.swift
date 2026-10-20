import CodexKit
import Foundation
import SimbiKit
import os

/// The single writer for `transcript.vtt` (guide §9.1): an ordered queue of
/// entries created synchronously by the pipeline in note-timeline order.
/// NOTE entries are ready immediately; cues become ready when their
/// transcription reaches a terminal state. The head is appended as soon as
/// it is ready, so the file is always valid WebVTT and cues appear strictly
/// in timestamp order regardless of completion order.
///
/// Live uploads can finish after Stop while an import begins. Production
/// pipelines share one locked outbox per note so both keep one ordered journal.
public final class TranscriptOutbox: @unchecked Sendable {
    private static let sharedOutboxes = OSAllocatedUnfairLock(initialState: [URL: TranscriptOutbox]())
    private let lock = NSRecursiveLock()

    public static func shared(noteFolderURL: URL) -> TranscriptOutbox {
        let folder = noteFolderURL.standardizedFileURL
        return sharedOutboxes.withLock { values in
            if let existing = values[folder] { return existing }
            let outbox = TranscriptOutbox(
                fileURL: VTT.fileURL(noteFolder: folder), noteName: folder.lastPathComponent,
                journalURL: NoteLayout.stateDirURL(noteFolder: folder).appending(path: "transcript-outbox.json"))
            values[folder] = outbox
            return outbox
        }
    }
    private enum Slot: Codable {
        case ready(VTTEntry)
        case pendingCue(
            index: Int, start: TimeInterval, end: TimeInterval, speaker: String,
            continuation: Bool, text: String?)

        var isReady: Bool {
            switch self {
            case .ready: return true
            case .pendingCue(_, _, _, _, _, let text): return text != nil
            }
        }

        var cueIndex: Int? {
            if case .pendingCue(let index, _, _, _, _, _) = self { return index }
            return nil
        }
    }

    private var queue: [Slot] = []
    private let fileURL: URL
    private let noteName: String
    private let journalURL: URL?
    private var restored = false
    private var uploadClaims: Set<Int> = []

    /// Recording and import workers share the journal. A queued or in-flight
    /// request must not be uploaded twice when the user retries either job.
    func claimUpload(index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return uploadClaims.insert(index).inserted
    }

    func releaseUpload(index: Int) {
        lock.lock()
        defer { lock.unlock() }
        uploadClaims.remove(index)
    }

    public init(fileURL: URL, noteName: String, journalURL: URL? = nil) {
        self.fileURL = fileURL
        self.noteName = noteName
        self.journalURL = journalURL
    }

    private func restore() throws {
        guard !restored else { return }
        if let journalURL, FileManager.default.fileExists(atPath: journalURL.path) {
            queue = try JSONDecoder().decode([Slot].self, from: Data(contentsOf: journalURL))
        }
        restored = true
    }

    private func persist() throws {
        guard let journalURL else { return }
        guard !queue.isEmpty || FileManager.default.fileExists(atPath: journalURL.path) else { return }
        try FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(queue).write(to: journalURL, options: .atomic)
    }

    /// Replays saved results without starting a new recording or contacting
    /// the transcriber. Already committed cue/session identities are skipped.
    public func retry() throws {
        lock.lock()
        defer { lock.unlock() }
        try restore()
        try persist()
        try drain()
    }

    public func committedCueIndices() throws -> Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return try existingEntries().reduce(into: Set<Int>()) { indices, entry in
            if case .cue(let index, _, _, _, _, _) = entry { indices.insert(index) }
        }
    }

    /// A result waiting behind an earlier cue remains in the journal and its
    /// original segment stays recoverable until the cue reaches the VTT.
    public func removeCommittedSegments(from directory: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let committed = try committedCueIndices()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in files where ["webm", "json"].contains(url.pathExtension) {
            guard let index = Int(url.deletingPathExtension().lastPathComponent), committed.contains(index) else {
                continue
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    public func hasResult(index: Int) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try restore()
        return queue.contains {
            if case .pendingCue(index, _, _, _, _, .some) = $0 { return true }
            return false
        }
    }

    /// Enqueues an immediately-ready NOTE entry (session/gap).
    public func append(_ entry: VTTEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        try restore()
        if queue.contains(where: {
            if case .ready(let queued) = $0 { Self.identity(queued) == Self.identity(entry) } else { false }
        }) {
            try retry()
            return
        }
        queue.append(.ready(entry))
        try persist()
        try drain()
    }

    /// Reserves the ordering slot for a flushed cue (§6.3 step 8).
    public func reserveCue(
        index: Int, start: TimeInterval, end: TimeInterval, speaker: String,
        continuation: Bool
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try restore()
        guard !queue.contains(where: { $0.cueIndex == index }) else { return }
        queue.append(
            .pendingCue(
                index: index, start: start, end: end, speaker: speaker,
                continuation: continuation, text: nil))
        try persist()
    }

    /// Marks a reserved cue terminal (transcription text or `[inaudible]`).
    public func fulfillCue(index: Int, text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try restore()
        for (i, slot) in queue.enumerated() {
            if case .pendingCue(index, let start, let end, let speaker, let continuation, nil) =
                slot
            {
                queue[i] = .pendingCue(
                    index: index, start: start, end: end, speaker: speaker,
                    continuation: continuation, text: text)
                break
            }
        }
        try persist()
        try drain()
    }

    /// True when no reserved cue is still awaiting its text.
    public var isDrained: Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            try restore()
            return queue.isEmpty
        } catch { return false }
    }

    /// One fixer edit to merge into the live file: a new payload (speaker +
    /// text) for an existing cue. Timestamps and numbering are never
    /// editable — they stay whatever the live file says.
    public struct CueEdit: Equatable, Sendable {
        public let index: Int
        public let speaker: String
        public let text: String

        public init(index: Int, speaker: String, text: String) {
            self.index = index
            self.speaker = speaker
            self.text = text
        }
    }

    /// Rewrites the payload line of each edited cue in place. Runs on the
    /// pipeline actor like every other write, so it is serialized against
    /// appends — the whole point of the fixer merge (the fixer never
    /// touches this file). Everything except the edited payload lines —
    /// numbering, timestamps, NOTE blocks, unknown blocks — is preserved
    /// byte-for-byte, and nothing is written unless the result re-parses.
    public func applyEdits(_ edits: [CueEdit]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !edits.isEmpty, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let byIndex = Dictionary(edits.map { ($0.index, $0) }) { _, last in last }
        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .components(separatedBy: "\n")

        var out: [String] = []
        var i = 0
        var changed = false
        while i < lines.count {
            // A cue block: bare integer line, then a timing line.
            if let cueIndex = Int(lines[i]), i + 1 < lines.count,
                lines[i + 1].contains(" --> "), let edit = byIndex[cueIndex]
            {
                out.append(lines[i])
                out.append(lines[i + 1])
                out.append(
                    VTT.voicePayload(
                        speaker: Self.sanitizeSpeaker(edit.speaker),
                        text: Self.sanitizeText(edit.text)))
                i += 2
                while i < lines.count, !lines[i].isEmpty { i += 1 }
                changed = true
            } else {
                out.append(lines[i])
                i += 1
            }
        }
        guard changed else { return }
        let updated = out.joined(separator: "\n")
        guard (try? VTTParser.parse(updated)) != nil else {
            Log.recording.error("fixer merge produced unparseable VTT; edits discarded")
            return
        }
        try updated.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Payload text must stay one line and must not contain the cue-timing
    /// arrow (WebVTT forbids it in cue text).
    static func sanitizeText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "-->", with: "→")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A `>` inside the voice tag would end it early.
    static func sanitizeSpeaker(_ speaker: String) -> String {
        speaker.replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func drain() throws {
        while let head = queue.first, head.isReady {
            let entry: VTTEntry
            switch head {
            case .ready(let readyEntry):
                entry = readyEntry
            case .pendingCue(let index, let start, let end, let speaker, let continuation, let text):
                entry = .cue(
                    index: index, start: start, end: end, speaker: speaker,
                    text: text ?? "[inaudible]", continuation: continuation)
            }
            try appendToFile(entry)
            queue.removeFirst()
            try persist()
        }
    }

    /// The per-cue diff between the fixer's snapshot ("before" — what the
    /// pipeline copied into the worktree at ping time) and the fixer's
    /// edited copy ("after"). Only changed payloads of cues present in BOTH
    /// survive: deletions, additions, renumbering, and timestamp changes
    /// are ignored by construction, and an unparseable copy yields nothing
    /// — the prompt rules the fixer used to be trusted with are enforced
    /// here instead.
    public static func fixerEdits(before: String, after: String) -> [CueEdit] {
        guard before != after,
            let beforeDocument = try? VTTParser.parse(before),
            let afterDocument = try? VTTParser.parse(after)
        else { return [] }
        var beforeCues: [Int: (speaker: String, text: String)] = [:]
        for case .cue(let index, _, _, let speaker, let text, _) in beforeDocument.entries {
            beforeCues[index] = (speaker, text)
        }
        var edits: [CueEdit] = []
        for case .cue(let index, _, _, let speaker, let text, _) in afterDocument.entries {
            if let old = beforeCues[index], old.speaker != speaker || old.text != text {
                edits.append(CueEdit(index: index, speaker: speaker, text: text))
            }
        }
        return edits
    }

    private func existingEntries() throws -> [VTTEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try VTTParser.parse(String(contentsOf: fileURL, encoding: .utf8)).entries
    }

    private static func identity(_ entry: VTTEntry) -> String {
        switch entry {
        case .cue(let index, _, _, _, _, _): "cue-\(index)"
        case .sessionStart(let n, _, _): "session-start-\(n)"
        case .sessionEnd(let n, _, _): "session-end-\(n)"
        case .gap(let start, let end): "gap-\(VTT.timestamp(start))-\(VTT.timestamp(end))"
        }
    }

    private func appendToFile(_ entry: VTTEntry) throws {
        let text: String
        if FileManager.default.fileExists(atPath: fileURL.path) {
            text = try String(contentsOf: fileURL, encoding: .utf8)
            let entries = try VTTParser.parse(text).entries
            // A crash can occur after the transcript replacement but before
            // the journal acknowledgment. Never append that entry twice or
            // overwrite later speaker/fixer edits when replaying it.
            if entries.contains(where: { Self.identity($0) == Self.identity(entry) }) { return }
        } else {
            text = VTT.header(noteName: noteName)
        }
        // Atomic replacement keeps a failed or interrupted write from leaving
        // a partial final block that would prevent all subsequent recovery.
        try (text + VTT.render(entry)).write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
