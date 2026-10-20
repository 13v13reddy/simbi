import Foundation
import Testing
@preconcurrency import UserNotifications

@testable import SimbiUI

@Suite("Recording notifications", .serialized)
@MainActor
struct RecordingNotificationTests {
    private let activity = RecordingActivity()
    private let folder = URL(fileURLWithPath: "/tmp/simbi-notification-note")

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test("launch registers notification actions and can clear old alerts without requesting permission")
    func launchRegistrationAndClear() {
        let center = TestNotificationCenter()
        let notices = RecordingNotifications(center: center, activity: activity)
        notices.install()
        #expect(center.delegate === notices)
        #expect(center.categories.contains { $0.identifier == "source-unavailable" })
        notices.clear(noteFolderURL: folder)
        #expect(center.removedDelivered.contains(folder.path))
        #expect(!center.authorizationRequested)
    }

    @Test("transcript save alerts offer a saving retry instead of starting another recording")
    func transcriptSaveFailure() async throws {
        let center = TestNotificationCenter()
        let notices = RecordingNotifications(center: center, activity: activity, appIsActive: { false })
        notices.post(problem: .transcriptSaveFailed, noteFolderURL: folder)
        try await waitUntil { center.requests.count == 1 }
        let request = try #require(center.requests.first)
        #expect(request.content.title == "Simbi transcript not saved")
        let category = try #require(center.categories.first { $0.identifier == request.content.categoryIdentifier })
        #expect(category.actions.map(\.identifier) == ["retry-transcript"])
    }

    @Test("background errors produce an actionable desktop notification")
    func backgroundFailure() async throws {
        let center = TestNotificationCenter()
        let notices = RecordingNotifications(center: center, activity: activity, appIsActive: { false })
        notices.post(problem: .noAudio, noteFolderURL: folder)
        try await waitUntil { center.requests.count == 1 }
        let request = try #require(center.requests.first)
        #expect(request.content.title == "Simbi recording stopped")
        #expect(request.content.userInfo["notePath"] as? String == folder.path)
        let category = try #require(center.categories.first { $0.identifier == request.content.categoryIdentifier })
        #expect(category.actions.map(\.identifier).contains("retry"))
        #expect(category.actions.map(\.identifier).contains("settings"))
    }

    @Test("network transcription failures have their own alert and retry action")
    func transcriptionFailure() async throws {
        let center = TestNotificationCenter()
        let notices = RecordingNotifications(center: center, activity: activity, appIsActive: { false })
        notices.post(problem: .transcriptionFailed, noteFolderURL: folder)
        try await waitUntil { center.requests.count == 1 }
        let request = try #require(center.requests.first)
        #expect(request.content.title == "Simbi transcription failed")
        #expect(request.content.body.contains("audio is saved"))
        let category = try #require(center.categories.first { $0.identifier == request.content.categoryIdentifier })
        #expect(category.actions.map(\.identifier) == ["retry-transcription"])
    }

    @Test("source recovery updates do not repeatedly notify the user")
    func deduplicatesOutage() async throws {
        let center = TestNotificationCenter()
        let notices = RecordingNotifications(center: center, activity: activity, appIsActive: { false })
        notices.post(problem: .sourceUnavailable(.microphone, retrying: true), noteFolderURL: folder)
        try await waitUntil { center.requests.count == 1 }
        notices.post(problem: .sourceUnavailable(.microphone, retrying: false), noteFolderURL: folder)
        try await Task.sleep(for: .milliseconds(30))
        #expect(center.requests.count == 1)
        notices.clear(noteFolderURL: folder)
        #expect(center.removedDelivered.contains(folder.path))
    }

    @Test("recovery before permission is granted prevents a stale notification")
    func discardsRecoveredFailureWhileAwaitingPermission() async throws {
        let center = TestNotificationCenter()
        center.waitForPermission = true
        let notices = RecordingNotifications(center: center, activity: activity, appIsActive: { false })
        notices.post(problem: .noAudio, noteFolderURL: folder)
        try await waitUntil { center.permission != nil }
        notices.clear(noteFolderURL: folder)
        center.permission?.resume(returning: true)
        center.permission = nil
        try await Task.sleep(for: .milliseconds(30))
        #expect(center.requests.isEmpty)
    }

    @Test("denied notifications retain the persistent menu error and expose settings")
    func deniedPermissionDoesNotHideError() async throws {
        let center = TestNotificationCenter()
        center.allowed = false
        let notices = RecordingNotifications(center: center, activity: activity, appIsActive: { false })
        activity.report(.noAudio, noteFolderURL: folder)
        notices.post(problem: .noAudio, noteFolderURL: folder)
        try await waitUntil { center.authorizationRequested }
        try await Task.sleep(for: .milliseconds(30))
        #expect(center.requests.isEmpty)
        #expect(activity.notificationsUnavailable)
        #expect(activity.problem?.problem == .noAudio)
        activity.clearProblem(noteFolderURL: folder)
    }

    @Test("foreground failures use the persistent app UI without duplicate desktop alerts")
    func foregroundFailure() async throws {
        let center = TestNotificationCenter()
        let notices = RecordingNotifications(center: center, activity: activity, appIsActive: { true })
        notices.post(problem: .noAudio, noteFolderURL: folder)
        try await waitUntil { center.authorizationRequested }
        try await Task.sleep(for: .milliseconds(30))
        #expect(center.requests.isEmpty)
    }
}

@MainActor
private final class TestNotificationCenter: RecordingNotificationCenter {
    weak var delegate: (any UNUserNotificationCenterDelegate)?
    var requests: [UNNotificationRequest] = []
    var categories: Set<UNNotificationCategory> = []
    var removedDelivered: [String] = []
    var allowed = true
    var waitForPermission = false
    var permission: CheckedContinuation<Bool, Never>?
    var authorizationRequested = false

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequested = true
        if waitForPermission { return await withCheckedContinuation { permission = $0 } }
        return allowed
    }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories }
    func add(_ request: UNNotificationRequest) async throws { requests.append(request) }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { removedDelivered += identifiers }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
}
