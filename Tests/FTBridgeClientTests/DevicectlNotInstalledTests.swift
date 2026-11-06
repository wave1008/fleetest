import XCTest
@testable import FTBridgeClient

final class DevicectlNotInstalledTests: XCTestCase {
    private let nested = """
    Some stderr line
    {
      "error" : { "domain" : "com.apple.dt.CoreDeviceError", "code" : 7000,
        "userInfo" : { "NSUnderlyingError" : { "error" : { "domain" : "ContainerLookupErrorDomain", "code" : -1 } } } },
      "info" : { "outcome" : "failed" }
    }
    """

    func testContainerLookupDomainIsReadFromNestedError() {
        XCTAssertTrue(DevicectlErrorDomains.indicatesNotInstalled(nested))
    }

    func testErrorSignatureFieldIsReadToo() {
        let json = #"{"errorSignature":"(com.apple.dt.CoreDeviceError 7000 (ContainerLookupErrorDomain -1))"}"#
        XCTAssertTrue(DevicectlErrorDomains.indicatesNotInstalled(json))
    }

    func testOtherDomainOrUnreadableOutputIsNotNamed() {
        XCTAssertFalse(DevicectlErrorDomains.indicatesNotInstalled(#"{"error":{"domain":"com.apple.dt.CoreDeviceError","code":1}}"#))
        XCTAssertFalse(DevicectlErrorDomains.indicatesNotInstalled("ContainerLookupErrorDomain but not json"))
        XCTAssertFalse(DevicectlErrorDomains.indicatesNotInstalled(""))
    }

    func testCopyFailureClassification() {
        guard case .appNotInstalled = InAppLauncher.copyFailure("m", output: nested) else { return XCTFail("not installed expected") }
        guard case .launchFailed = InAppLauncher.copyFailure("m", output: "{}") else { return XCTFail("launchFailed expected") }
    }
}
