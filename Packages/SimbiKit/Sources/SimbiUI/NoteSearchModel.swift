import Foundation
import Observation
import SimbiKit
import SwiftUI

/// Sidebar search state. Each query change restarts a short debounce, then
/// scans the note folders off the main actor; a newer query cancels the
/// older scan, so results always belong to the text in the field.
@MainActor
@Observable
final class NoteSearchModel {
    var query = "" {
        didSet { if query != oldValue { schedule(after: .milliseconds(150)) } }
    }
    private(set) var results: [NoteSearchResult] = []
    private(set) var isSearching = false
    /// The terms the current `results` were computed for (for highlighting).
    private(set) var resultTerms: [String] = []

    private var notes: [URL] = []
    private var root: URL?
    private var task: Task<Void, Never>?

    var isActive: Bool { !NoteSearch.terms(in: query).isEmpty }

    /// Called whenever the sidebar tree changes (notes added, renamed, moved).
    func update(nodes: [FileTreeNode], root: URL) {
        notes = NoteSearch.noteFolders(in: nodes)
        self.root = root
        if isActive { schedule(after: .milliseconds(300)) }
    }

    func clear() { query = "" }

    private func schedule(after delay: Duration) {
        task?.cancel()
        guard isActive, let root else {
            task = nil
            results = []
            resultTerms = []
            isSearching = false
            return
        }
        isSearching = true
        let query = query
        let notes = notes
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            let found = await Self.run(query, notes: notes, root: root)
            guard !Task.isCancelled, let self else { return }
            results = found
            resultTerms = NoteSearch.terms(in: query)
            isSearching = false
        }
    }

    /// File reads stay off the main actor; cancellation stops the scan early.
    @concurrent
    private nonisolated static func run(_ query: String, notes: [URL], root: URL) async -> [NoteSearchResult] {
        NoteSearch.search(query, notes: notes, root: root)
    }
}

/// ⇧⌘F routes to the sidebar field from anywhere in the main window.
@MainActor
@Observable
final class NoteSearchFocus {
    static let shared = NoteSearchFocus()
    private(set) var requests = 0
    func request() { requests += 1 }
}

/// Edit ▸ Search All Notes (⇧⌘F). ⌘F stays with the editors' own find bar.
public struct NoteSearchCommands: Commands {
    public init() {}

    public var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search All Notes") { NoteSearchFocus.shared.request() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}

/// A one-shot "open this note at that spot" hand-off from search to the
/// note view. The note view may not exist yet (it is built shortly after the
/// selection changes), so the request waits here until a matching view
/// takes it.
@MainActor
@Observable
final class NoteNavigation {
    static let shared = NoteNavigation()

    enum Target: Equatable {
        case myNotes
        case aiNotes
        /// Scroll to and flash the transcript cue at this note time.
        case transcript(TimeInterval)
    }

    struct Request: Equatable {
        let noteURL: URL
        let target: Target
        let id = UUID()
    }

    private(set) var request: Request?

    func open(_ noteURL: URL, at target: Target) {
        request = Request(noteURL: noteURL.standardizedFileURL, target: target)
    }

    /// Returns and clears the pending target if it is for `noteURL`.
    func take(for noteURL: URL) -> Target? {
        guard let request, request.noteURL == noteURL.standardizedFileURL else { return nil }
        self.request = nil
        return request.target
    }
}

extension NoteSearchSource {
    /// Where clicking a snippet lands. Attachment hits open the note itself.
    var navigationTarget: NoteNavigation.Target? {
        switch self {
        case .title, .context: nil
        case .notes: .myNotes
        case .aiNotes: .aiNotes
        case .transcript(let start, _): .transcript(start)
        }
    }
}
