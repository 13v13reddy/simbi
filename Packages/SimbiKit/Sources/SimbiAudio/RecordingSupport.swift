import Foundation
import SimbiKit

/// Support types for `RecordingPipeline` (split out for file size only).

/// Sidecar metadata persisted next to each pending segment upload
/// (`.simbi/pending/{cueIndex}.json`, guide §6.3 step 7).
public struct PendingSegment: Codable, Equatable, Sendable {
    public var cueIndex: Int
    public var startSec: TimeInterval
    public var endSec: TimeInterval
    public var speaker: Int
    public var continuation: Bool
    /// Optional for sidecars written by older versions. Failed requests are
    /// pending work, never a transcription result such as `[inaudible]`.
    public var transcriptionFailed: Bool? = nil

    static func load(cue: Int, in directory: URL) throws -> Self {
        let url = directory.appending(path: "\(cue).json")
        let segment = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard segment.cueIndex == cue else { throw CocoaError(.fileReadCorruptFile) }
        return segment
    }

    static func markTranscriptionFailure(_ failed: Bool, cue: Int, in directory: URL) throws {
        let url = directory.appending(path: "\(cue).json")
        var segment = try load(cue: cue, in: directory)
        segment.transcriptionFailed = failed ? true : nil
        try PersistedJSON.encoder().encode(segment).write(to: url, options: .atomic)
    }

    static func failedCueIndices(in directory: URL) throws -> Set<Int> {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }.reduce(into: Set<Int>()) { indices, url in
            guard let cue = Int(url.deletingPathExtension().lastPathComponent) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let segment = try load(cue: cue, in: directory)
            if segment.transcriptionFailed == true { indices.insert(segment.cueIndex) }
        }
    }
}

/// Live-UI snapshot emitted by the pipeline while recording.
public struct RecordingLiveUpdate: Equatable, Sendable {
    /// Note-timeline seconds (base + this session's samples).
    public let elapsed: TimeInterval
    /// Tentative "Speaker N speaking…" indicator slot, nil when silent.
    public let tentativeSpeaker: Int?
}

public enum RecordingPipelineError: Error, Equatable {
    case alreadyRecording
    case audioFileMismatch
    case notRecording
}
