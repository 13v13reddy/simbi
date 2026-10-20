import Foundation
import SimbiAudio
import SimbiKit

public enum RecordingProblem: Codable, Equatable, Sendable {
    case microphonePermission
    case microphonePermissionFallback
    case noAudio
    case writeStalled
    case recordingFailed
    case startupFailed
    case sourceUnavailable(RecordingSource, retrying: Bool)
    case sourceRecovered(RecordingSource)
    case microphoneFallback
    case transcriptSaveFailed
    case transcriptionFailed

    public var isTranscriptProblem: Bool { self == .transcriptSaveFailed || self == .transcriptionFailed }

    public func retryTitle(isCapturing: Bool) -> String {
        if self == .transcriptSaveFailed { return "Retry Saving Transcript" }
        if self == .transcriptionFailed { return "Retry Transcription" }
        return isFatal || !isCapturing ? "Retry Recording" : "Retry Audio"
    }

    public var isFatal: Bool {
        switch self {
        case .sourceUnavailable, .sourceRecovered, .microphoneFallback, .microphonePermissionFallback,
            .transcriptSaveFailed, .transcriptionFailed:
            false
        default: true
        }
    }

    public var message: String {
        switch self {
        case .microphonePermission:
            "Microphone access is denied. Enable Microphone access for Simbi in System Settings."
        case .microphonePermissionFallback:
            "Microphone access is denied. System audio can still be recorded. Enable Microphone access for Simbi, then retry audio."
        case .noAudio:
            "Recording stopped because no audio was arriving. Check your microphone and system audio permissions, then retry."
        case .writeStalled:
            "Recording stopped because audio was not being saved. Check free disk space and folder access, then retry."
        case .recordingFailed:
            "Recording stopped after an audio or file error. Audio saved before the error has been preserved. Retry to continue."
        case .startupFailed:
            "Recording could not start. Check your audio devices, permissions, and notes folder, then retry."
        case .sourceUnavailable(let source, let retrying):
            retrying
                ? "\(source.name) is not delivering audio. Simbi is reconnecting it; the other source can continue recording."
                : "\(source.name) is unavailable. Check its connection and permissions, then retry audio."
        case .microphoneFallback:
            "The selected microphone is not connected. Simbi is using the system default microphone."
        case .sourceRecovered(let source):
            "\(source.name) audio has resumed after an interruption. Some audio from the interruption may be missing."
        case .transcriptSaveFailed:
            "Simbi could not save the transcript. Check free disk space and folder access, then retry. Queued audio is kept for recovery."
        case .transcriptionFailed:
            "Some audio could not be transcribed. Your audio is saved. Check your connection and ChatGPT sign-in, then retry transcription."
        }
    }

    public var source: RecordingSource? {
        switch self {
        case .sourceUnavailable(let source, _), .sourceRecovered(let source): source
        case .microphonePermission, .microphonePermissionFallback, .microphoneFallback: .microphone
        default: nil
        }
    }

    public var settingsURL: URL? {
        if isRecovered { return nil }
        if self == .microphoneFallback { return URL(string: "x-apple.systempreferences:com.apple.preference.sound") }
        guard let source else {
            switch self {
            case .noAudio, .startupFailed:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security")
            default: return nil
            }
        }
        let pane = source == .microphone ? "Privacy_Microphone" : "Privacy_AudioCapture"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    public var isRecovered: Bool {
        if case .sourceRecovered = self { return true }
        return false
    }

    var notificationKey: String {
        if self == .transcriptSaveFailed { return "transcript-save-failed" }
        if self == .transcriptionFailed { return "transcription-failed" }
        if self == .microphoneFallback { return "microphone-fallback" }
        if let source { return "source-\(source.rawValue)" }
        return isFatal ? "recording-failed" : "recording-warning"
    }
}

public struct RecordingAlert: Equatable, Sendable {
    public let noteFolderURL: URL
    public let problem: RecordingProblem
}

struct StoredRecordingProblem: Codable {
    private static let queue = DispatchQueue(label: "app.getsimbi.mac.recording-issues", qos: .utility)
    let problem: RecordingProblem
    let occurredAt: Date

    static func fileURL(noteFolder: URL) -> URL {
        noteFolder.appending(path: NoteLayout.stateDirName).appending(path: "recording-issue.json")
    }

    static func load(noteFolder: URL) -> RecordingProblem? {
        let url = fileURL(noteFolder: noteFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).problem } catch {
            Log.recording.warning("reading recording issue failed: \(error)")
            return nil
        }
    }

    static func save(_ problem: RecordingProblem?, noteFolder: URL) {
        let url = fileURL(noteFolder: noteFolder)
        // Serialized writes also prevent a delayed warning from reappearing
        // after recovery/dismissal. None of this IO blocks capture or alerts.
        queue.async {
            do {
                if let problem {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(Self(problem: problem, occurredAt: .now))
                        .write(to: url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch { RecordingDiagnostics.warning("persisting recording issue failed: \(error)") }
        }
    }
}

@MainActor
protocol RecordingNotifying: AnyObject {
    func prepare()
    func post(problem: RecordingProblem, noteFolderURL: URL)
    func clear(noteFolderURL: URL)
}
