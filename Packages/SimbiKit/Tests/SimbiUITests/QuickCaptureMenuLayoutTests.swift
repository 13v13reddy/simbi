import AppKit
import SwiftUI
import Testing

@testable import SimbiUI

@MainActor @Suite struct QuickCaptureMenuLayoutTests {
    @Test func menuUsesCompactPopoverDimensions() {
        let hostingView = NSHostingView(rootView: QuickCaptureMenuContent())
        hostingView.layoutSubtreeIfNeeded()

        let size = hostingView.fittingSize
        #expect(size.width <= 220)
        #expect(size.height <= 130)
    }
}
