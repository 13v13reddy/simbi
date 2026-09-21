import Foundation
import SimbiKit

/// Builds the developer instructions for an embedded Note Chat. File names
/// are inventoried without copying their contents into the prompt; Codex reads
/// relevant note files itself inside the enforced read-only sandbox.
public enum NoteChatInstructions {
    /// App-owned rules sit outside the user-editable CHAT.md template so
    /// every existing install gains live attachment refresh and read-only
    /// behavior without overwriting the user's file.
    private static let appContract = """
        Before every answer, re-list `context/` rather than relying only on the \
        launch-time inventory. Read every newly added or changed markdown file \
        there before responding. This chat is read-only: never create, edit, \
        move, rename, or delete any file. Explain suggested changes in the reply \
        instead.
        """

    public static func developerInstructions(
        noteFolderURL: URL, homeRootURL: URL
    ) -> String {
        let notePath = CodexChat.notePath(
            noteFolderURL: noteFolderURL, homeRootURL: homeRootURL)
        let files = inventory(noteFolderURL: noteFolderURL)
        let contents =
            files.isEmpty
            ? "The note has no files yet."
            : "The note currently contains: "
                + files.map { "`\($0)`" }.joined(separator: ", ") + "."
        let chatInstructions = AgentInstructions.chat.resolve(
            homeRootURL: homeRootURL,
            variables: ["note_path": notePath, "files": contents])
        let project = SimbiCodexProject(rootURL: homeRootURL)
        return project.instructions(
            for: noteFolderURL, taskDirectoryURL: noteFolderURL,
            task: chatInstructions + "\n\n" + appContract)
    }

    /// Top-level note files plus one level of `context/` and `files/`,
    /// sorted for stable output. Hidden state never reaches the prompt.
    private static func inventory(noteFolderURL: URL) -> [String] {
        let fm = FileManager.default
        func names(in dir: URL, prefix: String = "") -> [String] {
            ((try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles)) ?? [])
                .filter {
                    !((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                }
                .map { prefix + $0.lastPathComponent }
        }
        let top = names(in: noteFolderURL)
        let context = names(
            in: NoteLayout.contextDirURL(noteFolder: noteFolderURL),
            prefix: "\(NoteLayout.contextDirName)/")
        let attachments = names(
            in: NoteLayout.filesDirURL(noteFolder: noteFolderURL),
            prefix: "\(NoteLayout.filesDirName)/")
        return (top + context + attachments).sorted()
    }
}
