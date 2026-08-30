import XCTest
@testable import PaperShelf

/// Reading mode and the inspector, which used to be two answers to the same question.
///
/// The panel was hidden by `!collapsed && !reading`, so while reading the toolbar's
/// inspector button, ⌥⌘I and ⌘⇧N all flipped a switch nothing was reading and the window
/// did not change. One switch decides it now, and the mode does not touch it: reading a
/// paper with the notes beside it is the ordinary way to read.
@MainActor
final class ReadingModeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "readingMode")
        UserDefaults.standard.removeObject(forKey: "inspectorCollapsed")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "readingMode")
        UserDefaults.standard.removeObject(forKey: "inspectorCollapsed")
        super.tearDown()
    }

    /// The mode moves the browser out of the way and nothing else. A panel opened by hand
    /// is still open on the way in, and one shut by hand is still shut on the way out.
    func testReadingModeLeavesTheInspectorAlone() {
        let chrome = Chrome()
        XCTAssertFalse(chrome.reading)
        XCTAssertFalse(chrome.inspectorCollapsed)

        chrome.toggleReading()
        XCTAssertTrue(chrome.reading)
        XCTAssertFalse(chrome.inspectorCollapsed, "the notes stay beside the page")

        chrome.inspectorCollapsed = true
        chrome.toggleReading()
        XCTAssertFalse(chrome.reading)
        XCTAssertTrue(chrome.inspectorCollapsed, "the panel was closed by hand, not by the mode")
    }

    /// The bug this whole change is about: the button has to be able to open and close the
    /// panel while reading, rather than being overruled by the mode.
    func testTheInspectorCanBeWorkedWhileReading() {
        let chrome = Chrome()
        chrome.toggleReading()

        chrome.inspectorCollapsed = true
        XCTAssertTrue(chrome.reading, "closing the inspector does not leave reading mode")

        chrome.showNotes()
        XCTAssertTrue(chrome.notesShown)
        XCTAssertTrue(chrome.reading)
    }

    /// A click on a shelf row leaves reading mode whether or not it was on.
    func testLeavingAModeYouAreNotInChangesNothing() {
        let chrome = Chrome()
        chrome.inspectorCollapsed = true

        chrome.setReading(false)
        XCTAssertFalse(chrome.reading)
        XCTAssertTrue(chrome.inspectorCollapsed)
    }
}
