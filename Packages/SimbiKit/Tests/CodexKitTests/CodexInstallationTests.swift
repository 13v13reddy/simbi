import Foundation
import Testing

@testable import CodexKit

@Suite("CodexAuth")
struct CodexAuthTests {
    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "auth-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("parses a ChatGPT-mode auth.json")
    func parsesValidAuth() throws {
        let url = try write(
            """
            {"auth_mode": "chatgpt",
             "tokens": {"access_token": "tok-123", "account_id": "acct-456"}}
            """)
        defer { try? FileManager.default.removeItem(at: url) }

        let auth = try CodexAuth.load(from: url)
        #expect(auth.accessToken == "tok-123")
        #expect(auth.accountId == "acct-456")
    }

    @Test("rejects non-ChatGPT login modes")
    func rejectsApiKeyMode() throws {
        let url = try write(#"{"auth_mode": "apikey", "OPENAI_API_KEY": "sk-x"}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: CodexAuth.LoadError.notChatGPTLogin) {
            try CodexAuth.load(from: url)
        }
    }

    @Test("rejects missing credentials")
    func rejectsMissingTokens() throws {
        let url = try write(#"{"auth_mode": "chatgpt", "tokens": {}}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: CodexAuth.LoadError.missingCredentials) {
            try CodexAuth.load(from: url)
        }
    }
}

@Suite("CodexInstallation")
struct CodexInstallationTests {
    @Test("current ChatGPT layout resolves the bundled Codex executable")
    func resolvesCurrentChatGPTLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "codex-installation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let appBundleURL = root.appending(path: "ChatGPT.app", directoryHint: .isDirectory)
        let binaryURL = appBundleURL.appending(
            path: "Contents/Resources/codex-cli/bin/codex")
        try FileManager.default.createDirectory(
            at: binaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: binaryURL.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        let installation = CodexInstallation(
            appBundleURL: appBundleURL,
            codexHomeURL: root.appending(path: ".codex", directoryHint: .isDirectory))

        #expect(installation.binaryURL == binaryURL)
        #expect(installation.isBinaryInstalled)
    }

    @Test("legacy ChatGPT layout remains supported")
    func resolvesLegacyChatGPTLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "codex-installation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let appBundleURL = root.appending(path: "ChatGPT.app", directoryHint: .isDirectory)
        let binaryURL = appBundleURL.appending(path: "Contents/Resources/codex")
        try FileManager.default.createDirectory(
            at: binaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: binaryURL.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        let installation = CodexInstallation(
            appBundleURL: appBundleURL,
            codexHomeURL: root.appending(path: ".codex", directoryHint: .isDirectory))

        #expect(installation.binaryURL == binaryURL)
        #expect(installation.appBundleURL == appBundleURL)
    }

    @Test("absence of binary and auth is reported, not fatal")
    func reportsAbsence() {
        let missing = CodexInstallation(
            binaryURL: URL(filePath: "/nonexistent/codex"),
            codexHomeURL: URL(filePath: "/nonexistent/.codex"))
        #expect(!missing.isBinaryInstalled)
        #expect(missing.loadAuth() == nil)
    }

    @Test("standard install points at the ChatGPT app bundle and ~/.codex")
    func standardPaths() {
        let std = CodexInstallation.standard
        #expect(
            [
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex",
            ].contains(std.binaryURL.path))
        #expect(std.appBundleURL.path == "/Applications/ChatGPT.app")
        #expect(std.authFileURL.lastPathComponent == "auth.json")
        #expect(std.codexHomeURL.lastPathComponent == ".codex")
    }
}
