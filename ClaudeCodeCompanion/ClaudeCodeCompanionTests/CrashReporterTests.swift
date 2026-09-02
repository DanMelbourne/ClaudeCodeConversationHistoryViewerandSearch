import XCTest
@testable import Claude_Code_Companion

final class CrashReporterTests: XCTestCase {
    // MARK: - App Hang episode grouping
    //
    // CODE-COMPANION-1 is 394 occurrences of one "App Hanging" title, and 30
    // of this project's unresolved issues are hangs. Sentry's hang report is a
    // single stack SAMPLE, so one stalled session files a new issue every few
    // minutes; read as separate bugs that is 30 wrong root causes, and it
    // buries any genuine crash. Hangs are now fingerprinted per app RUN.

    /// The invariant: two samples from ONE run group together, however
    /// different their stacks were.
    func testTwoHangsInOneRunShareOneFingerprint() {
        let first = CrashReporter.groupingFingerprint(
            mechanismType: CrashReporter.appHangMechanismType,
            releaseName: "com.danwarnemail.ClaudeCodeCompanion@1.0.62+62",
            runID: "run-A"
        )
        let second = CrashReporter.groupingFingerprint(
            mechanismType: CrashReporter.appHangMechanismType,
            releaseName: "com.danwarnemail.ClaudeCodeCompanion@1.0.62+62",
            runID: "run-A"
        )
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    /// The direction that makes the one above mean something: a constant
    /// fingerprint would also pass it, while merging every episode ever
    /// recorded into a single issue.
    func testHangsInDifferentRunsDoNotShareAFingerprint() {
        XCTAssertNotEqual(
            CrashReporter.groupingFingerprint(
                mechanismType: CrashReporter.appHangMechanismType,
                releaseName: "com.danwarnemail.ClaudeCodeCompanion@1.0.62+62",
                runID: "run-A"
            ),
            CrashReporter.groupingFingerprint(
                mechanismType: CrashReporter.appHangMechanismType,
                releaseName: "com.danwarnemail.ClaudeCodeCompanion@1.0.62+62",
                runID: "run-B"
            )
        )
    }

    /// A crash must keep Sentry's own grouping — regrouping crashes per run
    /// would hide the very report this change exists to surface.
    func testNonHangEventsKeepSentrysOwnGrouping() {
        XCTAssertNil(CrashReporter.groupingFingerprint(
            mechanismType: "NSException",
            releaseName: "r",
            runID: "run-A"
        ))
        XCTAssertNil(CrashReporter.groupingFingerprint(
            mechanismType: nil,
            releaseName: "r",
            runID: "run-A"
        ))
    }

    /// Two builds' episodes stay apart, so a fix can be seen to take effect.
    func testReleaseNameCarriesVersionAndBuild() {
        XCTAssertFalse(CrashReporter.currentReleaseName().isEmpty)
        XCTAssertNotEqual(
            CrashReporter.groupingFingerprint(
                mechanismType: CrashReporter.appHangMechanismType,
                releaseName: "app@1.0.62+62",
                runID: "run-A"
            ),
            CrashReporter.groupingFingerprint(
                mechanismType: CrashReporter.appHangMechanismType,
                releaseName: "app@1.0.63+63",
                runID: "run-A"
            )
        )
    }

    func testUnitTestDetectionRequiresXCTestEnvironmentMarker() {
        XCTAssertFalse(CrashReporter.isRunningUnitTests(environment: [:]))
        XCTAssertTrue(CrashReporter.isRunningUnitTests(environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]))
        XCTAssertTrue(CrashReporter.isRunningUnitTests(environment: ["XCTestBundlePath": "/tmp/Tests.xctest"]))
    }
}
