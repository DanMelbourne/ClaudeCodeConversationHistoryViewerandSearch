import Foundation
import Sentry

/// Thin wrapper around the Sentry SDK.
///
/// Crash reporting is on by default (opt-out). Call `configure(enabled:)` once at launch;
/// call again whenever the preference changes.
///
/// The DSN is read from the main bundle's Info.plist key `SentryDSN`.
/// In debug builds you can override it by setting the env var `SENTRY_DSN`.
@MainActor
enum CrashReporter {
    private static var isInitialised = false

    /// One identifier per process launch, used to group App Hang events.
    ///
    /// CODE-COMPANION-1 is 394 occurrences of "App Hanging" from a single
    /// user, and 30 of this project's issues are hangs. That is not 30 bugs:
    /// Sentry's App Hang report is a single stack SAMPLE, and the sampled top
    /// frame differs between samples, so one stalled session files a new
    /// "issue" every couple of minutes. Grouping per app RUN turns an episode
    /// into one issue carrying N events, which is the unit a person can act
    /// on — and it stops a genuine crash being buried under the hang page.
    nonisolated private static let processRunID = UUID().uuidString

    /// The grouping fingerprint for one event, or `nil` to leave Sentry's own
    /// grouping alone.
    ///
    /// Pure so a test can prove both directions without starting the SDK —
    /// `configure` refuses to run under XCTest, so anything reachable only
    /// from inside `SentrySDK.start` is untestable here. Only App Hangs are
    /// regrouped; a crash keeps Sentry's grouping, which is exactly what makes
    /// it visible above the hangs again.
    nonisolated static func groupingFingerprint(
        mechanismType: String?,
        releaseName: String,
        runID: String
    ) -> [String]? {
        guard mechanismType == appHangMechanismType else { return nil }
        return ["app-hang", releaseName, runID]
    }

    /// The mechanism type sentry-cocoa stamps on a hang
    /// (`SentryANRTrackingIntegration`: `initWithType:@"AppHang"`).
    nonisolated static let appHangMechanismType = "AppHang"

    /// What the fingerprint uses to keep two builds' episodes apart. The SDK
    /// derives its own `release` the same way when none is set explicitly.
    nonisolated static func currentReleaseName(bundle: Bundle = .main) -> String {
        let id = bundle.bundleIdentifier ?? "ClaudeCodeCompanion"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?): return "\(id)@\(version)+\(build)"
        case let (version?, nil): return "\(id)@\(version)"
        default: return id
        }
    }

    static func configure(enabled: Bool) {
        guard !isRunningUnitTests() else {
            print("[CrashReporter] Sentry disabled in XCTest")
            return
        }
        guard enabled else {
            if isInitialised {
                SentrySDK.close()
                isInitialised = false
            }
            return
        }
        guard !isInitialised else { return }
        guard let dsn = resolveDSN(), !dsn.isEmpty else {
            print("[CrashReporter] No SentryDSN configured — crash reporting unavailable")
            return
        }
        let releaseName = currentReleaseName()
        let runID = processRunID
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = isDebugBuild ? "debug" : "production"
            options.enableAutoSessionTracking = false // respect privacy; no session metrics
            options.enableWatchdogTerminationTracking = true
            options.debug = isDebugBuild

            // App hang detection — reports when main thread is blocked.
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 2 // report hangs > 2 seconds

            // No performance tracing — just crash + hang reporting.
            options.tracesSampleRate = 0
            options.profilesSampleRate = 0

            // Collapse a hang EPISODE into one issue. `beforeSend` runs off
            // the main thread, so both inputs are read here and captured by
            // value rather than reached for from inside the closure.
            options.beforeSend = { event in
                if let fingerprint = groupingFingerprint(
                    mechanismType: event.exceptions?.first?.mechanism?.type,
                    releaseName: releaseName,
                    runID: runID
                ) {
                    event.fingerprint = fingerprint
                }
                return event
            }
        }
        isInitialised = true
        print("[CrashReporter] Sentry crash reporting enabled (env: \(isDebugBuild ? "debug" : "production"))")
    }

    static func setUserContext(id: String) {
        guard isInitialised else { return }
        let user = Sentry.User(userId: id)
        SentrySDK.setUser(user)
    }

    /// Add a Sentry breadcrumb — a trail entry attached to any later event.
    /// No-op when crash reporting is disabled.
    static func breadcrumb(_ message: String, category: String, level: SentryLevel = .info) {
        guard isInitialised else { return }
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Capture a non-fatal error as a Sentry event, with optional searchable tags.
    /// No-op when crash reporting is disabled.
    static func capture(_ error: Error, tags: [String: String] = [:]) {
        guard isInitialised else { return }
        SentrySDK.capture(error: error) { scope in
            for (key, value) in tags {
                scope.setTag(value: value, key: key)
            }
        }
    }

    // MARK: - Helpers

    nonisolated static func isRunningUnitTests(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    private static func resolveDSN() -> String? {
        if let envDSN = ProcessInfo.processInfo.environment["SENTRY_DSN"], !envDSN.isEmpty {
            return envDSN
        }
        return Bundle.main.infoDictionary?["SentryDSN"] as? String
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }
}
