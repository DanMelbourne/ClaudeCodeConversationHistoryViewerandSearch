import XCTest
@testable import Claude_Code_Companion

/// The build stamp exists to answer one question truthfully: is the window in
/// front of me the build I just made? Every test here is about not lying.
final class BuildInfoTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_800_000_000)

    private func info(
        version: String = "1.0.12",
        build: String = "12",
        minutesAgo: Double? = 0,
        dirty: Bool = false,
        configuration: String? = "Release"
    ) -> BuildInfo {
        BuildInfo(
            version: version,
            build: build,
            buildDate: minutesAgo.map { reference.addingTimeInterval(-$0 * 60) },
            sourceBranch: "main",
            sourceCommit: "abcdef0123456789",
            hasUncommittedChanges: dirty,
            configuration: configuration
        )
    }

    // MARK: - Reading the bundle

    func testReadsStampedKeysFromInfoDictionary() {
        let parsed = BuildInfo(info: [
            "CFBundleShortVersionString": "1.0.9",
            "CFBundleVersion": "9",
            "CCCBuildDate": "2026-08-04T09:15:00Z",
            "CCCBuildSourceBranch": "main",
            "CCCBuildSourceCommit": "0123456789abcdef",
            "CCCBuildDirty": true,
            "CCCBuildConfiguration": "Debug"
        ])

        XCTAssertEqual(parsed.version, "1.0.9")
        XCTAssertEqual(parsed.build, "9")
        XCTAssertEqual(parsed.sourceBranch, "main")
        XCTAssertTrue(parsed.hasUncommittedChanges)
        XCTAssertEqual(parsed.configuration, "Debug")
        XCTAssertEqual(
            parsed.buildDate,
            ISO8601DateFormatter().date(from: "2026-08-04T09:15:00Z")
        )
    }

    /// An Xcode-IDE build carries no stamp; that must read as "unknown", never
    /// as a fabricated build time.
    func testUnstampedBundleHasNoBuildAge() {
        let parsed = BuildInfo(info: [
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1"
        ])

        XCTAssertNil(parsed.buildDate)
        XCTAssertNil(parsed.builtAgoLabel(now: reference))
        XCTAssertFalse(parsed.isStale(now: reference))
        XCTAssertTrue(parsed.detailText(now: reference).contains("No build stamp"))
    }

    func testEmptyStringsAreTreatedAsMissing() {
        let parsed = BuildInfo(info: [
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "CCCBuildSourceBranch": "",
            "CCCBuildSourceCommit": ""
        ])

        XCTAssertNil(parsed.sourceBranch)
        XCTAssertNil(parsed.sourceCommit)
    }

    // MARK: - Age wording

    func testRelativeAgeAcrossUnits() {
        XCTAssertEqual(BuildInfo.relativeAge(from: reference.addingTimeInterval(-5), to: reference), "just now")
        XCTAssertEqual(BuildInfo.relativeAge(from: reference.addingTimeInterval(-60), to: reference), "1 min ago")
        XCTAssertEqual(BuildInfo.relativeAge(from: reference.addingTimeInterval(-600), to: reference), "10 min ago")
        XCTAssertEqual(BuildInfo.relativeAge(from: reference.addingTimeInterval(-5400), to: reference), "1 hour ago")
        XCTAssertEqual(BuildInfo.relativeAge(from: reference.addingTimeInterval(-3 * 3600), to: reference), "3 hours ago")
        XCTAssertEqual(BuildInfo.relativeAge(from: reference.addingTimeInterval(-90_000), to: reference), "yesterday")
        XCTAssertEqual(BuildInfo.relativeAge(from: reference.addingTimeInterval(-5 * 86_400), to: reference), "5 days ago")
        XCTAssertTrue(BuildInfo.relativeAge(from: reference.addingTimeInterval(-120 * 86_400), to: reference).hasPrefix("on "))
    }

    /// A build stamped in the future means clock skew. Say so rather than
    /// rendering a nonsense negative age.
    func testFutureBuildDateIsCalledOut() {
        XCTAssertEqual(BuildInfo.relativeAge(from: reference.addingTimeInterval(600), to: reference), "in the future")
    }

    func testVersionAndAgeLabels() {
        let stamp = info(minutesAgo: 4)
        XCTAssertEqual(stamp.versionLabel, "v1.0.12 (12)")
        XCTAssertEqual(stamp.builtAgoLabel(now: reference), "built 4 min ago")
    }

    // MARK: - Staleness

    func testFreshBuildIsNotStaleAndDayOldBuildIs() {
        XCTAssertFalse(info(minutesAgo: 30).isStale(now: reference))
        XCTAssertTrue(info(minutesAgo: 60 * 25).isStale(now: reference))
    }

    // MARK: - Detail text

    func testDetailTextNamesSourceAndUncommittedChanges() {
        let detail = info(minutesAgo: 2, dirty: true, configuration: "Debug").detailText(now: reference)

        XCTAssertTrue(detail.contains("v1.0.12 (12)"))
        XCTAssertTrue(detail.contains("main @ abcdef012345"), detail)
        XCTAssertTrue(detail.contains("uncommitted changes"), detail)
        XCTAssertTrue(detail.contains("Configuration: Debug"), detail)
    }

    func testReleaseConfigurationIsNotCalledOut() {
        let detail = info(minutesAgo: 2).detailText(now: reference)
        XCTAssertFalse(detail.contains("Configuration:"), detail)
    }

    /// The shipped app must actually carry a version — a missing key would make
    /// the footer meaningless.
    func testCurrentBundleExposesAVersion() {
        XCTAssertFalse(BuildInfo.current.version.isEmpty)
        XCTAssertFalse(BuildInfo.current.build.isEmpty)
    }
}
