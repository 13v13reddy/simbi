import Foundation
import SimbiKit

/// Labels the local voice on a call. The microphone and the call audio are
/// mixed into one track before speaker detection, which then often files the
/// same person under two numbers. The recorded per-source levels say directly
/// which lines came only through the microphone, so those become one speaker
/// ("You") without any voice model.
///
/// Whole-recording voice models were measured and rejected: on a 45-minute,
/// 5-speaker benchmark the offline Sortformer scored 37–44% against 79% for
/// the live labels, and embedding clustering (80%) merged two voices.
public enum SpeakerAssignment {
    public static let localSpeakerName = "You"

    public struct Cue: Equatable, Sendable {
        public let index: Int
        public let start: TimeInterval
        public let end: TimeInterval
        public let speaker: String

        public init(index: Int, start: TimeInterval, end: TimeInterval, speaker: String) {
            self.index = index
            self.start = start
            self.end = end
            self.speaker = speaker
        }

        var duration: TimeInterval { max(end - start, 0) }
    }

    /// Mean per-frame power below this is silence, not evidence.
    static let minimumPower: Double = 1e-6
    /// A cue whose microphone share of the power is at least this came only
    /// through the microphone; at most `1 - strongShare`, only from the call.
    static let strongShare = 0.85
    /// Seconds of call-only speech required before anything is relabelled,
    /// so in-room meetings (everyone on the microphone) are left alone.
    static let minimumCallSpeech: TimeInterval = 3

    /// New speaker for every cue that clearly came from the local
    /// microphone. Empty when the recording has no call audio or no levels.
    public static func localSpeakerLabels(cues: [Cue], levels: [SourceLevel]) -> [Int: String] {
        let shares = cues.map { microphoneShare($0, levels: levels) }
        let callSpeech = zip(cues, shares).filter { ($0.1 ?? 1) <= 1 - strongShare }
            .reduce(0) { $0 + $1.0.duration }
        guard callSpeech >= minimumCallSpeech else { return [:] }
        let local = zip(cues, shares).filter { ($0.1 ?? 0) >= strongShare }.map(\.0)
        guard !local.isEmpty else { return [:] }

        // Keep a name the user already gave their own voice.
        var named: [String: TimeInterval] = [:]
        for cue in local where SpeakerLabel.slot(name: cue.speaker) == nil {
            named[cue.speaker, default: 0] += cue.duration
        }
        let total = local.reduce(0) { $0 + $1.duration }
        let name =
            named.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
            .flatMap { $0.value * 2 >= total ? $0.key : nil } ?? localSpeakerName
        return Dictionary(uniqueKeysWithValues: local.map { ($0.index, name) })
    }

    /// Microphone power / total power over the cue, nil when silent or unknown.
    static func microphoneShare(_ cue: Cue, levels: [SourceLevel]) -> Double? {
        let first = max(0, Int((cue.start / CutConstants.frameSeconds).rounded(.down)))
        let last = min(levels.count, max(first + 1, Int((cue.end / CutConstants.frameSeconds).rounded(.up))))
        guard first < last else { return nil }
        var microphone = 0.0
        var system = 0.0
        for frame in first..<last {
            microphone += Double(levels[frame].microphone * levels[frame].microphone)
            system += Double(levels[frame].system * levels[frame].system)
        }
        let total = microphone + system
        return total / Double(last - first) > minimumPower ? microphone / total : nil
    }
}

/// Applies `SpeakerAssignment` to a stopped recording through the note's
/// transcript outbox (its single writer).
public enum SpeakerRelabeler {
    /// The previous transcript, kept so a relabel can be compared or undone.
    public static func backupURL(noteFolder: URL) -> URL {
        NoteLayout.stateDirURL(noteFolder: noteFolder).appending(path: "transcript-before-relabel.vtt")
    }

    /// Returns the number of cues whose speaker changed.
    public static func relabel(noteFolderURL: URL, outbox: TranscriptOutbox) throws -> Int {
        let levels = SourceLevelsWriter.read(url: NoteLayout.sourceLevelsURL(noteFolder: noteFolderURL))
        guard !levels.isEmpty,
            let text = try? String(contentsOf: VTT.fileURL(noteFolder: noteFolderURL), encoding: .utf8)
        else { return 0 }
        var cues: [SpeakerAssignment.Cue] = []
        for case .cue(let index, let start, let end, let speaker, _, _) in try VTTParser.parse(text).entries {
            cues.append(.init(index: index, start: start, end: end, speaker: speaker))
        }
        let labels = SpeakerAssignment.localSpeakerLabels(cues: cues, levels: levels)
        let edits = cues.compactMap { cue -> TranscriptOutbox.CueEdit? in
            guard let label = labels[cue.index], label != cue.speaker else { return nil }
            return .init(index: cue.index, speaker: label, text: nil)
        }
        guard !edits.isEmpty else { return 0 }
        try FileManager.default.createDirectory(
            at: NoteLayout.stateDirURL(noteFolder: noteFolderURL), withIntermediateDirectories: true)
        try text.write(to: backupURL(noteFolder: noteFolderURL), atomically: true, encoding: .utf8)
        try outbox.applyEdits(edits)
        return edits.count
    }
}
