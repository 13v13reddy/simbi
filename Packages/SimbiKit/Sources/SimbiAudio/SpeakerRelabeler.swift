import FluidAudio
import Foundation
import SimbiKit

/// Re-labels a finished recording's transcript from a whole-file speaker
/// pass. Live labels come from a streaming model with about one second of
/// context that restarts every session; the offline model sees the entire
/// recording, so the same voice keeps the same label across Stop/Resume.
/// When the recording has per-source levels, the local microphone voice is
/// labelled "You" and separated from the call audio.
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
    }

    static let slots = 4
    /// Minimum summed speaker probability (about two confident frames)
    /// before a cue's label is replaced.
    static let minimumScore: Float = 1.5
    /// Mean per-frame power below this is silence for source attribution.
    static let minimumPower: Double = 1e-6
    /// Cue-level microphone share beyond which a cue clearly belongs to the
    /// local voice (or, below `1 - strongShare`, to the call).
    static let strongShare = 0.85
    /// Speaker-level microphone share that marks a local speaker.
    static let localShare = 0.7
    /// Seconds of evidence required before trusting a source split.
    static let minimumEvidence: TimeInterval = 3

    private struct Analysis {
        let cue: Cue
        var scores: [Float]
        /// Microphone power / total power, nil when the frames are silent
        /// or have no recorded levels.
        let microphoneShare: Double?
        var slot: Int?
        var duration: TimeInterval { max(cue.end - cue.start, 0) }
    }

    /// The new label for every cue the speaker pass could resolve.
    /// `probabilities` holds four values per 80 ms frame from note start;
    /// `levels` is the matching per-frame source loudness (may be empty).
    public static func labels(
        cues: [Cue], probabilities: [Float], levels: [SourceLevel]
    ) -> [Int: String] {
        let frameCount = probabilities.count / slots
        var analyses = cues.map { analyze($0, probabilities: probabilities, frames: frameCount, levels: levels) }

        let localSlot = localSpeakerSlot(analyses)
        if let localSlot { correctSources(&analyses, localSlot: localSlot) }

        let names = slotNames(analyses, localSlot: localSlot)
        var result: [Int: String] = [:]
        for analysis in analyses {
            if let slot = analysis.slot, let name = names[slot] { result[analysis.cue.index] = name }
        }
        return result
    }

    private static func analyze(
        _ cue: Cue, probabilities: [Float], frames: Int, levels: [SourceLevel]
    ) -> Analysis {
        let first = max(0, Int((cue.start / CutConstants.frameSeconds).rounded(.down)))
        let last = min(frames, max(first + 1, Int((cue.end / CutConstants.frameSeconds).rounded(.up))))
        var scores = [Float](repeating: 0, count: slots)
        if first < last {
            for frame in first..<last {
                for slot in 0..<slots { scores[slot] += probabilities[frame * slots + slot] }
            }
        }
        var microphone = 0.0
        var system = 0.0
        var levelFrames = 0
        let levelEnd = min(levels.count, max(first + 1, Int((cue.end / CutConstants.frameSeconds).rounded(.up))))
        if first < levelEnd {
            for frame in first..<levelEnd {
                microphone += Double(levels[frame].microphone * levels[frame].microphone)
                system += Double(levels[frame].system * levels[frame].system)
                levelFrames += 1
            }
        }
        let total = microphone + system
        let share = levelFrames > 0 && total / Double(levelFrames) > minimumPower ? microphone / total : nil
        let best = scores.indices.max { scores[$0] < scores[$1] }
        let slot = best.flatMap { scores[$0] >= minimumScore ? $0 : nil }
        return Analysis(cue: cue, scores: scores, microphoneShare: share, slot: slot)
    }

    /// The one speaker heard mainly through the microphone, when the
    /// recording also has speech from the call. With several local voices
    /// (an in-room meeting) nobody is called "You".
    private static func localSpeakerSlot(_ analyses: [Analysis]) -> Int? {
        let remoteEvidence = analyses.filter { ($0.microphoneShare ?? 1) <= 1 - localShare }
            .reduce(0) { $0 + $1.duration }
        guard remoteEvidence >= minimumEvidence else { return nil }
        var shareSum = [Double](repeating: 0, count: slots)
        var known = [TimeInterval](repeating: 0, count: slots)
        var microphoneOnly = [TimeInterval](repeating: 0, count: slots)
        for analysis in analyses {
            guard let slot = analysis.slot, let share = analysis.microphoneShare else { continue }
            shareSum[slot] += share * analysis.duration
            known[slot] += analysis.duration
            if share >= strongShare { microphoneOnly[slot] += analysis.duration }
        }
        let local = (0..<slots).filter { known[$0] >= minimumEvidence && shareSum[$0] / known[$0] >= localShare }
        if local.count == 1 { return local[0] }
        guard local.isEmpty else { return nil }
        // The model may have merged some call audio into the local voice.
        // Fall back to where the clearly microphone-only lines went.
        let total = microphoneOnly.reduce(0, +)
        guard total >= minimumEvidence,
            let best = microphoneOnly.indices.max(by: { microphoneOnly[$0] < microphoneOnly[$1] })
        else { return nil }
        return microphoneOnly[best] / total >= localShare ? best : nil
    }

    /// Fixes cues whose source contradicts their speaker: a clearly
    /// microphone-only cue belongs to the local speaker, and a clearly
    /// call-only cue cannot.
    private static func correctSources(_ analyses: inout [Analysis], localSlot: Int) {
        var remoteDuration = [TimeInterval](repeating: 0, count: slots)
        for analysis in analyses where analysis.slot != localSlot {
            if let slot = analysis.slot { remoteDuration[slot] += analysis.duration }
        }
        let mostCommonRemote = remoteDuration.indices.filter { $0 != localSlot && remoteDuration[$0] > 0 }
            .max { remoteDuration[$0] < remoteDuration[$1] }
        for index in analyses.indices {
            guard let share = analyses[index].microphoneShare, analyses[index].slot != nil else { continue }
            if share >= strongShare {
                analyses[index].slot = localSlot
            } else if share <= 1 - strongShare, analyses[index].slot == localSlot {
                let scores = analyses[index].scores
                let alternative = scores.indices.filter { $0 != localSlot }.max { scores[$0] < scores[$1] }
                if let alternative, scores[alternative] >= minimumScore {
                    analyses[index].slot = alternative
                } else if let mostCommonRemote {
                    analyses[index].slot = mostCommonRemote
                }
            }
        }
    }

    /// Display names per slot. A name the user (or the fixer) gave a
    /// speaker is kept when it is that speaker's most common old label (live
    /// labels drift between sessions, so a rename rarely covers every line);
    /// the local speaker is "You"; every other speaker is numbered in order
    /// of first appearance.
    private static func slotNames(_ analyses: [Analysis], localSlot: Int?) -> [Int: String] {
        var oldLabels: [Int: [String: TimeInterval]] = [:]
        var firstStart: [Int: TimeInterval] = [:]
        for analysis in analyses {
            guard let slot = analysis.slot else { continue }
            firstStart[slot] = min(firstStart[slot] ?? .infinity, analysis.cue.start)
            oldLabels[slot, default: [:]][analysis.cue.speaker, default: 0] += analysis.duration
        }

        var names: [Int: String] = [:]
        var used = Set<String>()
        var candidates: [(slot: Int, name: String, duration: TimeInterval)] = []
        for (slot, labels) in oldLabels {
            let top = labels.values.max() ?? 0
            for (name, duration) in labels where SpeakerLabel.slot(name: name) == nil && duration >= top {
                candidates.append((slot, name, duration))
            }
        }
        candidates.sort { $0.duration != $1.duration ? $0.duration > $1.duration : $0.name < $1.name }
        for candidate in candidates where names[candidate.slot] == nil && !used.contains(candidate.name) {
            names[candidate.slot] = candidate.name
            used.insert(candidate.name)
        }
        if let localSlot, names[localSlot] == nil, !used.contains(localSpeakerName) {
            names[localSlot] = localSpeakerName
            used.insert(localSpeakerName)
        }
        var number = 0
        for slot in firstStart.keys.sorted(by: { firstStart[$0]! < firstStart[$1]! }) where names[slot] == nil {
            repeat { number += 1 } while used.contains(SpeakerLabel.name(slot: number - 1))
            names[slot] = SpeakerLabel.name(slot: number - 1)
        }
        return names
    }
}

/// Runs the whole-file speaker pass on a stopped recording and applies the
/// new labels through the note's transcript outbox (its single writer).
public struct SpeakerRelabeler: Sendable {
    /// Whole-file decoding keeps the recording in memory (about 230 MB per
    /// hour including the model's features), so very long notes keep their
    /// live labels.
    public static let maxDuration: TimeInterval = 2 * 3600

    private let analyze: @Sendable ([Float]) async throws -> [Float]

    public init() {
        self.init { samples in
            let diarizer = try await SpeechModelPool.shared.offlineDiarizer()
            return try diarizer.processComplete(samples).finalizedPredictions
        }
    }

    init(analyze: @escaping @Sendable ([Float]) async throws -> [Float]) {
        self.analyze = analyze
    }

    /// Returns the number of cues whose speaker changed.
    @concurrent
    public nonisolated func relabel(noteFolderURL: URL, outbox: TranscriptOutbox) async throws -> Int {
        let transcriptURL = VTT.fileURL(noteFolder: noteFolderURL)
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return 0 }
        var cues: [SpeakerAssignment.Cue] = []
        for case .cue(let index, let start, let end, let speaker, _, _) in try VTTParser.parse(text).entries {
            cues.append(.init(index: index, start: start, end: end, speaker: speaker))
        }
        guard cues.count > 1 else { return 0 }

        let decoder = try OpusWebMDecoder(fileURL: NoteLayout.audioURL(noteFolder: noteFolderURL))
        guard TimeInterval(decoder.endMilliseconds) / 1000 <= Self.maxDuration else { return 0 }
        var samples: [Float] = []
        samples.reserveCapacity(Int(decoder.endMilliseconds) * (CutConstants.sampleRate / 1000))
        let packets = try decoder.packets(from: 0)
        while let chunk = try packets.next(maxSamples: CutConstants.sampleRate * 10) {
            try Task.checkCancellation()
            samples.append(contentsOf: chunk.samples)
        }
        let probabilities = try await analyze(samples)
        samples = []
        try Task.checkCancellation()

        let levels = SourceLevelsWriter.read(url: NoteLayout.sourceLevelsURL(noteFolder: noteFolderURL))
        let labels = SpeakerAssignment.labels(cues: cues, probabilities: probabilities, levels: levels)
        let edits = cues.compactMap { cue -> TranscriptOutbox.CueEdit? in
            guard let label = labels[cue.index], label != cue.speaker else { return nil }
            return .init(index: cue.index, speaker: label, text: nil)
        }
        try outbox.applyEdits(edits)
        return edits.count
    }
}
