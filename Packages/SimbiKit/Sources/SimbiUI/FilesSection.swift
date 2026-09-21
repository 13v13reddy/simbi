import AppKit
import SimbiKit
import SwiftUI
import UniformTypeIdentifiers

/// Stable paperclip action in the editor tab strip. Attachments remain
/// available on an empty note and never consume permanent editor height.
struct AttachmentsButton: View {
    let model: FilesModel
    @State private var presented = false

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            Image(systemName: "paperclip")
                .font(.meta)
                .foregroundStyle(.secondary)
                .overlay(alignment: .topTrailing) {
                    if !model.rows.isEmpty {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -2)
                    }
                }
        }
        .buttonStyle(HoverCircleButtonStyle(inset: Design.iconGap))
        .help("Attachments")
        .accessibilityLabel("Attachments")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            AttachmentsPopover(model: model)
        }
    }
}

private struct AttachmentsPopover: View {
    let model: FilesModel
    @State private var showImporter = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Attachments")
                    .font(.headline)
                if !model.rows.isEmpty {
                    Text("\(model.rows.count)")
                        .font(.meta)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Add Files", systemImage: "plus") {
                    showImporter = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(HoverCircleButtonStyle(inset: Design.iconGap))
                .help("Add Files…")
            }
            .padding(Design.paneInset)

            Divider()

            if model.rows.isEmpty {
                VStack(spacing: Design.rowGap) {
                    Image(systemName: "paperclip")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    VStack(spacing: Design.innerGap) {
                        Text("No attachments")
                            .font(.body.weight(.semibold))
                        Text("Add files to make them available to this note's Chat.")
                            .font(.meta)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button("Add Files…") { showImporter = true }
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .padding(Design.paneInset)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            AttachmentRow(model: model, row: row)
                        }
                    }
                    .padding(.vertical, Design.stripPadding)
                }
                .frame(maxHeight: 320)
            }

            if let error = model.importError {
                Divider()
                Text(error)
                    .font(.meta)
                    .foregroundStyle(Color.statusLive)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Design.paneInset)
            }
        }
        .frame(width: 360)
        .background(Color.accentColor.opacity(isDropTargeted ? 0.08 : 0))
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.card)
                .stroke(
                    Color.accentColor.opacity(isDropTargeted ? 1 : 0),
                    lineWidth: 2)
        }
        .animation(Design.Anim.quick, value: isDropTargeted)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.importFiles(urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.importFiles(files)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
    }
}

private struct AttachmentRow: View {
    let model: FilesModel
    let row: FilesModel.Row
    @State private var hovered = false

    private var fileURL: URL { model.fileURL(for: row.name) }

    var body: some View {
        HStack(spacing: Design.rowGap) {
            statusIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: Design.innerGap) {
                Text(row.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusLabel)
                    .font(.meta)
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: Design.rowGap)

            if case .failed = row.status {
                Button("Retry", systemImage: "arrow.clockwise") {
                    model.retry(row.name)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(HoverCircleButtonStyle(inset: Design.iconGap))
                .help("Retry conversion")
            }

            Button("Move to Trash", systemImage: "trash") {
                model.delete(row.name)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(HoverCircleButtonStyle(inset: Design.iconGap))
            .foregroundStyle(hovered ? Color.destructiveAction : Color.secondary)
            .opacity(hovered ? 1 : 0)
            .accessibilityHidden(!hovered)
            .help("Move to Trash")
        }
        .padding(.horizontal, Design.paneInset)
        .padding(.vertical, Design.stripPadding)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(fileURL) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(fileURL) }
            if case .done = row.status {
                Button("Open Context") {
                    ContextEditorWindowManager.shared.open(
                        fileURL: model.contextURL(for: row.name),
                        title: "Context: \(row.name)")
                }
            }
            if row.threadId != nil {
                Button("View Codex Thread") { model.openThreadViewer(row.name) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
        .hoverFill(
            RoundedRectangle(cornerRadius: Design.Radius.row),
            horizontalBleed: -Design.iconGap)
    }

    @ViewBuilder private var statusIcon: some View {
        switch row.status {
        case .converting:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.statusWarning)
        case .done:
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var statusLabel: String {
        switch row.status {
        case .converting: "Preparing for Chat…"
        case .failed: "Conversion failed"
        case .done: "Ready for Chat"
        }
    }

    private var statusColor: Color {
        if case .failed = row.status { return .statusWarning }
        return .secondary
    }
}
