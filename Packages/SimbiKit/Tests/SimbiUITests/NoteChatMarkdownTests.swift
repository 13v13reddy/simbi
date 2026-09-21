import Testing

@testable import SimbiUI

@Suite("Note chat Markdown")
struct NoteChatMarkdownTests {
    @Test("dialogue answers preserve list spacing and timestamp labels")
    func preservesWhitespace() {
        let rendered = NoteChatMarkdown.render(
            "Decisions:\n\n- Keep Chat scoped.\n- Keep files local. [[1:02]]")
        let text = String(rendered.characters)

        #expect(text.contains("Decisions:\n\n- Keep Chat scoped."))
        #expect(text.contains("\n- Keep files local. 1:02"))
    }
}
