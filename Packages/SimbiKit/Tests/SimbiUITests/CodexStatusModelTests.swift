import Testing

@testable import SimbiUI

@MainActor @Suite("Codex status")
struct CodexStatusModelTests {
    @Test("unavailable status offers a retry action")
    func unavailableStatusOffersRetry() {
        let phase = CodexStatusModel.Phase.unavailable("Codex did not answer.")

        #expect(phase.reloadActionTitle == "Try Again")
    }
}
