import XCTest
@testable import FTAndroid

/// `pm path` の結果 →「入っていない」の確定(起動失敗にクラッシュの証拠を付けない)
final class AndroidPackageAbsenceTests: XCTestCase {
    func testNonZeroWithEmptyOutputIsConfirmedAbsent() {
        XCTAssertEqual(AndroidAppProcessEvidenceQuery.packageAbsence(status: 1, output: ""), true)
    }

    func testPackageLineMeansInstalled() {
        XCTAssertEqual(AndroidAppProcessEvidenceQuery.packageAbsence(
            status: 0, output: "package:/data/app/x/base.apk\n"), false)
    }

    func testAdbFailureIsUndetermined() {
        XCTAssertNil(AndroidAppProcessEvidenceQuery.packageAbsence(status: 1, output: "error: device offline"))
        XCTAssertNil(AndroidAppProcessEvidenceQuery.packageAbsence(status: 1, output: "something unknown"))
        XCTAssertNil(AndroidAppProcessEvidenceQuery.packageAbsence(status: 0, output: ""))
    }
}
