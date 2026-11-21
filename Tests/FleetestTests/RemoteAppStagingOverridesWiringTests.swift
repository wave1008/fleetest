// リモート送信の前にランナーへ運ぶアプリの原本は、向こうの子へ中継するのと同じ `--set` の上書きで決める。
// `declaredAppPaths(overrides:)` は既定値を持たないので渡し忘れはコンパイルで止まるが、`[:]` を渡す後退は止まらない

import XCTest

final class RemoteAppStagingOverridesWiringTests: XCTestCase {
    func testTheDispatcherStagesTheAppsWithTheRelayedOverrides() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest/RemoteRunDispatcher.swift")
        let code = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(code.contains("ProfileResolver.declaredAppPaths(project: project, runName: profile, overrides: setOverrides)"))
        XCTAssertTrue(code.contains("prepareWorkspace(project: project, profile: profile, setOverrides: setOverrides,"))
        // 入口の2つ(dispatch / dispatchApi)が中継するのと同じ上書きを共通の本体へ渡す
        XCTAssertEqual(code.components(separatedBy: "linkedToParent: workQueue || runMemoLink, setOverrides: setOverrides,").count - 1, 2)
    }
}
