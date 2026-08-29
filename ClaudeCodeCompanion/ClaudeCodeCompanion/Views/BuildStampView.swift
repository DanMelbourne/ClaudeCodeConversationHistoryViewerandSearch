import AppKit
import SwiftUI

/// Sidebar footer showing which build is running and how long ago it was made.
///
/// The age re-renders on a timer so "just now" becomes "12 min ago" without a
/// relaunch — the whole point is to notice when the window in front of you is
/// not the build you just made.
struct BuildStampView: View {
    var info: BuildInfo = .current

    @State private var now = Date()

    /// One clock for the process, not one per view init.
    ///
    /// As a stored `let`, this was rebuilt every time the struct was
    /// re-created — which for a sidebar footer is every parent render — and
    /// `onReceive` then cancelled the old run-loop timer and scheduled a new
    /// one each time. A shared publisher is subscribed once and left alone.
    private static let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: info.hasUncommittedChanges ? "hammer.circle.fill" : "hammer.circle")
                .font(.caption)
                .foregroundStyle(info.isStale(now: now) ? Color.orange : .secondary)

            Text(info.versionLabel)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            if let builtAgo = info.builtAgoLabel(now: now) {
                Text("· \(builtAgo)")
                    .font(.caption2)
                    .foregroundStyle(info.isStale(now: now) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            } else {
                Text("· unstamped build")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help(info.detailText(now: now))
        .onReceive(Self.tick) { now = $0 }
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info.detailText(now: now), forType: .string)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Build \(info.versionLabel), \(info.builtAgoLabel(now: now) ?? "no build stamp")")
    }
}
