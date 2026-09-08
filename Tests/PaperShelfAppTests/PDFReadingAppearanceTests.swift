import XCTest
@testable import PaperShelf

@MainActor
final class PDFReadingAppearanceTests: XCTestCase {

    func testAppearanceOffersEveryContrastLightestPaperFirst() {
        XCTAssertEqual(PDFReadingAppearance.allCases,
                       [.normal, .sepia, .tint, .whiteOnBlack])
    }

    func testSepiaWarmsThePaperRatherThanDimmingIt() throws {
        let sepia = try XCTUnwrap(PDFReadingAppearance.sepia.wash)
        // Multiplied onto the page, so anything below the ink would darken the text along
        // with the paper. Warm means red over green over blue, and none of it dim.
        XCTAssertGreaterThan(sepia.red, sepia.green)
        XCTAssertGreaterThan(sepia.green, sepia.blue)
        XCTAssertGreaterThan(sepia.blue, 0.75)

        let tint = try XCTUnwrap(PDFReadingAppearance.tint.wash)
        XCTAssertLessThan(tint.red, sepia.red)
        XCTAssertNil(PDFReadingAppearance.normal.wash)
        XCTAssertNil(PDFReadingAppearance.whiteOnBlack.wash)
    }

    /// A contrast reachable from the menu but not by name is one a script, a Shortcut or
    /// the smoke test cannot reach at all.
    func testEveryContrastIsNamedInTheScriptingSurfaceAndTheSmokeTest() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sdef = try String(contentsOf: root.appendingPathComponent("Resources/PaperShelf.sdef"),
                              encoding: .utf8)
        let script = try String(contentsOf: root.appendingPathComponent("Tools/ui-smoke-test.applescript"),
                                encoding: .utf8)
        for mode in PDFReadingAppearance.allCases {
            XCTAssertTrue(sdef.contains(mode.label.lowercased()), mode.label)
            XCTAssertTrue(script.contains("\"\(mode.rawValue)\""), mode.rawValue)
            XCTAssertTrue(script.contains("\"\(mode.label)\""), mode.label)
        }
        XCTAssertTrue(script.contains("repeat with index from 1 to \(PDFReadingAppearance.allCases.count)"),
                      "the smoke test walks fewer contrasts than there are")
    }

    func testThemeMapsToTheCommandPaletteColorScheme() {
        XCTAssertNil(Appearance.system.colorScheme)
        XCTAssertEqual(Appearance.light.colorScheme, .light)
        XCTAssertEqual(Appearance.dark.colorScheme, .dark)
    }

    func testWhiteOnBlackStartsWithALightCanvasSoInversionLeavesDarkGray() {
        let color = PDFPreview.canvasColor(for: .whiteOnBlack).usingColorSpace(.sRGB)
        XCTAssertNotNil(color)
        XCTAssertEqual(Double(color!.redComponent), 232.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(Double(color!.greenComponent), 232.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(Double(color!.blueComponent), 235.0 / 255.0, accuracy: 0.001)
    }

    func testPaletteSettingCyclesThroughEveryPDFAppearance() {
        let prefs = Prefs.shared
        let before = prefs.readingAppearance
        defer { prefs.readingAppearance = before }

        let setting = try! XCTUnwrap(
            PaletteSettings.all().first { $0.id == "pdfAppearance" }
        )
        var seen: [PDFReadingAppearance] = [prefs.readingAppearance]
        for _ in 1..<PDFReadingAppearance.allCases.count {
            setting.act()
            seen.append(prefs.readingAppearance)
        }
        XCTAssertEqual(Set(seen), Set(PDFReadingAppearance.allCases))
        XCTAssertEqual(setting.value(), prefs.readingAppearance.label)
    }
}
