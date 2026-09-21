import Foundation
import Testing

@testable import CodexKit

@Suite("Note chat instructions")
struct NoteChatInstructionsTests {
    private struct TempNote {
        let home: URL
        let note: URL
        func cleanup() { try? FileManager.default.removeItem(at: home) }
    }

    private func makeNote(files: [String: String]) throws -> TempNote {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "note-chat-instructions-\(UUID().uuidString)")
        let note = home.appending(path: "Work/Standup")
        try FileManager.default.createDirectory(
            at: note, withIntermediateDirectories: true)
        for (name, content) in files {
            let target = note.appending(path: name)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target, atomically: true, encoding: .utf8)
        }
        return TempNote(home: home, note: note)
    }

    @Test("instructions inventory note files and refresh converted context")
    func inventoryAndRefresh() throws {
        let temp = try makeNote(files: [
            "note.md": "hello",
            "transcript.vtt": "WEBVTT",
            "context/slides.md": "converted",
            "files/slides.pdf": "raw",
            ".DS_Store": "hidden",
        ])
        defer { temp.cleanup() }

        let text = NoteChatInstructions.developerInstructions(
            noteFolderURL: temp.note, homeRootURL: temp.home)
        #expect(text.contains("Work/Standup"))
        #expect(text.contains("`note.md`"))
        #expect(text.contains("`transcript.vtt`"))
        #expect(text.contains("`context/slides.md`"))
        #expect(text.contains("`files/slides.pdf`"))
        #expect(!text.contains(".DS_Store"))
        #expect(text.contains("Before every answer, re-list `context/`"))
    }

    @Test("app-owned contract remains read-only with a custom CHAT template")
    func readOnlyCustomTemplate() throws {
        let temp = try makeNote(files: ["note.md": "hi"])
        defer { temp.cleanup() }
        try "Help with {{ note_path }} and edit it. {{ files }}".write(
            to: temp.home.appending(path: "CHAT.md"),
            atomically: true, encoding: .utf8)

        let text = NoteChatInstructions.developerInstructions(
            noteFolderURL: temp.note, homeRootURL: temp.home)
        #expect(text.contains("Help with Work/Standup and edit it."))
        #expect(text.contains("This chat is read-only"))
        #expect(text.contains("never create, edit, move, rename, or delete"))
    }

    @Test("empty notes are described without inventing files")
    func emptyNote() throws {
        let temp = try makeNote(files: [:])
        defer { temp.cleanup() }
        let text = NoteChatInstructions.developerInstructions(
            noteFolderURL: temp.note, homeRootURL: temp.home)
        #expect(text.contains("no files yet"))
        #expect(!text.contains("currently contains"))
    }
}
