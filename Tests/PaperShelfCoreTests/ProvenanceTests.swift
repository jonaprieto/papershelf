import XCTest
@testable import PaperShelfCore

/// Reading a planned name back apart into what it was built from, for the panel in the
/// reviewer that says so. Nothing may be claimed that is not in the name or in the item.
final class ProvenanceTests: XCTestCase {

    private func makeItem(from source: String, to destination: String,
                          metadataDate: Date? = nil, modifiedDate: Date? = nil,
                          info: [String: String] = [:]) -> Item {
        var item = Item(root: URL(fileURLWithPath: "/papers"),
                        source: URL(fileURLWithPath: "/papers/" + source),
                        destination: URL(fileURLWithPath: "/papers/" + destination),
                        status: .renamed)
        item.metadataDate = metadataDate
        item.modifiedDate = modifiedDate
        item.documentInfo = info
        return item
    }

    private func labels(_ provenance: NameProvenance) -> [String] {
        provenance.parts.map { "\($0.label)=\($0.value)" }
    }

    func testTheThreePartsOfAnOrdinaryName() {
        let item = makeItem(from: "mostly_harmless_econometrics_FINAL(2).pdf",
                            to: "2009-angrist-mostly-harmless-econometrics.pdf",
                            info: ["Author": "Angrist, Joshua D."])
        XCTAssertEqual(labels(nameProvenance(for: item)),
                       ["date=2009", "author=angrist", "title=mostly-harmless-econometrics"])
    }

    /// No author in the name means no author part, however the document is signed.
    func testAnAuthorIsClaimedOnlyWhenItIsInTheName() {
        let item = makeItem(from: "book.pdf", to: "2009-mostly-harmless.pdf",
                            info: ["Author": "Angrist, Joshua D."])
        XCTAssertEqual(labels(nameProvenance(for: item)),
                       ["date=2009", "title=mostly-harmless"])
    }

    func testAYearAndMonthStaysOnePart() {
        let item = makeItem(from: "statement.pdf", to: "2024-06-cuenta-abc123.pdf")
        XCTAssertEqual(labels(nameProvenance(for: item)),
                       ["date=2024-06", "title=cuenta-abc123"])
    }

    func testANameWithNoDateIsAllTitle() {
        let item = makeItem(from: "notes.pdf", to: "reading-notes.pdf")
        XCTAssertEqual(labels(nameProvenance(for: item)), ["title=reading-notes"])
    }

    /// The note is about where the year came from, so it is only made when the year was
    /// not in the name to begin with and the item says where it did come from.
    func testWhereTheYearCameFrom() {
        let fromDocument = makeItem(from: "book.pdf", to: "2009-book.pdf",
                                    metadataDate: Date(timeIntervalSince1970: 1_234_567_890))
        XCTAssertEqual(nameProvenance(for: fromDocument).notes.first,
                       "Year read from the document, not the filename — the name carried none.")

        let fromFile = makeItem(from: "book.pdf", to: "2009-book.pdf",
                                modifiedDate: Date(timeIntervalSince1970: 1_234_567_890))
        XCTAssertEqual(nameProvenance(for: fromFile).notes.first,
                       "Year taken from the file's own date — neither the name nor the document said.")

        let alreadyThere = makeItem(from: "2009 book.pdf", to: "2009-book.pdf",
                                    metadataDate: Date(timeIntervalSince1970: 1_234_567_890))
        XCTAssertTrue(alreadyThere.metadataDate != nil)
        XCTAssertTrue(nameProvenance(for: alreadyThere).notes.isEmpty,
                      "the name carried the year, so nothing was read from anywhere")

        let noEvidence = makeItem(from: "book.pdf", to: "2009-book.pdf")
        XCTAssertTrue(nameProvenance(for: noEvidence).notes.isEmpty,
                      "nothing on the item says where it came from, so nothing is said")
    }

    func testCopyMarkersAreNamedWhenTheyAreDropped() {
        let item = makeItem(from: "mostly_harmless_FINAL(2).pdf", to: "mostly-harmless.pdf")
        XCTAssertEqual(nameProvenance(for: item).notes,
                       ["FINAL and (2) dropped as copy markers."])
    }

    func testOneMarkerIsSingular() {
        let item = makeItem(from: "report copy.pdf", to: "report.pdf")
        XCTAssertEqual(nameProvenance(for: item).notes, ["COPY dropped as copy marker."])
    }

    /// A title that happens to contain one of the words keeps it, because it is still
    /// there afterwards.
    func testAWordThatSurvivesIsNotAMarker() {
        let item = makeItem(from: "Final Cut Pro.pdf", to: "final-cut-pro.pdf")
        XCTAssertTrue(nameProvenance(for: item).notes.isEmpty)
    }

    func testANameThatDidNotChangeSaysNothingExtra() {
        let item = makeItem(from: "already-fine.pdf", to: "already-fine.pdf")
        let provenance = nameProvenance(for: item)
        XCTAssertEqual(labels(provenance), ["title=already-fine"])
        XCTAssertTrue(provenance.notes.isEmpty)
    }
}
