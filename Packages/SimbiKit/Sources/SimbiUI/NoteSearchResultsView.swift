import SimbiKit
import SwiftUI

/// The sidebar's search field: replaces the folder tree with results while
/// it holds text. Esc clears it; Return opens the top result.
struct NoteSearchField: View {
    @Bindable var search: NoteSearchModel
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: Design.iconGap) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search notes", text: $search.query)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit(onSubmit)
                .onExitCommand {
                    search.clear()
                    focused.wrappedValue = false
                }
                .accessibilityLabel("Search all notes")
            if !search.query.isEmpty {
                Button {
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Design.Radius.row).fill(Color.trackFill))
        .help("Search titles, notes, AI notes, transcripts, and attached files (⇧⌘F)")
    }
}

struct NoteSearchResultsView: View {
    let search: NoteSearchModel
    let selection: URL?
    let open: (URL, NoteNavigation.Target?) -> Void

    var body: some View {
        if search.results.isEmpty {
            if search.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: search.query)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.stripPadding) {
                    Text(search.results.count == 1 ? "1 note" : "\(search.results.count) notes")
                        .font(.metaSemibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Design.stripPadding)
                    ForEach(search.results) { result in
                        resultRow(result)
                    }
                }
                .padding(.horizontal, Design.stripPadding)
                .padding(.vertical, Design.stripPadding)
            }
            .opacity(search.isSearching ? 0.6 : 1)
        }
    }

    private func resultRow(_ result: NoteSearchResult) -> some View {
        VStack(alignment: .leading, spacing: Design.innerGap) {
            Button {
                open(result.noteURL, nil)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(highlighted(result.noteName))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if let subtitle = subtitle(result) {
                        Text(subtitle)
                            .font(.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.stripPadding)
                .padding(.vertical, Design.innerGap)
                .contentShape(.rect)
            }
            .buttonStyle(SearchRowButtonStyle(isSelected: result.noteURL == selection))
            .accessibilityLabel("Open \(result.noteName)")

            ForEach(result.snippets, id: \.self) { snippet in
                Button {
                    open(result.noteURL, snippet.source.navigationTarget)
                } label: {
                    snippetLabel(snippet)
                }
                .buttonStyle(SearchRowButtonStyle(isSelected: false))
                .help(help(for: snippet.source))
            }
        }
    }

    private func snippetLabel(_ snippet: NoteSearchSnippet) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.iconGap) {
            Image(systemName: icon(for: snippet.source))
                .font(.micro)
                .foregroundStyle(.tertiary)
                .frame(width: 12)
                .accessibilityLabel(sourceName(snippet.source))
            VStack(alignment: .leading, spacing: 1) {
                if case .transcript(let start, _) = snippet.source {
                    Text(TimestampLink.render(start))
                        .font(.metaMono)
                        .foregroundStyle(.tertiary)
                } else if case .context(let fileName) = snippet.source {
                    Text(fileName)
                        .font(.micro)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(highlighted(snippet.text))
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Design.stripPadding + Design.iconGap)
        .padding(.trailing, Design.stripPadding)
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    /// "Work · 4 more matches"; nil when there is nothing to add.
    private func subtitle(_ result: NoteSearchResult) -> String? {
        let extra = result.matchCount - result.snippets.count - (result.titleMatches ? 1 : 0)
        let more = extra > 0 ? "\(extra) more \(extra == 1 ? "match" : "matches")" : nil
        let parts = [result.folderPath.isEmpty ? nil : result.folderPath, more].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Bold, primary-colored runs for every query term.
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for term in search.resultTerms {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                let range = text.range(
                    of: term, options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchStart..<text.endIndex)
            {
                if let attributedRange = Range(range, in: attributed) {
                    attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
                    attributed[attributedRange].foregroundColor = .primary
                }
                searchStart = range.upperBound
            }
        }
        return attributed
    }

    private func icon(for source: NoteSearchSource) -> String {
        switch source {
        case .title, .notes: "doc.text"
        case .aiNotes: "sparkles"
        case .transcript: "waveform"
        case .context: "paperclip"
        }
    }

    private func sourceName(_ source: NoteSearchSource) -> String {
        switch source {
        case .title: "Title"
        case .notes: "My Notes"
        case .aiNotes: "AI Notes"
        case .transcript(_, let speaker): "Transcript, \(speaker)"
        case .context(let fileName): "Attached file \(fileName)"
        }
    }

    private func help(for source: NoteSearchSource) -> String {
        switch source {
        case .title: "Open note"
        case .notes: "Open in My Notes"
        case .aiNotes: "Open in AI Notes"
        case .transcript: "Show this line in the transcript"
        case .context(let fileName): "Found in attached file \(fileName)"
        }
    }
}

private struct SearchRowButtonStyle: ButtonStyle {
    let isSelected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.row)
                    .fill(
                        configuration.isPressed
                            ? Color.pressFill
                            : isSelected ? Color.selectionBackplate : hovering ? Color.hoverFill : .clear)
            )
            .onHover { hovering = $0 }
    }
}
