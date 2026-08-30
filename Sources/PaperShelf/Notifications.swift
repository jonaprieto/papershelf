import AppKit
import UserNotifications
import PaperShelfCore

// Whether a local notification can ever reach the user here was checked empirically before
// writing any of this, exactly as asked, using a standalone ad-hoc-signed .app bundle (the
// same signing `build.sh` does: `codesign --force --sign -`), launched both directly and via
// `open`, from a scratch path and from /Applications, with `NSApp.setActivationPolicy(.regular)`
// and a real window so it looked as much like a normal foreground app as possible:
//
//   - Direct execution, any path: `requestAuthorization` returns within milliseconds with
//     `granted=false` and `UNErrorDomain` code 1, "Notifications are not allowed for this
//     application" -- no system prompt is ever shown, and `getNotificationSettings` reports
//     `authorizationStatus` unchanged from before the call (0, notDetermined, for a bundle id
//     never seen before). This is not the user saying no; nothing ever asked them.
//   - Launched from /Applications: the first `requestAuthorization` call does not return at
//     all within 45 seconds and no prompt is ever visibly shown; a second launch minutes
//     later reports `authorizationStatus == 1` (denied) immediately, meaning the first
//     request was resolved in the background, after this process's own wait had already
//     given up, again with nothing shown to a person to answer.
//
// So: in this environment, on this machine, notifications never reach the user and never
// give them anything to click "Allow" on, exactly the silent failure Apple's own docs already
// warn `add(_:)` degrades to once denied -- just arrived at without a user ever making that
// choice. Nothing here is written as if this will work. `DuplicateAlert.present` below opens
// the review window unconditionally and does not wait on, or care about, whether the
// notification below ever shows.

/// Best-effort local notification for a duplicate the watcher finds while the app is running.
/// See the file-level note above for why this can never be the only way the user finds out.
@MainActor
enum DuplicateNotifications {
    private static var prepared = false
    private static let delegate = BannerDelegate()

    /// Call once; safe to call again; requesting authorization more than once just re-asks
    /// the system a question it already knows the answer to; see the file-level note on why
    /// nothing here reads the answer or reacts to it.
    static func prepare() {
        guard !prepared else { return }
        prepared = true
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(for group: DuplicateGroup) {
        let content = UNMutableNotificationContent()
        content.title = "Possible duplicate found"
        content.body = summary(of: group)
        content.sound = .default
        let request = UNNotificationRequest(identifier: "duplicate-\(group.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private static func summary(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names.dropLast().joined(separator: ", ")), and \(names.last ?? "")"
        }
    }

    private static func summary(of group: DuplicateGroup) -> String {
        let names = summary(group.items.map(\.sourceName))
        switch group.kind {
        case .identical: return "\(names) look byte-for-byte identical."
        case .sameText: return "\(names) open with the same text."
        case .likely: return "\(names) share a name."
        }
    }

    /// Without this delegate opting in, `UNUserNotificationCenter` suppresses a notification
    /// whenever the posting app is already frontmost -- exactly the ordinary case here, since
    /// the watcher only runs while PaperShelf is open. Moot everywhere this was tested (see
    /// the file-level note), kept for the one real Mac where authorization is ever granted.
    private final class BannerDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }
    }
}

/// The one entry point the watcher needs: called once per newly detected group, straight
/// from `DuplicateIndex.insert`'s return value. Posts a best-effort notification and opens
/// the review window (DuplicateReview.swift) unconditionally -- the window is what the user
/// actually sees; the notification is a bonus on top of it, not a precondition for it.
///
/// `onKeepBoth` is the one thing this cannot do itself: persisting the dismissal (this file)
/// happens here, but forgetting the match *this run*, before the next relaunch reloads it
/// from disk, means telling the caller's own `DuplicateIndex` -- which lives on `Runner`, not
/// here. That one call (`duplicateIndex.dismiss(id)`) is the hook; see the accompanying notes
/// for exactly where it goes.
@MainActor
public enum DuplicateAlert {
    public static func present(
        _ group: DuplicateGroup,
        thumbnail: @escaping (Item) -> NSImage?,
        trashNow: @escaping (Item) -> Void,
        onKeepBoth: @escaping (String) -> Void
    ) {
        DuplicateNotifications.prepare()
        DuplicateNotifications.post(for: group)
        DuplicateReviewWindow.present(
            group,
            thumbnail: thumbnail,
            trashNow: trashNow,
            keepBoth: {
                // Recorded in the library rather than a file of its own, so the interface
                // and the MCP server cannot lose each other's writes.
                if let library = Library.shared {
                    Task { try? await library.dismissDuplicate(groupID: group.id) }
                }
                onKeepBoth(group.id)
            }
        )
    }
}
