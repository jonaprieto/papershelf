import Foundation
import PaperShelfCore

/// Moves a managed notes companion with the PDF, whether future synchronization is on or
/// off. Turning synchronization off must not strand or delete a file already generated.
func moveNotesSidecar(for item: Item) {
    guard item.carriedOut else { return }
    let oldPDF = item.source.resolvingSymlinksInPath()
    let newPDF = item.currentURL.resolvingSymlinksInPath()
    guard oldPDF.path != newPDF.path else { return }

    let oldSidecar = notesSidecarURL(for: oldPDF)
    let newSidecar = notesSidecarURL(for: newPDF)
    guard FileManager.default.fileExists(atPath: oldSidecar.path) else { return }

    do {
        if FileManager.default.fileExists(atPath: newSidecar.path) {
            _ = try FileManager.default.replaceItemAt(newSidecar, withItemAt: oldSidecar)
        } else {
            try FileManager.default.moveItem(at: oldSidecar, to: newSidecar)
        }
    } catch {
        // The PDF move has already completed; leaving the sidecar in place is safer than
        // deleting it when a destination volume or permissions make the companion move fail.
    }
}
