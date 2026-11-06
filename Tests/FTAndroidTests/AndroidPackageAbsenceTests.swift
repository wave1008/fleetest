import XCTest
@testable import FTAndroid
import FTCore

/// `pm list packages <pkg>` の結果 →「入っていない」の確定(起動失敗にクラッシュの証拠を付けない)
final class AndroidPackageAbsenceTests: XCTestCase {
    private let pkg = "com.ftester.e2ey.android"

    func testEmptyOutputIsConfirmedAbsentForExitZeroAndOne() {
        XCTAssertEqual(AndroidAppProcessEvidenceQuery.packageAbsence(status: 0, output: "", package: pkg), true)
        XCTAssertEqual(AndroidAppProcessEvidenceQuery.packageAbsence(status: 1, output: "", package: pkg), true)
    }

    func testExactPackageLineMeansInstalled() {
        XCTAssertEqual(AndroidAppProcessEvidenceQuery.packageAbsence(
            status: 0, output: "package:\(pkg)\n", package: pkg), false)
    }

    func testPrefixMatchOfAnotherPackageIsStillAbsent() {
        XCTAssertEqual(AndroidAppProcessEvidenceQuery.packageAbsence(
            status: 0, output: "package:\(pkg).debug\n", package: pkg), true)
    }

    func testAdbFailureOrUnknownOutputIsUndetermined() {
        XCTAssertNil(AndroidAppProcessEvidenceQuery.packageAbsence(status: 1, output: "error: device offline", package: pkg))
        XCTAssertNil(AndroidAppProcessEvidenceQuery.packageAbsence(status: 0, output: "something unknown", package: pkg))
        XCTAssertNil(AndroidAppProcessEvidenceQuery.packageAbsence(status: 255, output: "", package: pkg))
    }

    /// サンドボックスの中の adb は表の形だけ通る: 組み立てた形が表に載っていること(`pm path` は載っていない)
    func testQueryShapeIsAllowedBySandboxPolicyAndPmPathIsNot() {
        let context = SimctlPolicy.Context(udid: nil, deviceName: nil, toolRoots: [], childWritableRoots: [],
                                           serial: "emulator-5554", adbPath: "/parent/adb")
        XCTAssertNil(AdbPolicy.check(["-s", "emulator-5554", "shell", "pm", "list", "packages", pkg], context: context))
        XCTAssertNotNil(AdbPolicy.check(["-s", "emulator-5554", "shell", "pm", "path", pkg], context: context))
    }
}
