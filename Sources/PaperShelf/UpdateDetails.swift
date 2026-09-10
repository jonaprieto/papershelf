import SwiftUI
import AppKit

/// Every entry point checks both sources without making a sleeping checkout delay GitHub.
@MainActor
func checkForUpdates(manual: Bool) {
    Task { await LocalBuildUpdates.shared.check() }
    Task {
        await ReleaseUpdates.shared.check(manual: manual,
                                          automaticChecks: Prefs.shared.automaticallyCheckForReleases)
    }
}

struct CheckForUpdatesButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(Command.checkForUpdates.title) {
            openWindow(id: UpdateDetails.windowID)
            checkForUpdates(manual: true)
        }
        .disabled(ReleaseUpdates.shared.checking)
        .accessibilityIdentifier("updates.check")
        .tip("Check GitHub for a stable release and look for completed local builds")
    }
}

struct UpdateNotice: View {
    private let releases = ReleaseUpdates.shared
    private let local = LocalBuildUpdates.shared
    @State private var showingDetails = false

    var body: some View {
        if local.showsBadge || releases.showsBadge {
            Button { showingDetails = true } label: {
                Text(local.showsBadge ? "Local build available" : "Update available")
                    .font(Face.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .fixedSize()
            .accessibilityIdentifier("updates.notice")
            .tip("Compare the running build with available updates")
            .popover(isPresented: $showingDetails, arrowEdge: .top) {
                UpdateDetails()
            }
        }
    }
}

struct UpdateDetails: View {
    static let windowID = "updates"
    var releases: ReleaseUpdates = .shared
    var local: LocalBuildUpdates = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.roomy) {
            Text("PaperShelf updates").font(Face.title)
            identity("Running", releases.running)
            Divider()
            VStack(alignment: .leading, spacing: Space.step) {
                HStack(spacing: Space.step) {
                    if releases.checking { ProgressView().controlSize(.small) }
                    Text(releases.statusText).fontWeight(.medium)
                }
                if let release = releases.release, let version = release.version {
                    HStack {
                        Text("Latest release: \(version.description)")
                        Spacer()
                        Link("View release", destination: release.html_url)
                            .foregroundStyle(Color.accentColor)
                            .tip("Open the release notes and download on GitHub")
                            .accessibilityIdentifier("updates.release")
                    }
                    if releases.newerRelease != nil {
                        Button(releases.showsBadge ? "Hide this release notice" : "Release notice hidden") {
                            releases.dismissRelease()
                        }
                        .disabled(!releases.showsBadge)
                        .tip("Hide the footer notice for this version; keep its details here")
                    }
                }
                if let date = releases.lastSuccess {
                    Text("Last successful check: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No successful release check yet.").foregroundStyle(.secondary)
                }
                if let retry = releases.retryAfter, retry > Date() {
                    Text("Try again after \(retry.formatted(date: .abbreviated, time: .shortened)).")
                        .foregroundStyle(.secondary)
                }
                CheckForUpdatesButton()
                if releases.running.channel == .development {
                    Text("Development builds are identified separately from published releases.")
                        .foregroundStyle(.secondary)
                }
            }
            if let available = local.available {
                Divider()
                VStack(alignment: .leading, spacing: Space.step) {
                    identity("Available build", available)
                    Text(available.bundleURL.path)
                        .font(Face.mono)
                        .foregroundStyle(.secondary)
                    Text("Relaunch this build to use it. Finish saving your notes, quit PaperShelf, then open this copy.")
                    HStack {
                        Button("Reveal build in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([available.bundleURL])
                        }
                        .tip("Show the completed app bundle without quitting or installing it")
                        .accessibilityIdentifier("updates.revealBuild")
                        Spacer()
                        Button(local.showsBadge ? "Hide notice" : "Notice hidden") { local.dismissBuild() }
                            .disabled(!local.showsBadge)
                            .tip("Hide the footer notice for this build; keep its details here")
                    }
                }
            }
        }
        .font(Face.caption)
        .foregroundStyle(.primary)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .padding(Space.gutter)
        .frame(width: 440)
        .preferredColorScheme(Prefs.shared.appearance.colorScheme)
        .task { await local.check() }
    }

    private func identity(_ title: String, _ build: AppBuild) -> some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            Text("\(title): \(build.version) (\(build.build))").font(Face.body).fontWeight(.medium)
            Text("\(build.channel == .development ? "Development" : "Release") · \(build.revision ?? "Revision unrecorded")")
                .foregroundStyle(.secondary)
            if let date = build.builtAt {
                Text("Built \(date.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let id = build.id {
                Text("ID \(id.uuidString.lowercased())").font(Face.mono).foregroundStyle(.secondary)
            }
        }
    }
}
