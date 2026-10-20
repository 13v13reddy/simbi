import AppKit
import Foundation
import Observation
import SimbiKit
@preconcurrency import UserNotifications

@MainActor
protocol RecordingNotificationCenter: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func add(_ request: UNNotificationRequest) async throws
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: RecordingNotificationCenter {}

public enum RecordingAlerts {
    /// Install the response delegate before launch finishes, including when a
    /// notification reopens an app that is no longer running. No permission UI.
    @MainActor public static func install() { RecordingNotifications.shared.install() }
}

/// A pending selection survives opening the main window from a notification.
@MainActor @Observable
public final class RecordingAlertNavigation {
    public static let shared = RecordingAlertNavigation()
    public var noteFolderURL: URL?

    public func reveal(_ url: URL) {
        noteFolderURL = url
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: .init(), completionHandler: nil)
    }
}

/// Permission is requested once at Record, without delaying capture. Inline and
/// menubar warnings remain authoritative if notifications are denied or muted.
@MainActor
final class RecordingNotifications: NSObject, RecordingNotifying, UNUserNotificationCenterDelegate {
    static let shared = RecordingNotifications()
    private var authorization: Task<Bool, Never>?
    private var installed = false
    private var current: [URL: String] = [:]
    private let suppliedCenter: (any RecordingNotificationCenter)?
    private let appIsActive: @MainActor () -> Bool
    private let activity: RecordingActivity

    init(
        center: (any RecordingNotificationCenter)? = nil,
        activity: RecordingActivity = .shared,
        appIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive }
    ) {
        suppliedCenter = center
        self.activity = activity
        self.appIsActive = appIsActive
        super.init()
    }

    private var center: any RecordingNotificationCenter {
        if let suppliedCenter { return suppliedCenter }
        return UNUserNotificationCenter.current()
    }

    func install() {
        guard !Flags.uiPreview, !installed else { return }
        installed = true
        center.delegate = self
        let retry = UNNotificationAction(
            identifier: "retry", title: "Retry Recording", options: [.foreground])
        let retryAudio = UNNotificationAction(
            identifier: "retry-audio", title: "Retry Audio", options: [.foreground])
        let retryTranscript = UNNotificationAction(
            identifier: "retry-transcript", title: "Retry Saving Transcript", options: [.foreground])
        let retryTranscription = UNNotificationAction(
            identifier: "retry-transcription", title: "Retry Transcription", options: [.foreground])
        let settings = UNNotificationAction(
            identifier: "settings", title: "Open System Settings", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "recording-failed", actions: [retry], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: "recording-failed-source", actions: [retry, settings], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: "source-unavailable", actions: [retryAudio, settings], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: "transcript-save-failed", actions: [retryTranscript], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: "transcription-failed", actions: [retryTranscription], intentIdentifiers: []),
        ])
    }

    func prepare() {
        guard !Flags.uiPreview else { return }
        install()
        authorization = Task {
            do {
                let allowed = try await center.requestAuthorization(options: [.alert, .sound])
                activity.notificationsUnavailable = !allowed
                if !allowed { Log.ui.warning("recording notifications denied; errors remain visible in Simbi") }
                return allowed
            } catch {
                activity.notificationsUnavailable = true
                Log.ui.warning("enabling recording notifications failed: \(error)")
                return false
            }
        }
    }

    func post(problem: RecordingProblem, noteFolderURL: URL) {
        guard !Flags.uiPreview else { return }
        if problem.isRecovered {
            clear(noteFolderURL: noteFolderURL)
            return
        }
        let key = problem.notificationKey
        guard current[noteFolderURL] != key else { return }
        current[noteFolderURL] = key
        if authorization == nil { prepare() }
        Task { [weak self] in
            guard let self, await authorization?.value == true,
                current[noteFolderURL] == key, !appIsActive()
            else { return }
            let content = UNMutableNotificationContent()
            content.title =
                problem == .transcriptSaveFailed
                ? "Simbi transcript not saved"
                : problem == .transcriptionFailed
                    ? "Simbi transcription failed"
                    : problem.isFatal ? "Simbi recording stopped" : "Simbi audio source unavailable"
            let message: String
            if case .sourceUnavailable(let source, _) = problem {
                message = "\(source.name) audio is unavailable. Open Simbi to check the other source or retry audio."
            } else {
                message = problem.message
            }
            content.body = "\(noteFolderURL.lastPathComponent): \(message)"
            content.sound = .default
            content.categoryIdentifier =
                problem == .transcriptSaveFailed
                ? "transcript-save-failed"
                : problem == .transcriptionFailed
                    ? "transcription-failed"
                    : problem.isFatal
                        ? (problem.settingsURL == nil ? "recording-failed" : "recording-failed-source")
                        : "source-unavailable"
            content.userInfo = [
                "notePath": noteFolderURL.path,
                "settings": problem.settingsURL?.absoluteString ?? "",
            ]
            do {
                try await center.add(
                    UNNotificationRequest(identifier: noteFolderURL.path, content: content, trigger: nil))
            } catch { Log.ui.error("posting recording notification failed: \(error)") }
        }
    }

    func clear(noteFolderURL: URL) {
        current[noteFolderURL] = nil
        guard installed || suppliedCenter != nil else { return }
        center.removeDeliveredNotifications(withIdentifiers: [noteFolderURL.path])
        center.removePendingNotificationRequests(withIdentifiers: [noteFolderURL.path])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let path = response.notification.request.content.userInfo["notePath"] as? String
        let settings = response.notification.request.content.userInfo["settings"] as? String
        let action = response.actionIdentifier
        guard let path else { return }
        await MainActor.run {
            let folder = URL(fileURLWithPath: path).standardizedFileURL
            // Notifications only route into the current Simbi home.
            let root = SimbiHome().rootURL.path
            guard folder.path.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: folder.path) else { return }
            RecordingAlertNavigation.shared.reveal(folder)
            let controller = RecordingController.shared(noteFolderURL: folder)
            switch action {
            case "retry", "retry-audio": controller.retryRecording()
            case "retry-transcript": controller.retryTranscriptSaving()
            case "retry-transcription": controller.retryTranscription()
            case "settings":
                if let settings, let url = URL(string: settings), url.scheme == "x-apple.systempreferences" {
                    NSWorkspace.shared.open(url)
                }
            default: break
            }
        }
    }
}
