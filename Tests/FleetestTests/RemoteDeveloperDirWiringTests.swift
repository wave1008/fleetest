import Foundation
import XCTest

/// `checkCompatibility` が選んだ `DEVELOPER_DIR` を toolchain probe と実際の run(remoteRunCommand)の
/// **両方**が使うこと(RR-7)。別々に解決すると、照合した Xcode と実際に走る
/// Xcode が食い違う(緑のまま別の Xcode で走る沈黙の退行)。型では守れない境界(文字列合成)なので
/// ソース走査で固定する。
///
/// **`remote status` / `api remote-compat` も同じ解決を通す** —— docs は「表の TOOLCHAIN は実際の
/// ディスパッチと同じ Xcode を照合する」と約束しているので、あちらが ambient に戻ると
/// **表が ✅ のままディスパッチだけ止まる**(またはその逆)。
final class RemoteDeveloperDirWiringTests: XCTestCase {

    /// `remote status` と `api remote-compat` が共有するプローブ(`RemoteStatusProbing`)
    private static var statusSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/fleetest/RemoteCommands.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// 表(と拡張の実行前チェック)が読む toolchain は、**ディスパッチが選ぶのと同じ Xcode** から
    /// 採ること。ambient に戻すと表と実行が食い違う
    func testStatusProbeReadsTheToolchainThroughTheSameSelection() throws {
        let code = try Self.statusSource
        XCTAssertTrue(code.contains("developerDir: xcodeOutcome.developerDir"),
                      "RemoteStatusProbing.probe が解決した DEVELOPER_DIR を probe に渡していない")
        XCTAssertTrue(code.contains("xcodeSelectionRefusalReason: refusalReason"),
                      "選択の拒否が HostRow に載っていない(TOOLCHAIN が ✅ のまま通る)")
    }

    /// アラインのビルドも同じ解決(`XcodeSelection.resolve`)で選んだ Xcode を渡すこと。nil(ambient)を直に渡すと
    /// ランナーの `xcode-select` の既定でビルドし、コマンドラインツールだとビルドが落ちる(M1mini で実測)
    func testAlignBuildsThroughTheSameSelection() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/RemoteAlign.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("developerDir: alignmentDeveloperDir(hostSpec: hostSpec)"),
                      "runRemoteAlignment が選んだ Xcode をアラインのコマンドへ渡していない")
        XCTAssertTrue(code.contains("XcodeSelection.resolve(localFingerprint: ToolchainFingerprint.current()"),
                      "アラインの Xcode をディスパッチと同じ解決で選んでいない")
    }

    private static var source: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // FleetestTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // リポジトリルート
                .appendingPathComponent("Sources/fleetest/RemoteRunDispatcher.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// dispatch() / dispatchApi() の両方が checkCompatibility の戻り値(developerDir)を
    /// 捕まえていること(捕まえていなければ toolchain probe だけ使って走らない = 沈黙する退行)
    func testBothDispatchEntryPointsCaptureCheckCompatibilitysReturnValue() throws {
        let code = try Self.source
        func functionBody(_ marker: String) throws -> Substring {
            let start = try XCTUnwrap(code.range(of: marker), marker)
            let end = try XCTUnwrap(code.range(of: "\n    }\n", range: start.upperBound..<code.endIndex), marker)
            return code[start.lowerBound..<end.upperBound]
        }
        for entry in ["func dispatch(", "func dispatchApi("] {
            XCTAssertTrue(try functionBody(entry).contains("try await performDispatch("),
                          "\(entry) が共通本体を通らない = developerDir を捕まえる経路から外れる")
        }
        let shared = try functionBody("private func performDispatch(")
        // 照合はロックの前に1回 + 待機列で待った後に1回(待つ間に別の align がツールを差し替えうる)。どちらも同じ変数へ受ける
        XCTAssertEqual(shared.components(separatedBy: "var (developerDir, toolMatch) = try checkCompatibility(layout: layout)").count - 1, 1,
                       "共通本体が checkCompatibility の戻り値(developerDir)を捨てている")
        XCTAssertEqual(shared.components(separatedBy: "if waitedForLock { (developerDir, toolMatch) = try checkCompatibility(layout: layout) }").count - 1, 1,
                       "待った後の照合し直しの戻り値を run が使う developerDir へ入れていない")
        XCTAssertEqual(code.components(separatedBy: "try checkCompatibility(layout: layout)").count - 1, 2,
                       "共通本体の外に checkCompatibility の呼び出しが増えた")
    }

    /// toolchain probe は resolveXcodeSelection が解決した developerDir を使うこと
    func testToolchainProbeUsesTheResolvedDeveloperDir() throws {
        let code = try Self.source
        XCTAssertTrue(code.contains("remoteToolchainFingerprint(developerDir: developerDir)"),
                      "toolchain probe が resolveXcodeSelection の結果を使っていない")
    }

    /// 実際の run(remoteRunCommand)も同じ変数を使うこと。共通本体(dispatch/dispatchApi が共有)の
    /// runRemoteAndRelay 呼び出しと、runRemoteAndRelay 内の remoteRunCommand への中継を数える
    func testActualRunUsesTheSameDeveloperDirVariable() throws {
        let code = try Self.source
        XCTAssertEqual(code.components(separatedBy: "developerDir: developerDir, interruptFlag: interruptFlag,").count - 1, 1,
                       "共通本体が runRemoteAndRelay へ developerDir を中継していない")
        let occurrences = code.components(separatedBy: "developerDir: developerDir)").count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 2,
                                    "runRemoteAndRelay からの developerDir 中継が欠けている")
    }

    /// `.refused` は checkCompatibility の中で即座に止めること(later に埋もれさせない)
    func testRefusedOutcomeStopsInsideCheckCompatibility() throws {
        let code = try Self.source
        XCTAssertTrue(code.contains("if case .refused(let reason) = xcodeOutcome {"),
                      "refused の分岐が見当たらない")
        guard let refusedRange = code.range(of: "if case .refused(let reason) = xcodeOutcome {"),
              let toolchainProbeRange = code.range(of: "let toolchainProbe = probeRemote(\"toolchain\")") else {
            return XCTFail("expected markers missing")
        }
        XCTAssertTrue(refusedRange.lowerBound < toolchainProbeRange.lowerBound,
                      "refused の判定が toolchain probe より後ろにある(先に止めるべき)")
    }
}
