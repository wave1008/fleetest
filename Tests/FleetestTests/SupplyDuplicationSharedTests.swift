// run(prepareSupply)と api run が共有する供給の先頭の2行と lease 保持者。違い(出力先・順序)は呼び手に残す

import XCTest
@testable import fleetest

final class SupplyDuplicationSharedTests: XCTestCase {
    private static func code(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSupplyLeaseHolderIsNilOutsideTheRepo() {
        XCTAssertNil(ProfileRunner.supplyLeaseHolder(repoRoot: nil))
    }

    /// 2経路とも共有の関数を通し、行の文言を各自で組み直さない(片方だけ変わると供給の見出しが割れる)
    func testBothPathsUseTheSharedHelpers() throws {
        let api = try Self.code("Sources/fleetest/ApiRunCommand.swift")
        let supply = try Self.code("Sources/fleetest/ProfileRunner+Supply.swift")
        XCTAssertTrue(api.contains("ProfileRunner.supplyHeaderLines("))
        XCTAssertTrue(supply.contains("supplyHeaderLines(profileName: profileName"))
        XCTAssertFalse(api.contains("\"🧩 Profile"), "api run が見出しを自前で組み直している")
        XCTAssertEqual(api.components(separatedBy: "ProfileRunner.supplyLeaseHolder(").count - 1, 2)
        XCTAssertFalse(api.contains("SupplyLeaseHolder(stateDir:"))
        XCTAssertTrue(supply.contains("supplyLeaseHolder(repoRoot: repoRoot)"))
    }
}
