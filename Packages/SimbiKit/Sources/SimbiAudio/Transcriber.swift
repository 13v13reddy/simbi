import CodexKit
import Foundation

/// Transcription backend. The real implementation uploads to
/// `backend-api/transcribe`; tests script their own fakes.
public protocol Transcriber: Sendable {
    /// Returns the transcription text for one encoded WebM/Opus segment.
    /// Single attempt; the pipeline owns retry/backoff (guide §9.2).
    func transcribe(webmFile: URL) async throws -> String
}

/// The production transcriber: Codex-credentialed uploads.
public struct CodexTranscriber: Transcriber {
    private let upload: @Sendable (Data) async throws -> String
    private let refreshAuthentication: (@Sendable () async throws -> Void)?

    /// `refreshAuthentication` renews the ChatGPT login when the server
    /// rejects the saved token. Without it, an expired token stalls uploads
    /// until the ChatGPT app happens to renew `~/.codex/auth.json`.
    public init(refreshAuthentication: (@Sendable () async throws -> Void)? = nil) {
        let client = TranscriptionClient()
        self.init(upload: { try await client.transcribe(webmData: $0) }, refreshAuthentication: refreshAuthentication)
    }

    init(
        upload: @escaping @Sendable (Data) async throws -> String,
        refreshAuthentication: (@Sendable () async throws -> Void)?
    ) {
        self.upload = upload
        self.refreshAuthentication = refreshAuthentication
    }

    public func transcribe(webmFile: URL) async throws -> String {
        let data = try Data(contentsOf: webmFile)
        do {
            return try await upload(data)
        } catch TranscriptionClient.TranscriptionError.authRejected(let status) {
            guard let refreshAuthentication else {
                throw TranscriptionClient.TranscriptionError.authRejected(status: status)
            }
            do {
                try await refreshAuthentication()
            } catch {
                RecordingDiagnostics.warning("renewing the ChatGPT login failed: \(error)")
                throw TranscriptionClient.TranscriptionError.authRejected(status: status)
            }
            // One retry with the renewed token; a second rejection pauses
            // the upload queue as before.
            return try await upload(data)
        }
    }
}
