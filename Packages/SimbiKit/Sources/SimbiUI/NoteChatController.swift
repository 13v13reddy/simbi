import CodexKit
import Foundation
import Observation
import SimbiKit

@MainActor
@Observable
final class NoteChatController {
    enum Phase: Equatable {
        case unloaded
        case loading
        case ready
        case responding
        case retrying
        case unavailable(String)
        case failed(String)
    }

    private static let controllers = PerNoteRegistry<NoteChatController>()

    static func shared(noteFolderURL: URL) -> NoteChatController {
        controllers.value(for: noteFolderURL) {
            NoteChatController(noteFolderURL: $0)
        }
    }

    private(set) var messages: [NoteChatMessage] = []
    private(set) var phase: Phase = .unloaded
    private(set) var historyNotice: String?

    var isBusy: Bool {
        phase == .responding || phase == .retrying
    }

    var canSend: Bool { phase == .ready }
    var canStop: Bool { isBusy && activeTurnId != nil }

    var lastError: String? {
        switch phase {
        case .failed(let message), .unavailable(let message): message
        default: nil
        }
    }

    private let noteFolderURL: URL
    private let homeRootURL: URL
    private let client: AppServerClient
    private var threadId: String?
    private var activeTurnId: String?
    private var pendingClientMessageId: String?
    private var lastSubmittedPrompt: String?
    private var bufferedEvents: [NoteChatEvent] = []
    private var loadTask: Task<Void, Never>?

    private init(
        noteFolderURL: URL, homeRootURL: URL = SimbiHome().rootURL,
        client: AppServerClient = CodexServices.appServer
    ) {
        self.noteFolderURL = noteFolderURL
        self.homeRootURL = homeRootURL
        self.client = client
        if Flags.uiPreview {
            phase = .ready
            messages = [
                NoteChatMessage(
                    id: "preview-user-1", role: .user,
                    text: "What were the main decisions from this stand-up?"),
                NoteChatMessage(
                    id: "preview-assistant-1", role: .assistant,
                    text: """
                        Three decisions were made:

                        - Keep one persistent Chat per note.
                        - Scope every attachment to this workspace.
                        - Ship Chat as read-only before adding write actions. [[0:03]]
                        """),
                NoteChatMessage(
                    id: "preview-user-2", role: .user,
                    text: "What should I follow up on today?"),
                NoteChatMessage(
                    id: "preview-assistant-2", role: .assistant,
                    text: "Review the attachment popover and confirm the Dialogue layout in the native app."),
            ]
            return
        }
        Task { [weak self, client] in
            await client.addNotificationHandler { [weak self] method, params in
                guard let event = NoteChatWire.event(method: method, params: params) else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.receive(event)
                }
            }
        }
    }

    func activate() {
        guard
            phase == .unloaded
                || {
                    if case .unavailable = phase { return true }
                    return false
                }()
        else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.load()
        }
    }

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend, let threadId else { return }

        let clientId = UUID().uuidString
        pendingClientMessageId = clientId
        lastSubmittedPrompt = text
        activeTurnId = nil
        bufferedEvents.removeAll()
        messages.append(
            NoteChatMessage(
                id: "local-user-\(clientId)", role: .user,
                text: text, clientMessageId: clientId))
        phase = .responding

        Task { [weak self, client] in
            do {
                guard let self else { return }
                let snapshot = try await self.resumeWithUnarchive(threadId: threadId)
                guard self.pendingClientMessageId == clientId else { return }
                if snapshot.clientMessageIds.contains(clientId) {
                    self.apply(snapshot)
                    return
                }
                guard snapshot.activeTurnId == nil else {
                    self.apply(snapshot)
                    return
                }

                // A request always resumes first. If the app-server silently
                // restarted while Chat was idle, this re-subscribes the note
                // before the new turn can emit notifications.
                self.apply(snapshot)
                self.pendingClientMessageId = clientId
                self.lastSubmittedPrompt = text
                self.messages.append(
                    NoteChatMessage(
                        id: "local-user-\(clientId)", role: .user,
                        text: text, clientMessageId: clientId))
                self.phase = .responding
                let turnId = try await NoteChatWire.startTurn(
                    client: client, threadId: threadId,
                    text: text, clientMessageId: clientId)
                await MainActor.run { [weak self] in
                    guard let self,
                        self.pendingClientMessageId == clientId,
                        self.isBusy
                    else { return }
                    self.activeTurnId = turnId
                    self.drainBufferedEvents(for: turnId)
                }
            } catch {
                await self?.recoverAmbiguousStart(
                    text: text, clientId: clientId, originalError: error)
            }
        }
    }

    func stop() {
        guard let threadId, let activeTurnId, isBusy else { return }
        Task { [weak self, client] in
            do {
                try await NoteChatWire.interrupt(
                    client: client, threadId: threadId,
                    turnId: activeTurnId)
            } catch {
                await MainActor.run { [weak self] in
                    self?.phase = .failed("The reply could not be stopped. \(error.localizedDescription)")
                }
            }
        }
    }

    func retry() {
        guard case .failed = phase, let prompt = lastSubmittedPrompt else { return }
        phase = .ready
        send(prompt)
    }

    func reconnect() {
        phase = .unloaded
        activate()
    }

    private func load() async {
        phase = .loading
        historyNotice = nil
        do {
            let saved: NoteChatStore.State?
            do {
                saved = try NoteChatStore.load(noteFolderURL: noteFolderURL)
            } catch {
                historyNotice = "The previous chat record was damaged, so Simbi started a new chat."
                let snapshot = try await createAndPersistThread()
                apply(snapshot)
                return
            }

            if let saved {
                do {
                    let snapshot = try await resumeWithUnarchive(threadId: saved.threadId)
                    apply(snapshot)
                } catch  where NoteChatWire.isMissingThreadError(error) {
                    historyNotice = "The previous Codex chat could not be found, so Simbi started a new chat."
                    let snapshot = try await createAndPersistThread()
                    apply(snapshot)
                }
            } else {
                let snapshot = try await createAndPersistThread()
                apply(snapshot)
            }
        } catch {
            phase = .unavailable(connectionMessage(for: error))
        }
    }

    private func resumeWithUnarchive(threadId: String) async throws -> NoteChatSnapshot {
        do {
            return try await NoteChatWire.resumeThread(
                client: client, threadId: threadId,
                noteFolderURL: noteFolderURL, homeRootURL: homeRootURL)
        } catch {
            guard NoteChatWire.isArchivedThreadError(error) else { throw error }
            try await NoteChatWire.unarchive(client: client, threadId: threadId)
            return try await NoteChatWire.resumeThread(
                client: client, threadId: threadId,
                noteFolderURL: noteFolderURL, homeRootURL: homeRootURL)
        }
    }

    private func createAndPersistThread() async throws -> NoteChatSnapshot {
        let snapshot = try await NoteChatWire.startThread(
            client: client, noteFolderURL: noteFolderURL,
            homeRootURL: homeRootURL)
        try NoteChatStore.save(
            threadId: snapshot.threadId, noteFolderURL: noteFolderURL)
        return snapshot
    }

    private func apply(_ snapshot: NoteChatSnapshot) {
        threadId = snapshot.threadId
        messages = snapshot.messages
        activeTurnId = snapshot.activeTurnId
        pendingClientMessageId = nil
        lastSubmittedPrompt =
            snapshot.activeTurnId == nil
            ? nil
            : snapshot.messages.last(where: { $0.role == .user })?.text
        phase = snapshot.activeTurnId == nil ? .ready : .responding
        if let activeTurnId { drainBufferedEvents(for: activeTurnId) }
    }

    private func recoverAmbiguousStart(
        text: String, clientId: String, originalError: Error
    ) async {
        guard pendingClientMessageId == clientId, let threadId else { return }
        phase = .retrying
        do {
            let snapshot = try await resumeWithUnarchive(threadId: threadId)
            if snapshot.clientMessageIds.contains(clientId) {
                apply(snapshot)
                return
            }

            // The server's resumed history proves the first request was not
            // accepted. Restore the optimistic bubble after hydration and
            // make one safe retry with the same client message ID.
            apply(snapshot)
            pendingClientMessageId = clientId
            lastSubmittedPrompt = text
            messages.append(
                NoteChatMessage(
                    id: "local-user-\(clientId)", role: .user,
                    text: text, clientMessageId: clientId))
            phase = .retrying
            let turnId = try await NoteChatWire.startTurn(
                client: client, threadId: threadId,
                text: text, clientMessageId: clientId)
            if pendingClientMessageId == clientId, isBusy {
                activeTurnId = turnId
                phase = .responding
            }
        } catch {
            pendingClientMessageId = nil
            activeTurnId = nil
            let detail = connectionMessage(for: error)
            phase = .failed(
                detail.isEmpty ? originalError.localizedDescription : detail)
        }
    }

    private func receive(_ event: NoteChatEvent) {
        guard event.threadId == threadId else { return }
        guard let activeTurnId else {
            if isBusy { bufferedEvents.append(event) }
            return
        }
        guard
            Self.eventMatchesActiveTurn(
                event, threadId: threadId, activeTurnId: activeTurnId)
        else { return }
        applyEvent(event)
    }

    nonisolated static func eventMatchesActiveTurn(
        _ event: NoteChatEvent, threadId: String?, activeTurnId: String?
    ) -> Bool {
        event.threadId == threadId && event.turnId == activeTurnId
    }

    private func drainBufferedEvents(for turnId: String) {
        let matching = bufferedEvents.filter {
            Self.eventMatchesActiveTurn($0, threadId: threadId, activeTurnId: turnId)
        }
        bufferedEvents.removeAll()
        for event in matching { applyEvent(event) }
    }

    private func applyEvent(_ event: NoteChatEvent) {
        switch event {
        case .assistantStarted(_, _, let itemId):
            ensureAssistantMessage(id: itemId)
        case .assistantDelta(_, _, let itemId, let delta):
            ensureAssistantMessage(id: itemId)
            if let index = messages.firstIndex(where: { $0.id == itemId }) {
                messages[index].text += delta
            }
        case .assistantCompleted(_, _, let itemId, let text):
            ensureAssistantMessage(id: itemId)
            if let index = messages.firstIndex(where: { $0.id == itemId }) {
                messages[index].text = text
            }
        case .turnCompleted(_, _, let status, let error):
            activeTurnId = nil
            pendingClientMessageId = nil
            switch status {
            case .completed:
                lastSubmittedPrompt = nil
                phase = .ready
            case .interrupted:
                phase = .ready
            case .failed:
                phase = .failed(error ?? "Simbi could not finish that reply.")
            case .inProgress:
                phase = .responding
            }
        case .turnError(_, _, let message, let willRetry):
            phase = willRetry ? .retrying : .failed(message)
        }
    }

    private func ensureAssistantMessage(id: String) {
        guard !messages.contains(where: { $0.id == id }) else { return }
        messages.append(
            NoteChatMessage(id: id, role: .assistant, text: ""))
    }

    private func connectionMessage(for error: Error) -> String {
        switch error {
        case AppServerClient.ClientError.binaryMissing:
            "Chat needs the ChatGPT app. Install it, then try again."
        case AppServerClient.ClientError.notAuthenticated:
            "Sign in to ChatGPT, then try again."
        default:
            "Codex is unavailable. Check the sidebar connection and try again."
        }
    }
}
