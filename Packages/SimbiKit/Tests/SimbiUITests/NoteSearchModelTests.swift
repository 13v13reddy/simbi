import Foundation
import SimbiKit
import Testing

@testable import SimbiUI

@MainActor
@Suite("NoteSearchModel")
struct NoteSearchModelTests {
    @Test("open results pick up edits to a note without retyping the query")
    func refreshesOnContentChange() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "search-model-\(UUID())")
        let note = root.appending(path: "Sync")
        try FileManager.default.createDirectory(at: note, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "agenda".write(to: note.appending(path: "note.md"), atomically: true, encoding: .utf8)

        let search = NoteSearchModel()
        search.update(nodes: FileTreeScanner.scan(root: root), root: root)
        search.query = "budget"
        try await waitUntil { !search.isSearching }
        #expect(search.results.isEmpty)

        // The tree is unchanged; only the file's contents are.
        try "budget review".write(to: note.appending(path: "note.md"), atomically: true, encoding: .utf8)
        search.contentChanged()
        #expect(!search.isSearching)
        try await waitUntil { !search.results.isEmpty }
        #expect(search.results.first?.snippets.first?.text == "budget review")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }
}
