import Foundation
import Testing

@testable import SimbiKit

@Suite("NoteSearch")
struct NoteSearchTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "note-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func makeNote(
        _ path: String, notes: String = "", summary: String? = nil,
        cues: [(TimeInterval, String, String)] = [], context: [String: String] = [:]
    ) throws -> URL {
        let note = root.appending(path: path)
        try FileManager.default.createDirectory(at: note, withIntermediateDirectories: true)
        try notes.write(to: note.appending(path: "note.md"), atomically: true, encoding: .utf8)
        if let summary {
            try summary.write(to: NoteLayout.summaryURL(noteFolder: note), atomically: true, encoding: .utf8)
        }
        if !cues.isEmpty {
            var vtt = VTT.header(noteName: note.lastPathComponent)
            for (index, cue) in cues.enumerated() {
                vtt += VTT.render(
                    .cue(
                        index: index + 1, start: cue.0, end: cue.0 + 4, speaker: cue.1, text: cue.2,
                        continuation: false))
            }
            try vtt.write(to: VTT.fileURL(noteFolder: note), atomically: true, encoding: .utf8)
        }
        if !context.isEmpty {
            let dir = NoteLayout.contextDirURL(noteFolder: note)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, text) in context {
                try text.write(
                    to: NoteLayout.contextURL(noteFolder: note, fileName: name), atomically: true, encoding: .utf8)
            }
        }
        return note
    }

    private func search(_ query: String) -> [NoteSearchResult] {
        NoteSearch.search(query, notes: NoteSearch.noteFolders(in: FileTreeScanner.scan(root: root)), root: root)
    }

    @Test("finds text in every searchable file and reports where it was found")
    func searchesEverySource() throws {
        _ = try makeNote(
            "Work/Weekly Sync", notes: "# Agenda\n- budget review", summary: "## Decisions\n- Budget approved",
            cues: [(65, "Dana", "The budget is fine."), (90, "Sam", "Unrelated.")],
            context: ["plan.pdf": "Q3 budget table"])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try #require(search("budget").first)
        #expect(result.noteName == "Weekly Sync")
        #expect(result.folderPath == "Work")
        #expect(!result.titleMatches)
        #expect(result.matchCount == 4)
        #expect(
            result.snippets.map(\.source) == [.notes, .aiNotes, .transcript(start: 65, speaker: "Dana")])
        #expect(result.snippets.map(\.text) == ["budget review", "Budget approved", "Dana: The budget is fine."])

        let context = try #require(NoteSearch.search("Q3", notes: [result.noteURL], root: root).first)
        #expect(context.snippets.map(\.source) == [.context(fileName: "plan.pdf")])
    }

    @Test("every term must appear somewhere in the note, in any file")
    func requiresAllTerms() throws {
        _ = try makeNote("Launch", notes: "rollback plan", cues: [(0, "Speaker 1", "ship it Friday")])
        _ = try makeNote("Other", notes: "rollback only")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(search("rollback friday").map(\.noteName) == ["Launch"])
        #expect(search("rollback").count == 2)
        #expect(search("nothing-here").isEmpty)
        #expect(search("   ").isEmpty)
    }

    @Test("matching ignores case and diacritics, and speaker names are searchable")
    func caseAndDiacritics() throws {
        _ = try makeNote("Café chat", cues: [(12, "Zoë", "Résumé review")])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try #require(search("CAFE resume").first)
        #expect(result.titleMatches)
        #expect(search("zoe").first?.snippets.first?.source == .transcript(start: 12, speaker: "Zoë"))
    }

    @Test("title matches rank first and the title is never shown as a snippet")
    func titleFirst() throws {
        _ = try makeNote("Notes", notes: "about hiring")
        _ = try makeNote("Hiring sync", notes: "agenda")
        defer { try? FileManager.default.removeItem(at: root) }

        let results = search("hiring")
        #expect(results.map(\.noteName) == ["Hiring sync", "Notes"])
        #expect(results[0].snippets.isEmpty)
    }

    @Test("snippets prefer lines that match more terms and respect the limit")
    func snippetRanking() throws {
        _ = try makeNote("N", notes: "alpha\nalpha\nalpha beta\nalpha\nbeta")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try #require(search("alpha beta").first)
        #expect(result.snippets.map(\.text) == ["alpha beta", "alpha", "alpha"])
        #expect(result.matchCount == 5)
    }

    @Test("markdown markers are stripped and long lines are windowed around the match")
    func snippetFormatting() {
        #expect(NoteSearch.stripMarkdownMarker("## Heading") == "Heading")
        #expect(NoteSearch.stripMarkdownMarker("- [ ] Dana files the update") == "Dana files the update")
        #expect(NoteSearch.stripMarkdownMarker("  12. Twelfth item") == "Twelfth item")
        #expect(NoteSearch.stripMarkdownMarker("3.5 percent growth") == "3.5 percent growth")

        let long = String(repeating: "x ", count: 150) + "needle" + String(repeating: " y", count: 150)
        let window = NoteSearch.window(long, around: ["needle"])
        #expect(window.hasPrefix("…") && window.hasSuffix("…"))
        #expect(window.contains("needle"))
        #expect(window.count <= NoteSearch.snippetWidth + 2)
        #expect(NoteSearch.window("short needle", around: ["needle"]) == "short needle")
    }

    @Test("only note folders are searched, including nested ones")
    func nestedNotes() throws {
        _ = try makeNote("A/B/Deep", notes: "keyword")
        try "keyword".write(to: root.appending(path: "loose.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let results = search("keyword")
        #expect(results.map(\.noteName) == ["Deep"])
        #expect(results.first?.folderPath == "A/B")
    }
}
