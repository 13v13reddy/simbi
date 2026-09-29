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
        #expect(std.appBundleURL.path == "/Applications/ChatGPT.app")
        #expect(std.authFileURL.lastPathComponent == "auth.json")
        #expect(std.codexHomeURL.lastPathComponent == ".codex")
    }

    @Test("detects both bundle layouts and preserves the outer app for Open ChatGPT")
    func bundleLayouts() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let app = root.appending(path: "ChatGPT.app")
        let home = root.appending(path: ".codex")
        let legacy = app.appending(path: "Contents/Resources/codex")
        let nested = app.appending(path: "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        func installation() -> CodexInstallation {
            CodexInstallation(appBundleURL: app, codexHomeURL: home)
        }
        #expect(!installation().isBinaryInstalled)
        for binary in [legacy, nested] {
            try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            let detected = installation()
            #expect(detected.binaryURL == binary)
            #expect(detected.isBinaryInstalled)
            #expect(detected.appBundleURL == app)
            #expect(detected.terminalLaunchEnvironment["SIMBI_CODEX_BIN"] == binary.path)
        }
        try fm.removeItem(at: legacy)
        #expect(installation().binaryURL == nested)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nested.path)
        #expect(!installation().isBinaryInstalled)
    }
}
