import Foundation
import SimbiKit
import Testing

@testable import CodexKit

@Suite("Note chat wire contract")
struct NoteChatWireTests {
    @Test("thread start is note-scoped, read-only, and project assigned")
    func threadStartShape() {
        let params = NoteChatWire.threadStartParams(
            cwd: URL(filePath: "/Users/u/Simbi"),
            developerInstructions: "Read this note only.",
            projectId: "project-simbi")

        #expect(params["cwd"] as? String == "/Users/u/Simbi")
        #expect(params["approvalPolicy"] as? String == "never")
        #expect(params["sandbox"] as? String == "read-only")
        #expect(params["developerInstructions"] as? String == "Read this note only.")
        #expect(params["projectId"] as? String == "project-simbi")
    }

    @Test("turn start carries a stable client id and a read-only sandbox")
    func turnStartShape() {
        let params = NoteChatWire.turnStartParams(
            threadId: "thread-1", text: "What changed?", clientMessageId: "client-1")

        #expect(params["threadId"] as? String == "thread-1")
        #expect(params["clientUserMessageId"] as? String == "client-1")
        #expect(params["approvalPolicy"] as? String == "never")
        let input = params["input"] as? [[String: any Sendable]]
        #expect(input?.first?["text"] as? String == "What changed?")
        let sandbox = params["sandboxPolicy"] as? [String: any Sendable]
        #expect(sandbox?["type"] as? String == "readOnly")
        #expect(sandbox?["networkAccess"] as? Bool == false)
    }

    @Test("resume hydrates only user and assistant messages")
    func hydrateHistory() throws {
        let data = Data(
            #"{"thread":{"id":"thread-1","turns":[{"id":"turn-1","status":"completed","items":[{"type":"userMessage","id":"user-1","clientId":"client-1","content":[{"type":"text","text":"Summarize this","text_elements":[]}]},{"type":"reasoning","id":"reason-1","summary":[],"content":[]},{"type":"agentMessage","id":"agent-1","text":"Here is the summary.","phase":null,"memoryCitation":null,"delivery":null,"questions":null}]},{"id":"turn-2","status":"inProgress","items":[]}]}}"#
                .utf8)

        let snapshot = try NoteChatWire.snapshot(from: data)
        #expect(snapshot.threadId == "thread-1")
        #expect(snapshot.activeTurnId == "turn-2")
        #expect(snapshot.messages.map(\.role) == [.user, .assistant])
        #expect(snapshot.messages.map(\.text) == ["Summarize this", "Here is the summary."])
        #expect(snapshot.clientMessageIds == ["client-1"])
    }

    @Test("stream notifications parse into note chat events")
    func eventParsing() throws {
        let delta = Data(
            #"{"threadId":"thread-1","turnId":"turn-1","itemId":"agent-1","delta":"Hello"}"#.utf8)
        #expect(
            NoteChatWire.event(method: "item/agentMessage/delta", params: delta)
                == .assistantDelta(
                    threadId: "thread-1", turnId: "turn-1", itemId: "agent-1",
                    delta: "Hello"))

        let completed = Data(
            #"{"threadId":"thread-1","turnId":"turn-1","item":{"type":"agentMessage","id":"agent-1","text":"Hello there","phase":null,"memoryCitation":null,"delivery":null,"questions":null},"completedAtMs":1}"#
                .utf8)
        #expect(
            NoteChatWire.event(method: "item/completed", params: completed)
                == .assistantCompleted(
                    threadId: "thread-1", turnId: "turn-1", itemId: "agent-1",
                    text: "Hello there"))

        let failed = Data(
            #"{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":{"type":"full"},"status":"failed","error":{"message":"Model unavailable","codexErrorInfo":null,"additionalDetails":null,"misalignment":null},"startedAt":null,"completedAt":null,"durationMs":null}}"#
                .utf8)
        #expect(
            NoteChatWire.event(method: "turn/completed", params: failed)
                == .turnCompleted(
                    threadId: "thread-1", turnId: "turn-1", status: .failed,
                    error: "Model unavailable"))

        let retrying = Data(
            #"{"threadId":"thread-1","turnId":"turn-1","willRetry":true,"error":{"message":"Disconnected","codexErrorInfo":null,"additionalDetails":null,"misalignment":null}}"#
                .utf8)
        #expect(
            NoteChatWire.event(method: "error", params: retrying)
                == .turnError(
                    threadId: "thread-1", turnId: "turn-1", message: "Disconnected",
                    willRetry: true))
    }

    @Test("thread id persists separately from recording state")
    func stateRoundTrip() throws {
        let note = FileManager.default.temporaryDirectory
            .appending(path: "note-chat-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: note) }

        try NoteChatStore.save(threadId: "thread-9", noteFolderURL: note)

        #expect(try NoteChatStore.load(noteFolderURL: note)?.threadId == "thread-9")
        #expect(
            NoteChatStore.stateURL(noteFolderURL: note).path
                == note.appending(path: ".simbi/chat.json").path)
        #expect(!FileManager.default.fileExists(atPath: note.appending(path: ".simbi/state.json").path))
    }

    @Test("folder deletion discovers every nested note chat")
    func nestedThreadIds() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "note-chat-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try NoteChatStore.save(
            threadId: "thread-b",
            noteFolderURL: folder.appending(path: "DSU/Friday"))
        try NoteChatStore.save(
            threadId: "thread-a",
            noteFolderURL: folder.appending(path: "Research"))

        #expect(NoteChatStore.threadIds(under: folder) == ["thread-a", "thread-b"])
    }

    @Test("only an archived-thread error permits unarchive recovery")
    func archivedErrorClassification() {
        let archived = AppServerClient.ClientError.serverError(
            code: -32000, message: "Thread is archived")
        let disconnected = AppServerClient.ClientError.serverError(
            code: -1, message: "disconnected")

        #expect(NoteChatWire.isArchivedThreadError(archived))
        #expect(!NoteChatWire.isArchivedThreadError(disconnected))
    }
}
