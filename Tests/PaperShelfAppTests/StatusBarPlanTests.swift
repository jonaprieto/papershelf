import XCTest
@testable import PaperShelf

/// What the bar says while a plan is being worked through. A reviewer reads this line
/// several hundred times in a sitting, so what it leaves out matters as much as what it
/// says: a count of zero is a count to read past.
final class StatusBarPlanTests: XCTestCase {

    private func facts(total: Int = 312, confirmed: Int = 47, skipped: Int = 8,
                       trashed: Int = 0, pending: Int = 265,
                       backupFolder: String? = "original_pdfs", sources: Int = 3,
                       builtAt: Date? = nil) -> StatusBar.PlanFacts {
        StatusBar.PlanFacts(total: total, confirmed: confirmed, skipped: skipped,
                            trashed: trashed, pending: pending,
                            backupFolder: backupFolder, sources: sources, builtAt: builtAt)
    }

    func testProgressNamesOnlyWhatIsThere() {
        XCTAssertEqual(facts().progress, "47 confirmed · 8 skipped · 265 to go")
        XCTAssertEqual(facts(confirmed: 0, skipped: 0, pending: 312).progress, "312 to go")
        XCTAssertEqual(facts(confirmed: 1, skipped: 0, trashed: 2, pending: 9).progress,
                       "1 confirmed · 2 to trash · 9 to go")
    }

    /// Nothing left to decide still says so, rather than going blank at the one moment
    /// the bar is worth reading.
    func testAFinishedPlanStillSaysWhereItIs() {
        XCTAssertEqual(facts(confirmed: 312, skipped: 0, pending: 0).progress,
                       "312 confirmed · 0 to go")
    }

    func testTheFractionIsWhatIsDecided() {
        XCTAssertEqual(facts(total: 100, pending: 25).fraction, 0.75, accuracy: 0.0001)
        XCTAssertEqual(facts(total: 0, pending: 0).fraction, 0, "no plan is not a division by zero")
    }

    /// Whether a rename can be taken back is the one thing worth a permanent line.
    func testWhatHappensToTheOriginals() {
        XCTAssertEqual(facts().originals, "Originals move to original_pdfs/")
        XCTAssertEqual(facts(backupFolder: nil).originals, "Originals are replaced")
    }

    func testHowOldThePlanIs() {
        let now = Date()
        XCTAssertEqual(facts(builtAt: now).built, "Plan built just now from 3 sources")
        XCTAssertEqual(facts(builtAt: now.addingTimeInterval(-120)).built,
                       "Plan built 2 min ago from 3 sources")
        XCTAssertEqual(facts(sources: 1, builtAt: now.addingTimeInterval(-3600)).built,
                       "Plan built 1 hour ago from 1 source")
        XCTAssertEqual(facts(builtAt: nil).built, "No plan built yet")
    }
}
