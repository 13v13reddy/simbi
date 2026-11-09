import Foundation

/// Locates the Codex (ChatGPT desktop) installation Simbi piggybacks on:
/// the bundled `codex` binary for the app-server (SPEC.md §5.1) and
/// `~/.codex/auth.json` for transcription credentials (SPEC.md §3.3).
///
/// Simbi stays fully functional for recording/diarization without either;
/// the UI shows a degraded-state banner instead (SPEC.md §6).
public struct CodexInstallation: Sendable, Equatable {
    public let binaryURL: URL
    /// The outer ChatGPT bundle, not the nested CodexCLI.app.
    public let appBundleURL: URL
    /// Must be `~/.codex` when spawning the app-server — the binary launched
    /// standalone defaults to a private home invisible to the ChatGPT app
    /// (references/codex-open/README.md, gotcha #1).
    public let codexHomeURL: URL

    public static let standard = CodexInstallation(
        appBundleURL: URL(filePath: "/Applications/ChatGPT.app"),
        codexHomeURL: FileManager.default.homeDirectoryForCurrentUser.appending(
            path: ".codex", directoryHint: .isDirectory)
    )

    public var authFileURL: URL {
        codexHomeURL.appending(path: "auth.json")
    }

    public init(binaryURL: URL, codexHomeURL: URL) {
        self.binaryURL = binaryURL
        self.codexHomeURL = codexHomeURL
        self.appBundleURL = binaryURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    init(appBundleURL: URL, codexHomeURL: URL) {
        self.appBundleURL = appBundleURL
        self.codexHomeURL = codexHomeURL
        let resources = appBundleURL.appending(path: "Contents/Resources")
        let nested = resources.appending(path: "codex-cli/CodexCLI.app/Contents/MacOS/codex")
        // Launch the executable directly so orphan-process matching uses the same path.
        self.binaryURL =
            FileManager.default.isExecutableFile(atPath: nested.path)
            ? nested : resources.appending(path: "codex")
    }

    public var isBinaryInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binaryURL.path)
    }

    /// The env pair every terminal launch spec starts from: without
    /// CODEX_HOME the standalone binary uses a private home invisible to
    /// the ChatGPT app login, and SIMBI_CODEX_BIN carries the binary path
    /// into the constant command lines (quoting-free by design).
    public var terminalLaunchEnvironment: [String: String] {
        [
            "CODEX_HOME": codexHomeURL.path,
            "SIMBI_CODEX_BIN": binaryURL.path,
        ]
    }

    /// Where "Get ChatGPT" sends the user.
    public static let downloadURL = URL(string: "https://chatgpt.com/download")!

    /// Loads credentials, or `nil` if absent/not a ChatGPT login.
    public func loadAuth() -> CodexAuth? {
        try? CodexAuth.load(from: authFileURL)
    }
}

/// The subset of `~/.codex/auth.json` the transcription client needs
/// (references/codex-transcription/transcribe.mjs).
public struct CodexAuth: Sendable, Equatable {
    public let accessToken: String
    public let accountId: String

    public enum LoadError: Error, Equatable {
        case notChatGPTLogin
        case missingCredentials
    }

    public init(accessToken: String, accountId: String) {
        self.accessToken = accessToken
        self.accountId = accountId
    }

    public static func load(from url: URL) throws -> CodexAuth {
        struct AuthFile: Decodable {
            struct Tokens: Decodable {
                var accessToken: String?
                var accountId: String?
            }
            var authMode: String?
            var tokens: Tokens?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let file = try decoder.decode(AuthFile.self, from: Data(contentsOf: url))
        guard file.authMode == "chatgpt" else { throw LoadError.notChatGPTLogin }
        guard let token = file.tokens?.accessToken, let account = file.tokens?.accountId else {
            throw LoadError.missingCredentials
        }
        return CodexAuth(accessToken: token, accountId: account)
    }
}
