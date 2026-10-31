import AppKit
import SwiftUI

/// Replaces whatever is on the pasteboard with this text.
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// A size the way Finder writes it.
func formattedBytes(_ bytes: some BinaryInteger) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

/// A count and the noun it counts: "1 file", "2 files".
///
/// Plain text, so not for a `Text("...")` or `Button("...")` literal: those format the number
/// for the reader's locale, 1,000 rather than 1000, and this would quietly stop that.
func counted(_ count: some BinaryInteger, _ noun: String, plural: String? = nil) -> String {
    "\(count) \(count == 1 ? noun : plural ?? noun + "s")"
}

extension View {
    /// Saves text to a file the person chooses.
    func textExporter(isPresented: Binding<Bool>, text: String, filename: String,
                      onDone: @escaping () -> Void = {}) -> some View {
        fileExporter(isPresented: isPresented, document: TextDocument(text: text),
                     contentType: .plainText, defaultFilename: filename) { _ in onDone() }
    }
}
