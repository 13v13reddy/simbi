import CodexKit
import Testing

@testable import SimbiUI

@Suite("Note chat controller")
struct NoteChatControllerTests {
    @Test("chat phases expose clear activity labels")
    @MainActor func activityLabels() {
        #expect(NoteChatView.activityLabel(for: .loading) == "Opening this note's Chat…")
        #expect(NoteChatView.activityLabel(for: .responding) == "Generating response…")
        #expect(NoteChatView.activityLabel(for: .retrying) == "Connection interrupted. Retrying…")
        #expect(NoteChatView.activityLabel(for: .ready) == nil)
    }

    @Test("stream events must match both the visible thread and active turn")
    func eventScope() {
        let event = NoteChatEvent.assistantDelta(
            threadId: "thread-1", turnId: "turn-2",
            itemId: "item-1", delta: "Hello")

        #expect(
            NoteChatController.eventMatchesActiveTurn(
                event, threadId: "thread-1", activeTurnId: "turn-2"))
        #expect(
            !NoteChatController.eventMatchesActiveTurn(
                event, threadId: "thread-1", activeTurnId: "turn-old"))
        #expect(
            !NoteChatController.eventMatchesActiveTurn(
                event, threadId: "thread-other", activeTurnId: "turn-2"))
    }
}
