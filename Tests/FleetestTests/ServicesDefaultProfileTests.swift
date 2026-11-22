// `fleetest services` の `--profile` 省略時の選び方(`ServicesCommand.defaultProfile`)。
// サービスは作業フォルダごとなので、全プロファイルが同じ作業フォルダのときだけ省略を許す。

import XCTest
@testable import fleetest

final class ServicesDefaultProfileTests: XCTestCase {

    private struct Broken: LocalizedError { var errorDescription: String? { "bad json" } }

    private func choose(_ table: [String: Result<String, Error>]) -> Result<String, Error> {
        Result { try ServicesCommand.defaultProfile(names: table.keys.sorted()) { table[$0]! } }
    }

    func testSameWorkspacePicksTheFirstName() throws {
        let picked = try choose(["ios-run": .success("/w"), "android-run": .success("/w")]).get()
        XCTAssertEqual(picked, "android-run")
        XCTAssertEqual(try choose(["only": .success("/w")]).get(), "only")
    }

    func testDifferentWorkspacesAreRefusedWithTheirPaths() {
        let result = choose(["a": .success("/w1"), "b": .success("/w2")])
        XCTAssertThrowsError(try result.get()) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("--profile is required (available: a, b)"), text)
            XCTAssertTrue(text.contains("different workspaces (a: /w1, b: /w2)"), text)
        }
    }

    /// 1つでも解決できなければ「同じ」と言えないので選ばない(壊れていない側へ黙って倒さない)
    func testUnresolvableProfileIsRefused() {
        let result = choose(["a": .success("/w"), "b": .failure(Broken())])
        XCTAssertThrowsError(try result.get()) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("--profile is required"), text)
            XCTAssertTrue(text.contains("cannot resolve run profile b"), text)
            XCTAssertTrue(text.contains("bad json"), text)
        }
    }
}
