import XCTest
@testable import PaperShelf

@MainActor
final class PDFReadingAppearanceTests: XCTestCase {

    func testAppearanceOffersNormalTintAndWhiteOnBlack() {
        XCTAssertEqual(PDFReadingAppearance.allCases,
                       [.normal, .tint, .whiteOnBlack])
    }

    func testThemeMapsToTheCommandPaletteColorScheme() {
        XCTAssertNil(Appearance.system.colorScheme)
        XCTAssertEqual(Appearance.light.colorScheme, .light)
        XCTAssertEqual(Appearance.dark.colorScheme, .dark)
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
