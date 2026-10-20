import Foundation

/// Jobs keep absolute paths into their note. Check at the filesystem mutation,
/// including ancestor folders, rather than relying on a menu's earlier state.
@MainActor
enum NoteFolderActivity {
    static var protectedFolders: [URL] {
        RecordingController.protectedNoteFolders
            + ImportController.protectedNoteFolders
            + SummaryController.protectedNoteFolders
    }

    static func blockingNote(for url: URL, among folders: [URL]? = nil) -> URL? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return (folders ?? protectedFolders).first {
            let notePath = $0.standardizedFileURL.resolvingSymlinksInPath().path
            return notePath == path || notePath.hasPrefix(path + "/")
        }
    }
}
