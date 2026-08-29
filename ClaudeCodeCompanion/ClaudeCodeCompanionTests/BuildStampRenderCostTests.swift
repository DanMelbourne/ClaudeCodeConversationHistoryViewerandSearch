import XCTest
@testable import Claude_Code_Companion

/// Sentry CODE-COMPANION-15 — App Hang ≥2000 ms whose stack ends:
///
///     BuildStampView.body.getter
///     BuildInfo.detailText
///     -[NSDateFormatter stringForObjectValue:]
///     -[NSDateFormatter _regenerateFormatter]
///     __CreateCFDateFormatter → udat_open → icu::Locale::init
///
/// `BuildStampView.body` calls `detailText` on every evaluation to feed
/// `.help(...)`, and `detailText` built a fresh `DateFormatter` each time. ICU
/// locale construction, on the main thread, once per render.
///
/// The invariant is not "this call takes under N milliseconds" — a wall-clock
/// bound passes on a quiet machine and fails under load, proving nothing about
/// our code. It is a RATIO against a control measured in the same run: making
/// the tooltip must cost far less than constructing the formatters it needs.
/// If someone reintroduces a per-call `DateFormatter`, the two arms converge
/// and this goes red regardless of how fast or slow the machine is.
final class BuildStampRenderCostTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_800_000_000)

    private func info(minutesAgo: Double) -> BuildInfo {
        BuildInfo(
            version: "1.0.12",
            build: "12",
            buildDate: reference.addingTimeInterval(-minutesAgo * 60),
            sourceBranch: "main",
            sourceCommit: "abcdef0123456789",
            hasUncommittedChanges: false,
            configuration: "Release"
        )
    }

    private func elapsed(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    /// One render's worth of tooltip must not cost one formatter construction.
    func testDetailTextDoesNotPayFormatterConstructionPerCall() {
        let stamp = info(minutesAgo: 5)
        let iterations = 200

        // Warm: the shared formatters are lazily created on first use, and the
        // point of the test is the STEADY-STATE cost, not the one-off setup.
        _ = stamp.detailText(now: reference)

        let subject = elapsed {
            for _ in 0 ..< iterations {
                _ = stamp.detailText(now: reference)
            }
        }

        // The control is the thing the old code did once per call.
        let control = elapsed {
            for _ in 0 ..< iterations {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE d MMM yyyy, h:mm a"
                _ = formatter.string(from: self.reference)
            }
        }

        XCTAssertLessThan(
            subject,
            control / 2,
            """
            detailText cost \(subject)s for \(iterations) calls against a \
            control of \(control)s — that is the same order as building a \
            DateFormatter per call, which is CODE-COMPANION-15's stack. \
            Check BuildInfo.absoluteStampFormatter is still shared.
            """
        )
    }

    /// The >30-day branch of `relativeAge` had the same defect and the same
    /// caller, so it gets the same guarantee.
    func testLongAgoLabelDoesNotPayFormatterConstructionPerCall() {
        let old = reference.addingTimeInterval(-90 * 86_400)
        let iterations = 200

        _ = BuildInfo.relativeAge(from: old, to: reference)

        let subject = elapsed {
            for _ in 0 ..< iterations {
                _ = BuildInfo.relativeAge(from: old, to: self.reference)
            }
        }
        let control = elapsed {
            for _ in 0 ..< iterations {
                let formatter = DateFormatter()
                formatter.dateFormat = "d MMM yyyy"
                _ = formatter.string(from: old)
            }
        }

        XCTAssertLessThan(subject, control / 2)
    }

    /// The behaviour the shared formatter must not change: same text as before.
    func testSharedFormatterProducesTheSameTooltipText() {
        let stamp = info(minutesAgo: 5)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM yyyy, h:mm a"
        let expected = formatter.string(from: stamp.buildDate!)

        XCTAssertTrue(
            stamp.detailText(now: reference).contains("Built \(expected) —"),
            "the shared formatter must render exactly what the per-call one did"
        )
    }

    /// Repeated calls must agree with each other. A shared, mutated formatter
    /// would drift; a shared, never-mutated one cannot.
    func testDetailTextIsStableAcrossCalls() {
        let stamp = info(minutesAgo: 5)
        let first = stamp.detailText(now: reference)
        for _ in 0 ..< 50 {
            XCTAssertEqual(stamp.detailText(now: reference), first)
        }
    }
}
