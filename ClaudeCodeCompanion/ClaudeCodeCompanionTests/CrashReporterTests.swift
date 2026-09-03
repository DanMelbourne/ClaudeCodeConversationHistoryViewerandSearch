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
            runID: "run-A",
            episode: 0
        )
        let second = CrashReporter.groupingFingerprint(
            mechanismType: CrashReporter.appHangMechanismType,
            releaseName: "com.danwarnemail.ClaudeCodeCompanion@1.0.62+62",
            runID: "run-A",
            episode: 0
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
                runID: "run-A",
                episode: 0
            ),
            CrashReporter.groupingFingerprint(
                mechanismType: CrashReporter.appHangMechanismType,
                releaseName: "com.danwarnemail.ClaudeCodeCompanion@1.0.62+62",
                runID: "run-B",
                episode: 0
            )
        )
    }

    /// A crash must keep Sentry's own grouping — regrouping crashes per run
    /// would hide the very report this change exists to surface.
    func testNonHangEventsKeepSentrysOwnGrouping() {
        XCTAssertNil(CrashReporter.groupingFingerprint(
            mechanismType: "NSException",
            releaseName: "r",
            runID: "run-A",
            episode: 0
        ))
        XCTAssertNil(CrashReporter.groupingFingerprint(
            mechanismType: nil,
            releaseName: "r",
            runID: "run-A",
            episode: 0
        ))
    }

    /// Two builds' episodes stay apart, so a fix can be seen to take effect.
    func testReleaseNameCarriesVersionAndBuild() {
        XCTAssertFalse(CrashReporter.currentReleaseName().isEmpty)
        XCTAssertNotEqual(
            CrashReporter.groupingFingerprint(
                mechanismType: CrashReporter.appHangMechanismType,
                releaseName: "app@1.0.62+62",
                runID: "run-A",
                episode: 0
            ),
            CrashReporter.groupingFingerprint(
                mechanismType: CrashReporter.appHangMechanismType,
                releaseName: "app@1.0.63+63",
                runID: "run-A",
                episode: 0
            )
        )
    }


    /// The defect the first version shipped, caught in review: this app stays
    /// open for days, so fingerprinting per RUN merged a day of unrelated
    /// stalls into one issue — the opposite failure to over-splitting, and it
    /// hides root causes just as effectively.
    func testHangsFarApartInOneRunAreDifferentEpisodes() {
        let first = Date(timeIntervalSince1970: 1_000_000)
        let later = first.addingTimeInterval(CrashReporter.hangEpisodeGap + 1)
        XCTAssertEqual(
            CrashReporter.episodeIndex(previousHangAt: first, currentIndex: 0, now: later),
            1
        )
    }

    /// The half that must survive that change: samples of ONE stall, about a
    /// minute apart in the measured data, still collapse into one episode.
    func testSamplesOfOneStallStayInOneEpisode() {
        let first = Date(timeIntervalSince1970: 1_000_000)
        var index = 0
        var previous: Date?
        for step in 0 ..< 9 {
            let now = first.addingTimeInterval(Double(step) * 60)
            index = CrashReporter.episodeIndex(previousHangAt: previous, currentIndex: index, now: now)
            previous = now
        }
        XCTAssertEqual(index, 0, "Nine samples a minute apart are one episode, not nine")
    }

    /// A clock correction mid-session must not glue two episodes together.
    func testClockGoingBackwardsStartsANewEpisode() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            CrashReporter.episodeIndex(
                previousHangAt: now.addingTimeInterval(3600),
                currentIndex: 4,
                now: now
            ),
            5
        )
    }

    func testUnitTestDetectionRequiresXCTestEnvironmentMarker() {
        XCTAssertFalse(CrashReporter.isRunningUnitTests(environment: [:]))
        XCTAssertTrue(CrashReporter.isRunningUnitTests(environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]))
        XCTAssertTrue(CrashReporter.isRunningUnitTests(environment: ["XCTestBundlePath": "/tmp/Tests.xctest"]))
    }
}
