import AppKit

/// Replaces whatever is on the pasteboard with this text.
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
