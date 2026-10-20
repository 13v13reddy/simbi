import AppKit
import Observation

/// Quit waits for local durability, not network uploads. A stuck finalizer
/// cancels Quit and leaves the app open instead of silently losing its tail.
@MainActor
@Observable
final class ApplicationQuitCoordinator {
    static let shared = ApplicationQuitCoordinator(
        prepare: {
            let editorsSaved = AutosavingDocument.saveAllBeforeQuit()
            let recordingsSaved = await RecordingController.finishAllForQuit()
            return AutosavingDocument.saveAllBeforeQuit() && editorsSaved && recordingsSaved
        },
        didFail: {
            let alert = NSAlert()
            alert.messageText = "Simbi Could Not Finish Saving"
            alert.informativeText =
                "Quit was canceled to keep your work safe. Wait for recording to finish saving, and check open notes for save conflicts or folder access problems. Then try Quit again."
            alert.addButton(withTitle: "OK")
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        })

    private(set) var isQuitting = false
    private let prepare: @MainActor () async -> Bool
    private let didFail: @MainActor () -> Void
    private let timeout: TimeInterval

    init(
        timeout: TimeInterval = 15,
        prepare: @escaping @MainActor () async -> Bool,
        didFail: @escaping @MainActor () -> Void
    ) {
        self.timeout = timeout
        self.prepare = prepare
        self.didFail = didFail
    }

    func requestTermination(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        let attempt = Attempt()
        Task { attempt.result = await prepare() }
        Task {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while attempt.result == nil, ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let saved = attempt.result == true
            if !saved { isQuitting = false }
            reply(saved)
            if !saved { didFail() }
        }
        return .terminateLater
    }

    @MainActor
    private final class Attempt {
        var result: Bool?
    }
}

@MainActor
public final class SimbiApplicationDelegate: NSObject, NSApplicationDelegate {
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationQuitCoordinator.shared.requestTermination {
            sender.reply(toApplicationShouldTerminate: $0)
        }
    }
}
