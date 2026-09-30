import CodexKit
import Foundation
import SwiftUI

/// The selected Dialogue direction: compact right-aligned user bubbles and
/// full-width assistant prose, optimized for reading longer meeting answers.
struct NoteChatView: View {
    let controller: NoteChatController
    let onTimestamp: (String) -> Void

    @State private var draft = ""
    @State private var nearBottom = true

    var body: some View {
        VStack(spacing: 0) {
            if let notice = controller.historyNotice {
                StatusBanner(message: notice)
            }
            switch controller.phase {
            case .loading where controller.messages.isEmpty,
                .unloaded where controller.messages.isEmpty:
                loadingState
            default:
                conversation
            }
            failureBanner
            composer
        }
        .task { controller.activate() }
    }

    private var loadingState: some View {
        VStack(spacing: Design.rowGap) {
            Spacer()
            ProgressView()
            Text("Opening this note's Chat…")
                .font(.meta)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var conversation: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Design.chatMessageGap) {
                        if controller.messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(controller.messages) { message in
                                if message.role != .assistant || !message.text.isEmpty {
                                    MessageRow(message: message, onTimestamp: onTimestamp)
                                        .id(message.id)
                                }
                            }
                        }
                        if let label = Self.activityLabel(for: controller.phase) {
                            ChatActivityRow(label: label)
                                .id("chat-activity")
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("chat-bottom")
                            .background {
                                GeometryReader { bottom in
                                    Color.clear.preference(
                                        key: ChatBottomPreferenceKey.self,
                                        value: bottom.frame(in: .named("note-chat-scroll")).maxY)
                                }
                            }
                    }
                    .padding(.horizontal, Design.editorInset)
                    .padding(.vertical, Design.chatVerticalInset)
                }
                .coordinateSpace(name: "note-chat-scroll")
                .onPreferenceChange(ChatBottomPreferenceKey.self) { bottomY in
                    nearBottom = bottomY <= viewport.size.height + 80
                }
                .onChange(of: controller.messages) {
                    guard nearBottom else { return }
                    withAnimation(Design.Anim.standard) {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: controller.phase) { _, phase in
                    guard phase == .responding || phase == .retrying else { return }
                    withAnimation(Design.Anim.standard) {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Design.rowGap) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.title2)
                .foregroundStyle(.tertiary)
            VStack(spacing: Design.innerGap) {
                Text("Ask about this note")
                    .font(.body.weight(.semibold))
                Text("Chat can read My Notes, AI Notes, the transcript, and this note's attachments.")
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    @ViewBuilder private var failureBanner: some View {
        switch controller.phase {
        case .failed(let message):
            StatusBanner(
                message: message,
                actionTitle: "Retry",
                action: controller.retry)
        case .unavailable(let message):
            StatusBanner(
                message: message,
                actionTitle: "Try Again",
                action: controller.reconnect)
        default:
            EmptyView()
        }
    }

    private var composer: some View {
        VStack(spacing: Design.innerGap) {
            HStack(alignment: .bottom, spacing: Design.stripPadding) {
                TextField("Ask about this note…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .font(.body)
                    .onSubmit(submit)

                if controller.isBusy {
                    Button("Stop", systemImage: "stop.fill") {
                        controller.stop()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(HoverCircleButtonStyle(inset: Design.iconGap))
                    .disabled(!controller.canStop)
                    .help("Stop reply")
                } else {
                    Button("Send", systemImage: "arrow.up") {
                        submit()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(HoverCircleButtonStyle(inset: Design.iconGap))
                    .disabled(!canSubmit)
                    .help("Send")
                }
            }
            .padding(.horizontal, Design.rowGap)
            .padding(.vertical, Design.stripPadding)
            .card()
        }
        .padding(.horizontal, Design.paneInset)
        .padding(.top, Design.stripPadding)
        .padding(.bottom, Design.paneInset)
    }

    private var canSubmit: Bool {
        controller.canSend
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func activityLabel(for phase: NoteChatController.Phase) -> String? {
        switch phase {
        case .unloaded, .loading:
            "Opening this note's Chat…"
        case .responding:
            "Generating response…"
        case .retrying:
            "Connection interrupted. Retrying…"
        case .ready, .unavailable, .failed:
            nil
        }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, controller.canSend else { return }
        draft = ""
        nearBottom = true
        controller.send(text)
    }
}

private struct ChatActivityRow: View {
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: Design.innerGap) {
            Text("SIMBI")
                .font(.metaSemibold)
                .foregroundStyle(.tertiary)
            HStack(spacing: Design.iconGap) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

private struct MessageRow: View {
    let message: NoteChatMessage
    let onTimestamp: (String) -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: Design.chatUserLeadingInset)
                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, Design.rowGap)
                    .padding(.vertical, Design.stripPadding)
                    .background(
                        Color.cardFill,
                        in: RoundedRectangle(cornerRadius: Design.Radius.card))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: Design.innerGap) {
                Text("SIMBI")
                    .font(.metaSemibold)
                    .foregroundStyle(.tertiary)
                if message.text.isEmpty {
                    HStack(spacing: Design.iconGap) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…")
                            .font(.meta)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(NoteChatMarkdown.render(message.text))
                        .font(.body)
                        .lineSpacing(Design.innerGap)
                        .textSelection(.enabled)
                        .environment(
                            \.openURL,
                            OpenURLAction { url in
                                let prefix = "simbi-timestamp:"
                                guard url.absoluteString.hasPrefix(prefix) else {
                                    return .systemAction
                                }
                                onTimestamp(String(url.absoluteString.dropFirst(prefix.count)))
                                return .handled
                            })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

enum NoteChatMarkdown {
    static func render(_ source: String) -> AttributedString {
        let pattern = #"\[\[((?:\d+:)?\d{1,2}:\d{2})\]\]"#
        let linked = source.replacingOccurrences(
            of: pattern,
            with: "[$1](simbi-timestamp:$1)",
            options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linked, options: options))
            ?? AttributedString(source)
    }
}

private struct ChatBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
