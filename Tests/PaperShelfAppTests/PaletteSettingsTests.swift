import XCTest
@testable import PaperShelf

/// Settings reachable from the palette: the name finds them, the row says what they are
/// now, and Return changes it without a trip to the Settings window.
@MainActor
final class PaletteSettingsTests: XCTestCase {

    func testThePaletteCanOpenTheSettingsWindow() {
        let setting = try! XCTUnwrap(PaletteSettings.all().first { $0.id == "settings" })
        XCTAssertEqual(setting.title, "Open Settings")
        XCTAssertTrue(setting.opensSettings)
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

    func testAChoiceCyclesThroughItsValues() {
        let prefs = Prefs.shared
        let before = prefs.appearance
        defer { prefs.appearance = before }

        let setting = try! XCTUnwrap(PaletteSettings.all().first { $0.id == "appearance" })
        var seen: [Appearance] = [prefs.appearance]
        for _ in 1..<Appearance.allCases.count {
            setting.act()
            seen.append(prefs.appearance)
        }
        XCTAssertEqual(Set(seen), Set(Appearance.allCases), "every value is reachable")
        setting.act()
        XCTAssertEqual(prefs.appearance, before, "and it comes back round")
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
