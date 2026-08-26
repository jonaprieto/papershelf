import SwiftUI
import PDFHammerCore

extension View {
    /// A tooltip: one short line saying what the control is, and its key if it has one.
    ///
    /// A tooltip is read in the second before someone gives up and clicks anyway, so it
    /// has to fit that. The long explanations live in the footers under each panel, where
    /// there is room to read them.
    func tip(_ what: String, key: String? = nil) -> some View {
        help(key.map { "\(what)  (\($0))" } ?? what)
    }
}

extension Status {
    /// What a status pill means, for its tooltip.
    var explanation: String {
        switch self {
        case .decrypted: return "Was encrypted; a password matched and it will be written out unlocked"
        case .renamed: return "Not encrypted; copied through unchanged"
        case .locked: return "Encrypted and no password matched; renamed but still locked"
        case .encrypted: return "Will be written out locked with your password"
        case .trashed: return "Marked for the Trash"
        case .moved: return "Moving to the folder you chose when you apply"
        case .failed: return "Something went wrong; the note says what"
        }
    }
}

extension Decision {
    /// What a review mark means, and how to change it.
    var explanation: String {
        switch self {
        case .confirmed: return "Confirmed, and included when you apply"
        case .applied: return "Already carried out on disk"
        case .skipped: return "Left alone; nothing will happen to it"
        case .deleted: return "Headed for the Trash when you apply"
        case .moveTo(let folder): return "Moving to \(folder.lastPathComponent) when you apply"
        }
    }
}

/// The same for a file nothing has been decided about yet.
let undecidedExplanation = "Not reviewed yet"
