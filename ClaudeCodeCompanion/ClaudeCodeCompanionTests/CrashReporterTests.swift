import XCTest
@testable import Claude_Code_Companion

final class CrashReporterTests: XCTestCase {
    func testUnitTestDetectionRequiresXCTestEnvironmentMarker() {
        XCTAssertFalse(CrashReporter.isRunningUnitTests(environment: [:]))
        XCTAssertTrue(CrashReporter.isRunningUnitTests(environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]))
        XCTAssertTrue(CrashReporter.isRunningUnitTests(environment: ["XCTestBundlePath": "/tmp/Tests.xctest"]))
    }
}
