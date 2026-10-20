import Foundation
import SimbiKit
import Testing

@testable import SimbiUI

@Suite("FileTreeModel live filesystem")
struct FileTreeModelTests {
    @Test("an active note and its parent cannot be renamed", arguments: [false, true])
    @MainActor
    func refusesRenameWhileBusy(parent: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "simbi-tree-busy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let group = root.appending(path: "Group")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let note = try NoteOperations.createNote(named: "Meeting", in: group)
        let model = FileTreeModel(home: SimbiHome(rootURL: root), activeNoteFolders: { [note] })
        model.refresh()
        model.selection = note

        model.rename(parent ? group : note, to: "Renamed")

        #expect(FileManager.default.fileExists(atPath: note.path))
        #expect(model.selection == note)
        #expect(model.operationError?.contains("Meeting") == true)
    }

    @Test("a busy note prevents trash and makes a multi-item move all-or-nothing")
    @MainActor
    func refusesTrashAndMoveWhileBusy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "simbi-tree-busy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let group = root.appending(path: "Group")
        let destination = root.appending(path: "Archive")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let note = try NoteOperations.createNote(named: "Meeting", in: group)
        let other = try NoteOperations.createNote(named: "Other", in: root)
        let model = FileTreeModel(home: SimbiHome(rootURL: root), activeNoteFolders: { [note] })
        model.refresh()

        model.trash(note)
        model.trash(group)
        #expect(FileManager.default.fileExists(atPath: note.path))
        #expect(model.move([other, group], into: destination, at: nil) == false)
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: note.path))
        #expect(model.move([note], into: group, at: 0))
    }

    @Test("unrelated notes remain movable and a finished note can be renamed")
    @MainActor
    func permitsUnrelatedAndFinishedNotes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "simbi-tree-busy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let group = root.appending(path: "Group")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let note = try NoteOperations.createNote(named: "Meeting", in: root)
        let other = try NoteOperations.createNote(named: "Meeting 2", in: root)
        var active = [note]
        let model = FileTreeModel(home: SimbiHome(rootURL: root), activeNoteFolders: { active })
        model.refresh()
        #expect(model.move([other], into: group, at: nil))
        #expect(FileManager.default.fileExists(atPath: group.appending(path: "Meeting 2").path))
        active = []
        model.rename(note, to: "Finished")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Finished").path))
        #expect(model.operationError == nil)
    }

    @Test("an externally moved parent keeps the selected note open")
    @MainActor
    func followsExternalMove() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "simbi-tree-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let group = root.appending(path: "Group")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let note = try NoteOperations.createNote(named: "Meeting", in: group)
        let model = FileTreeModel(home: SimbiHome(rootURL: root))
        model.refresh()
        model.selection = note

        let movedGroup = root.appending(path: "Renamed Group")
        try FileManager.default.moveItem(at: group, to: movedGroup)
        model.refresh()

        #expect(model.selection?.path == movedGroup.appending(path: "Meeting").path)
        #expect(model.selectedNode?.name == "Meeting")
    }

    @Test("renaming an idle note flushes its pending editor save at the original path first")
    @MainActor
    func renameFlushesPendingEditor() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "simbi-tree-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let note = try NoteOperations.createNote(named: "Meeting", in: root)
        let document = AutosavingDocument(fileURL: note.appending(path: "note.md"))
        document.text = "Unsaved meeting notes"
        document.scheduleAutosave()
        let model = FileTreeModel(home: SimbiHome(rootURL: root), activeNoteFolders: { [] })
        model.rename(note, to: "Renamed")
        document.saveNow()
        #expect(
            try String(contentsOf: root.appending(path: "Renamed/note.md"), encoding: .utf8) == "Unsaved meeting notes")
        #expect(!FileManager.default.fileExists(atPath: note.path))
        #expect(model.operationError == nil)
    }
}
