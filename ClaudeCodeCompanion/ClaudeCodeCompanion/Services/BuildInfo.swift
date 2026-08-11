import Foundation

/// Which build is actually running.
///
/// `build.sh` stamps the source commit, branch and build time into the bundle's
/// Info.plist; this reads them back so the window can answer "am I looking at
/// the build I just made?" without anyone checking a file date in Finder.
struct BuildInfo: Equatable, Sendable {
    let version: String          // CFBundleShortVersionString, e.g. "1.0.12"
    let build: String            // CFBundleVersion, e.g. "12"
    let buildDate: Date?
    let sourceBranch: String?
    let sourceCommit: String?
    let hasUncommittedChanges: Bool
    let configuration: String?

    // MARK: - Reading the bundle

    static let current = BuildInfo(bundle: .main)

    init(bundle: Bundle) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "—"
        build = info["CFBundleVersion"] as? String ?? "—"
        buildDate = (info["CCCBuildDate"] as? String).flatMap(Self.parseDate)
        sourceBranch = (info["CCCBuildSourceBranch"] as? String).nonEmpty
        sourceCommit = (info["CCCBuildSourceCommit"] as? String).nonEmpty
        hasUncommittedChanges = info["CCCBuildDirty"] as? Bool ?? false
        configuration = (info["CCCBuildConfiguration"] as? String).nonEmpty
    }

    init(
        version: String,
        build: String,
        buildDate: Date?,
        sourceBranch: String? = nil,
        sourceCommit: String? = nil,
        hasUncommittedChanges: Bool = false,
        configuration: String? = nil
    ) {
        self.version = version
        self.build = build
        self.buildDate = buildDate
        self.sourceBranch = sourceBranch
        self.sourceCommit = sourceCommit
        self.hasUncommittedChanges = hasUncommittedChanges
        self.configuration = configuration
    }

    // MARK: - Display

    /// "v1.0.12 (12)" — the identity of this build at a glance.
    var versionLabel: String {
        "v\(version) (\(build))"
    }

    /// "built 4 min ago". Nil when the bundle carries no build date, which is
    /// what an Xcode-IDE build looks like — worth saying out loud rather than
    /// showing a made-up time.
    func builtAgoLabel(now: Date = Date()) -> String? {
        guard let buildDate else { return nil }
        return "built \(Self.relativeAge(from: buildDate, to: now))"
    }

    /// Short relative age, biased to the units a developer thinks in.
    static func relativeAge(from date: Date, to now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded())
        if seconds < 0 { return "in the future" }   // clock skew; do not lie about it
        switch seconds {
        case ..<45: return "just now"
        case ..<90: return "1 min ago"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<7200: return "1 hour ago"
        case ..<86_400: return "\(seconds / 3600) hours ago"
        case ..<172_800: return "yesterday"
        case ..<2_592_000: return "\(seconds / 86_400) days ago"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM yyyy"
            return "on \(formatter.string(from: date))"
        }
    }

    /// Multi-line detail for the tooltip: exact time, source, warnings.
    func detailText(now: Date = Date()) -> String {
        var lines = ["\(versionLabel)"]

        if let buildDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE d MMM yyyy, h:mm a"
            lines.append("Built \(formatter.string(from: buildDate)) — \(Self.relativeAge(from: buildDate, to: now))")
        } else {
            lines.append("No build stamp — built from Xcode, not ./build.sh")
        }

        if let sourceBranch, let sourceCommit {
            lines.append("Source: \(sourceBranch) @ \(String(sourceCommit.prefix(12)))")
        }
        if hasUncommittedChanges {
            lines.append("Built with uncommitted changes")
        }
        if let configuration, configuration != "Release" {
            lines.append("Configuration: \(configuration)")
        }
        return lines.joined(separator: "\n")
    }

    /// True when this build is old enough that the user is probably looking at
    /// a stale copy while iterating.
    func isStale(now: Date = Date(), threshold: TimeInterval = 24 * 3600) -> Bool {
        guard let buildDate else { return false }
        return now.timeIntervalSince(buildDate) > threshold
    }

    // MARK: - Private

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
