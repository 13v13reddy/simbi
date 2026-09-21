import CodexKit
import Testing

@testable import SimbiUI

@Suite("Note chat controller")
struct NoteChatControllerTests {
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
