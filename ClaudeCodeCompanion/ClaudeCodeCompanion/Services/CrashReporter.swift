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

    static func configure(enabled: Bool) {
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
