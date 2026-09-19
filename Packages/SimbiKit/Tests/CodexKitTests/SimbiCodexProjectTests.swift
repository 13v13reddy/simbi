import Foundation
import Testing

@testable import CodexKit

@Suite("Simbi Codex project")
struct SimbiCodexProjectTests {
    @Test("task instructions keep the project root shared and scope relative paths to one note")
    func scopesTaskToNote() {
        let root = URL(filePath: "/Users/test/Simbi")
        let note = root.appending(path: "Work/Standup")
        let project = SimbiCodexProject(rootURL: root)

        let text = project.instructions(
            for: note, taskDirectoryURL: note,
            task: "Read note.md and write summary.md.")

        #expect(project.rootURL == root.standardizedFileURL)
        #expect(text.contains("active Simbi note is `Work/Standup`"))
        #expect(text.contains("task directory is `Work/Standup`"))
        #expect(text.contains("Change to that task directory before running commands"))
        #expect(text.hasSuffix("Read note.md and write summary.md."))
    }

    @Test("thread names identify Simbi, the note path, role, and optional detail")
    func namesThread() {
        let root = URL(filePath: "/Users/test/Simbi")
        let note = root.appending(path: "Work/Standup")
        let project = SimbiCodexProject(rootURL: root)

        #expect(project.threadName(for: note, role: "AI Notes") == "[Simbi · Work/Standup] AI Notes")
        #expect(
            project.threadName(for: note, role: "Convert", detail: "agenda.pdf")
                == "[Simbi · Work/Standup] Convert — agenda.pdf")
    }
}
