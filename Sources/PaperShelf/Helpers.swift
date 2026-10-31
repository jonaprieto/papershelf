import AppKit

/// Replaces whatever is on the pasteboard with this text.
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// A size the way Finder writes it.
func formattedBytes(_ bytes: some BinaryInteger) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
