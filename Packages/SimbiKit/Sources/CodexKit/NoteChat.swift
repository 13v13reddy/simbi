import Foundation
import SimbiKit

public enum NoteChatRole: String, Sendable, Equatable {
    case user
    case assistant
}

public struct NoteChatMessage: Identifiable, Sendable, Equatable {
    public let id: String
    public let role: NoteChatRole
    public var text: String
    public let clientMessageId: String?

    public init(
        id: String, role: NoteChatRole, text: String, clientMessageId: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.clientMessageId = clientMessageId
    }
}

public struct NoteChatSnapshot: Sendable, Equatable {
    public let threadId: String
    public let messages: [NoteChatMessage]
    public let activeTurnId: String?
    public let clientMessageIds: Set<String>
}

public enum NoteChatTurnStatus: String, Sendable, Equatable {
    case completed
    case interrupted
    case failed
    case inProgress
}

public enum NoteChatEvent: Sendable, Equatable {
    case assistantStarted(threadId: String, turnId: String, itemId: String)
    case assistantDelta(
        threadId: String, turnId: String, itemId: String, delta: String)
    case assistantCompleted(
        threadId: String, turnId: String, itemId: String, text: String)
    case turnCompleted(
        threadId: String, turnId: String, status: NoteChatTurnStatus, error: String?)
    case turnError(
        threadId: String, turnId: String, message: String, willRetry: Bool)

    public var threadId: String {
        switch self {
        case .assistantStarted(let threadId, _, _),
            .assistantDelta(let threadId, _, _, _),
            .assistantCompleted(let threadId, _, _, _),
            .turnCompleted(let threadId, _, _, _),
            .turnError(let threadId, _, _, _):
            threadId
        }
    }

    public var turnId: String {
        switch self {
        case .assistantStarted(_, let turnId, _),
            .assistantDelta(_, let turnId, _, _),
            .assistantCompleted(_, let turnId, _, _),
            .turnCompleted(_, let turnId, _, _),
            .turnError(_, let turnId, _, _):
            turnId
        }
    }
}

/// Stable, hand-written adapter over the app-server's chat-related JSON.
/// Keeping the schema parsing here prevents the SwiftUI state machine from
/// learning wire keys and makes Codex version drift independently testable.
public enum NoteChatWire {
    static func threadStartParams(
        cwd: URL, developerInstructions: String, projectId: String?
    ) -> [String: any Sendable] {
        var params: [String: any Sendable] = [
            "cwd": cwd.standardizedFileURL.path,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "developerInstructions": developerInstructions,
        ]
        if let projectId { params["projectId"] = projectId }
        return params
    }

    static func resumeParams(
        threadId: String, cwd: URL, developerInstructions: String
    ) -> [String: any Sendable] {
        [
            "threadId": threadId,
            "cwd": cwd.standardizedFileURL.path,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "developerInstructions": developerInstructions,
        ]
    }

    static func turnStartParams(
        threadId: String, text: String, clientMessageId: String
    ) -> [String: any Sendable] {
        let sandbox: [String: any Sendable] = [
            "type": "readOnly",
            "networkAccess": false,
        ]
        return [
            "threadId": threadId,
            "clientUserMessageId": clientMessageId,
            "input": CodexTurn.textInput(text),
            "approvalPolicy": "never",
            "sandboxPolicy": sandbox,
        ]
    }

    public static func startThread(
        client: AppServerClient, noteFolderURL: URL,
        homeRootURL: URL = SimbiHome().rootURL
    ) async throws -> NoteChatSnapshot {
        let instructions = NoteChatInstructions.developerInstructions(
            noteFolderURL: noteFolderURL, homeRootURL: homeRootURL)
        let projectId: String?
        do {
            projectId = try await SimbiCodexProjectOrganizer.ensureProject(
                client: client, rootURL: homeRootURL)
        } catch {
            Log.codex.warning("organizing note chat project failed; continuing unassigned: \(error)")
            projectId = nil
        }
        let data: Data
        do {
            data = try await client.request(
                method: "thread/start",
                params: threadStartParams(
                    cwd: homeRootURL, developerInstructions: instructions,
                    projectId: projectId))
        } catch  where projectId != nil {
            // Some Codex releases expose project/list but reject projectId
            // on thread/start. Chat itself must not depend on that cosmetic
            // experimental assignment.
            Log.codex.warning("starting project-assigned note chat failed; retrying unassigned")
            data = try await client.request(
                method: "thread/start",
                params: threadStartParams(
                    cwd: homeRootURL, developerInstructions: instructions,
                    projectId: nil))
        }
        let snapshot = try snapshot(from: data)
        let project = SimbiCodexProject(rootURL: homeRootURL)
        _ = try await client.request(
            method: "thread/name/set",
            params: [
                "threadId": snapshot.threadId,
                "name": project.threadName(for: noteFolderURL, role: "Chat"),
            ])
        return snapshot
    }

    public static func resumeThread(
        client: AppServerClient, threadId: String, noteFolderURL: URL,
        homeRootURL: URL = SimbiHome().rootURL
    ) async throws -> NoteChatSnapshot {
        let instructions = NoteChatInstructions.developerInstructions(
            noteFolderURL: noteFolderURL, homeRootURL: homeRootURL)
        let data = try await client.request(
            method: "thread/resume",
            params: resumeParams(
                threadId: threadId, cwd: homeRootURL,
                developerInstructions: instructions))
        return try snapshot(from: data)
    }

    public static func startTurn(
        client: AppServerClient, threadId: String, text: String,
        clientMessageId: String
    ) async throws -> String {
        let data = try await client.request(
            method: "turn/start",
            params: turnStartParams(
                threadId: threadId, text: text,
                clientMessageId: clientMessageId))
        let object = jsonObject(data)
        guard let turn = object?["turn"] as? [String: Any],
            let id = turn["id"] as? String
        else { throw CodexWorkerError.malformedResponse }
        return id
    }

    public static func interrupt(
        client: AppServerClient, threadId: String, turnId: String
    ) async throws {
        _ = try await client.request(
            method: "turn/interrupt",
            params: ["threadId": threadId, "turnId": turnId])
    }

    public static func unsubscribe(
        client: AppServerClient, threadId: String
    ) async throws {
        _ = try await client.request(
            method: "thread/unsubscribe", params: ["threadId": threadId])
    }

    public static func archive(
        client: AppServerClient, threadId: String
    ) async throws {
        _ = try await client.request(
            method: "thread/archive", params: ["threadId": threadId])
    }

    public static func unarchive(
        client: AppServerClient, threadId: String
    ) async throws {
        _ = try await client.request(
            method: "thread/unarchive", params: ["threadId": threadId])
    }

    static func snapshot(from data: Data) throws -> NoteChatSnapshot {
        guard let thread = jsonObject(data)?["thread"] as? [String: Any],
            let threadId = thread["id"] as? String
        else { throw CodexWorkerError.malformedResponse }

        var messages: [NoteChatMessage] = []
        var clientMessageIds: Set<String> = []
        var activeTurnId: String?
        for turn in thread["turns"] as? [[String: Any]] ?? [] {
            if turn["status"] as? String == NoteChatTurnStatus.inProgress.rawValue {
                activeTurnId = turn["id"] as? String
            }
            for item in turn["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String,
                    let type = item["type"] as? String
                else { continue }
                switch type {
                case "userMessage":
                    let text = (item["content"] as? [[String: Any]] ?? [])
                        .compactMap { content -> String? in
                            guard content["type"] as? String == "text" else { return nil }
                            return content["text"] as? String
                        }
                        .joined(separator: "\n")
                    guard !text.isEmpty else { continue }
                    let clientId = item["clientId"] as? String
                    if let clientId { clientMessageIds.insert(clientId) }
                    messages.append(
                        NoteChatMessage(
                            id: id, role: .user, text: text,
                            clientMessageId: clientId))
                case "agentMessage":
                    guard let text = item["text"] as? String, !text.isEmpty else { continue }
                    messages.append(
                        NoteChatMessage(id: id, role: .assistant, text: text))
                default:
                    continue
                }
            }
        }
        return NoteChatSnapshot(
            threadId: threadId, messages: messages,
            activeTurnId: activeTurnId,
            clientMessageIds: clientMessageIds)
    }

    public static func event(method: String, params: Data) -> NoteChatEvent? {
        guard let object = jsonObject(params),
            let threadId = object["threadId"] as? String,
            let turnId = object["turnId"] as? String
                ?? (object["turn"] as? [String: Any])?["id"] as? String
        else { return nil }

        switch method {
        case "item/started":
            guard let item = object["item"] as? [String: Any],
                item["type"] as? String == "agentMessage",
                let itemId = item["id"] as? String
            else { return nil }
            return .assistantStarted(
                threadId: threadId, turnId: turnId, itemId: itemId)
        case "item/agentMessage/delta":
            guard let itemId = object["itemId"] as? String,
                let delta = object["delta"] as? String
            else { return nil }
            return .assistantDelta(
                threadId: threadId, turnId: turnId, itemId: itemId,
                delta: delta)
        case "item/completed":
            guard let item = object["item"] as? [String: Any],
                item["type"] as? String == "agentMessage",
                let itemId = item["id"] as? String,
                let text = item["text"] as? String
            else { return nil }
            return .assistantCompleted(
                threadId: threadId, turnId: turnId, itemId: itemId,
                text: text)
        case "turn/completed":
            guard let turn = object["turn"] as? [String: Any],
                let rawStatus = turn["status"] as? String,
                let status = NoteChatTurnStatus(rawValue: rawStatus)
            else { return nil }
            let error = (turn["error"] as? [String: Any])?["message"] as? String
            return .turnCompleted(
                threadId: threadId, turnId: turnId,
                status: status, error: error)
        case "error":
            guard let error = object["error"] as? [String: Any],
                let message = error["message"] as? String,
                let willRetry = object["willRetry"] as? Bool
            else { return nil }
            return .turnError(
                threadId: threadId, turnId: turnId,
                message: message, willRetry: willRetry)
        default:
            return nil
        }
    }

    public static func isMissingThreadError(_ error: Error) -> Bool {
        guard case AppServerClient.ClientError.serverError(_, let message) = error else {
            return false
        }
        let lowered = message.lowercased()
        return lowered.contains("not found")
            || lowered.contains("does not exist")
            || lowered.contains("unknown thread")
            || lowered.contains("invalid thread")
    }

    public static func isArchivedThreadError(_ error: Error) -> Bool {
        guard case AppServerClient.ClientError.serverError(_, let message) = error else {
            return false
        }
        return message.lowercased().contains("archiv")
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

public enum NoteChatStore {
    public struct State: Codable, Sendable, Equatable {
        public let threadId: String
    }

    public static func stateURL(noteFolderURL: URL) -> URL {
        NoteLayout.chatStateURL(noteFolder: noteFolderURL)
    }

    public static func load(noteFolderURL: URL) throws -> State? {
        let url = stateURL(noteFolderURL: noteFolderURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
    }

    public static func save(threadId: String, noteFolderURL: URL) throws {
        let url = stateURL(noteFolderURL: noteFolderURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PersistedJSON.encoder().encode(State(threadId: threadId))
            .write(to: url, options: .atomic)
    }

    /// Thread identities below a note or organizational folder, captured
    /// before that filesystem item is moved to Trash. Archiving is then
    /// best-effort and never delays deletion.
    public static func threadIds(under url: URL) -> [String] {
        var stateURLs: [URL] = []
        let direct = stateURL(noteFolderURL: url)
        if FileManager.default.fileExists(atPath: direct.path) {
            stateURLs.append(direct)
        }
        if let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants])
        {
            for case let candidate as URL in enumerator
            where candidate.lastPathComponent == NoteLayout.chatStateFileName
                && candidate.deletingLastPathComponent().lastPathComponent
                    == NoteLayout.stateDirName
            {
                stateURLs.append(candidate)
            }
        }
        return Array(
            Set(
                stateURLs.compactMap { stateURL in
                    (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)))?.threadId
                })
        ).sorted()
    }
}
