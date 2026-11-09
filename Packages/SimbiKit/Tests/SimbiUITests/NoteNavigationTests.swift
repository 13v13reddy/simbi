import Foundation
import SimbiKit
import Testing

@testable import SimbiUI

@MainActor
@Suite("NoteNavigation")
struct NoteNavigationTests {
    @Test("a pending hit waits for its own note and is taken exactly once")
    func takeMatchesOnlyItsNote() {
        let navigation = NoteNavigation()
        let note = URL(filePath: "/tmp/Simbi/Work/Sync")
        navigation.open(note, at: .transcript(42))

        #expect(navigation.take(for: URL(filePath: "/tmp/Simbi/Other")) == nil)
        #expect(navigation.take(for: URL(filePath: "/tmp/Simbi/Work/../Work/Sync")) == .transcript(42))
        #expect(navigation.take(for: note) == nil)
    }

    @Test("snippets open the tab or transcript line they came from")
    func snippetTargets() {
        #expect(NoteSearchSource.notes.navigationTarget == .myNotes)
        #expect(NoteSearchSource.aiNotes.navigationTarget == .aiNotes)
        #expect(NoteSearchSource.transcript(start: 9, speaker: "Dana").navigationTarget == .transcript(9))
        #expect(NoteSearchSource.context(fileName: "deck.pdf").navigationTarget == nil)
    }
}
