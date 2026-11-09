import Foundation

/// Where a search hit was found inside a note folder.
public enum NoteSearchSource: Equatable, Hashable, Sendable {
    case title
    case notes
    case aiNotes
    /// A transcript cue; `start` is note-timeline seconds.
    case transcript(start: TimeInterval, speaker: String)
    /// A converted attachment, `context/<fileName>.md`.
    case context(fileName: String)
}

public struct NoteSearchSnippet: Equatable, Hashable, Sendable {
    public let source: NoteSearchSource
    /// One display line, trimmed to a window around the first match.
    public let text: String
}

public struct NoteSearchResult: Identifiable, Equatable, Sendable {
    public let noteURL: URL
    public let noteName: String
    /// The parent folder relative to the Simbi home ("" at the root).
    public let folderPath: String
    public let titleMatches: Bool
    /// Every matching line, including those beyond `snippets`.
    public let matchCount: Int
    public let snippets: [NoteSearchSnippet]

    public var id: URL { noteURL }
}

/// Full-text search over note folders. There is no index: every note is a
/// plain folder, so a search reads the files directly (SPEC.md §2.1).
///
/// A note matches when every query term appears somewhere in it (title,
/// note.md, summary.md, transcript.vtt or context/*.md). Matching ignores
/// case and diacritics.
public enum NoteSearch {
    /// Files larger than this are skipped rather than read on every keystroke.
    static let maxFileBytes = 8 * 1024 * 1024
    static let snippetWidth = 160

    public static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Every note folder in a scanned sidebar tree, depth first.
    public static func noteFolders(in nodes: [FileTreeNode]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            switch node.kind {
            case .note: [node.url]
            case .folder: noteFolders(in: node.children ?? [])
            case .file: []
            }
        }
    }

    /// Searches `notes`, newest first after title matches. Returns early with
    /// partial results when the calling task is cancelled.
    public static func search(
        _ query: String, notes: [URL], root: URL, snippetLimit: Int = 3
    ) -> [NoteSearchResult] {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return [] }
        var results: [(result: NoteSearchResult, modified: Date)] = []
        for note in notes {
            if Task.isCancelled { break }
            guard let result = search(terms: terms, note: note, root: root, snippetLimit: snippetLimit)
            else { continue }
            let modified =
                (try? note.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            results.append((result, modified))
        }
        return results.sorted { lhs, rhs in
            if lhs.result.titleMatches != rhs.result.titleMatches { return lhs.result.titleMatches }
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.result.noteName.localizedStandardCompare(rhs.result.noteName) == .orderedAscending
        }.map(\.result)
    }

    static func search(
        terms: [String], note: URL, root: URL, snippetLimit: Int
    ) -> NoteSearchResult? {
        let lines = searchableLines(note: note)
        var found = Set<Int>()
        var matches: [(line: (source: NoteSearchSource, text: String), hits: Int)] = []
        for line in lines {
            var hits = 0
            for (index, term) in terms.enumerated() where contains(line.text, term) {
                found.insert(index)
                hits += 1
            }
            if hits > 0 { matches.append((line, hits)) }
        }
        guard found.count == terms.count else { return nil }

        // Lines matching more of the query first; ties keep document order
        // (title, notes, AI notes, transcript, context).
        let ranked = matches.enumerated().sorted {
            $0.element.hits != $1.element.hits ? $0.element.hits > $1.element.hits : $0.offset < $1.offset
        }
        let snippets = ranked.lazy
            .filter { $0.element.line.source != .title }
            .prefix(snippetLimit)
            .map {
                NoteSearchSnippet(
                    source: $0.element.line.source,
                    text: window($0.element.line.text, around: terms))
            }
        let parent = note.deletingLastPathComponent().standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let folderPath =
            parent.hasPrefix(rootPath + "/") ? String(parent.dropFirst(rootPath.count + 1)) : ""
        return NoteSearchResult(
            noteURL: note, noteName: note.lastPathComponent, folderPath: folderPath,
            titleMatches: matches.contains { $0.line.source == .title },
            matchCount: matches.count, snippets: Array(snippets))
    }

    /// The note's searchable text as display lines, in a stable order.
    static func searchableLines(note: URL) -> [(source: NoteSearchSource, text: String)] {
        var lines: [(source: NoteSearchSource, text: String)] = [(.title, note.lastPathComponent)]
        func markdownLines(_ url: URL, as source: NoteSearchSource) {
            guard let text = read(url) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                let cleaned = stripMarkdownMarker(String(line))
                if !cleaned.isEmpty { lines.append((source, cleaned)) }
            }
        }
        markdownLines(note.appending(path: FileTreeScanner.noteMarkerName), as: .notes)
        markdownLines(NoteLayout.summaryURL(noteFolder: note), as: .aiNotes)
        if let text = read(VTT.fileURL(noteFolder: note)), let document = try? VTTParser.parse(text) {
            for case .cue(_, let start, _, let speaker, let cueText, _) in document.entries {
                // The speaker name is searchable so "Dana" finds what Dana said.
                lines.append((.transcript(start: start, speaker: speaker), "\(speaker): \(cueText)"))
            }
        }
        let contextDir = NoteLayout.contextDirURL(noteFolder: note)
        let contextFiles =
            ((try? FileManager.default.contentsOfDirectory(
                at: contextDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for file in contextFiles {
            markdownLines(file, as: .context(fileName: file.deletingPathExtension().lastPathComponent))
        }
        return lines
    }

    private static func read(_ url: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
            size <= maxFileBytes
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func contains(_ text: String, _ term: String) -> Bool {
        text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Drops heading, list, checkbox and quote markers so snippets read as text.
    static func stripMarkdownMarker(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        let prefixes = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "- ", "* ", "+ ", "> "]
        if text.hasPrefix("#") {
            text = String(text.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        } else if let prefix = prefixes.first(where: text.hasPrefix) {
            text = String(text.dropFirst(prefix.count))
        } else if let dot = text.firstIndex(of: "."), text[..<dot].allSatisfy(\.isNumber),
            !text[..<dot].isEmpty, text[dot...].hasPrefix(". ")
        {
            text = String(text[text.index(dot, offsetBy: 2)...])
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// A `snippetWidth`-character window that starts a little before the
    /// first matching term, with ellipses where text was cut.
    static func window(_ text: String, around terms: [String]) -> String {
        guard text.count > snippetWidth else { return text }
        let first =
            terms.compactMap {
                text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound
            }.min() ?? text.startIndex
        let lead = snippetWidth / 3
        let start = text.index(first, offsetBy: -lead, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: snippetWidth, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }
}
