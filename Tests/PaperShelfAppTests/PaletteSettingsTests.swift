import XCTest
@testable import PaperShelf

/// Settings reachable from the palette: the name finds them, the row says what they are
/// now, and Return changes it without a trip to the Settings window.
@MainActor
final class PaletteSettingsTests: XCTestCase {

    func testThePaletteCanOpenTheSettingsWindow() {
        XCTAssertEqual(Command.openSettings.title, "Open Settings")
        XCTAssertTrue(ResultsPane.performable.contains(.openSettings))
        XCTAssertTrue(ResultsPane.alwaysAvailable.contains(.openSettings))
        XCTAssertTrue(ReaderWindow.paletteCommands.contains(.openSettings))
    }

    func testDefaultPDFViewerIsSearchableInGeneralSettings() {
        XCTAssertTrue(SettingsPane.general.matches("default PDF viewer"))
        XCTAssertTrue(SettingsPane.general.matches("PDF app"))
    }

    func testAToggleFlipsWhereItStands() {
        let prefs = Prefs.shared
        let before = prefs.watchSources
        defer { prefs.watchSources = before }

        let watching = try? XCTUnwrap(PaletteSettings.all().first { $0.id == "watchSources" })
        let setting = try! XCTUnwrap(watching)
        XCTAssertEqual(setting.value(), before ? "On" : "Off", "the row says what it is now")
        setting.act()
        XCTAssertEqual(prefs.watchSources, !before)
        XCTAssertEqual(setting.value(), !before ? "On" : "Off", "and says it again after")
        XCTAssertFalse(setting.opensSettings)
    }

    /// A key typed into a search field is a key in a search field's history.
    func testTextValuedSettingsHandOverToTheWindow() {
        let secrets = PaletteSettings.all().filter { $0.opensSettings }.map(\.id)
        XCTAssertTrue(secrets.contains("apiKey"))
        XCTAssertTrue(secrets.contains("passwords"))
        XCTAssertTrue(secrets.contains("namePattern"))
        for id in secrets {
            let setting = try! XCTUnwrap(PaletteSettings.all().first { $0.id == id })
            XCTAssertEqual(setting.value(), "in Settings",
                           "the palette does not print the value either")
        }
    }
}

final class DefaultPDFViewerTests: XCTestCase {

    func testMatchingBundleIdentifiersMeanPaperShelfIsDefault() {
        XCTAssertTrue(DefaultPDFViewer.matches(handlerBundleIdentifier: "com.jonaprieto.pdfhammer",
                                                paperShelfBundleIdentifier: "com.jonaprieto.pdfhammer"))
    }

    func testDifferentOrMissingBundleIdentifiersAreNotPaperShelf() {
        XCTAssertFalse(DefaultPDFViewer.matches(handlerBundleIdentifier: "net.sourceforge.skim-app.skim",
                                                 paperShelfBundleIdentifier: "com.jonaprieto.pdfhammer"))
        XCTAssertFalse(DefaultPDFViewer.matches(handlerBundleIdentifier: nil,
                                                 paperShelfBundleIdentifier: "com.jonaprieto.pdfhammer"))
    }
}
