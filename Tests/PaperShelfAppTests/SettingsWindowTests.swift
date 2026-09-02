import XCTest
import AppKit
@testable import PaperShelf

@MainActor
final class SettingsWindowTests: XCTestCase {

    func testSettingsWindowKeepsNativeTrafficLightsEnabled() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        SettingsWindowChrome.configure(window)

        XCTAssertTrue(window.standardWindowButton(.miniaturizeButton)?.isEnabled == true)
        XCTAssertTrue(window.standardWindowButton(.zoomButton)?.isEnabled == true)
    }
}
