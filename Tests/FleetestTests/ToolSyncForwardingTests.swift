// `--align` / `--tool-rev` は**単一のリモートへのディスパッチでだけ**効き、子プロセス(マシン別サブ実行・
// リモートの子・fleet / 複数対象の子)へは渡らない。子の引数を組む経路が1本でもこの2つを運ぶと、
// 子が(ランナー上で)ランナー自身を揃えようとする・照合の手元の値が子で食い違う。
// 組み立て側のソースにこの2つのリテラルが無いことで固定する(組み立ては明示の引数からだけで、
// 利用者の argv をそのまま運ぶ経路は無い)。
//
// 断る側(単一のリモート以外)は RunRejectionParityTests と RunToolSyncScopeTests。

import XCTest
@testable import fleetest

final class ToolSyncForwardingTests: XCTestCase {
    private static let childArgumentBuilders = [
        "Sources/FTRemote/RemoteDispatch.swift",        // RemoteRunArgs.build / buildApi(ランナーの子)
        "Sources/fleetest/DeviceMachineRunner.swift",   // childArgs
        "Sources/fleetest/ApiRunMachineFanout.swift",   // buildArgs
        "Sources/fleetest/FleetRunner.swift",           // buildArgs
        "Sources/fleetest/MultiTargetRunner.swift",
    ]

    func testNoChildArgumentBuilderMentionsTheSingleRemoteOnlyFlags() throws {
        for path in Self.childArgumentBuilders {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            for flag in ["--align", "--tool-rev"] {
                XCTAssertFalse(text.contains(flag), "\(path) forwards \(flag) to a child process")
            }
        }
    }

    /// 陽性対照: 走査が実在するファイルを読めている(読めなければ throw で落ちる)うえ、
    /// フラグの宣言側には2つのリテラルがある(= 走査の語が実際の綴りと一致している)
    func testTheScanWordsMatchTheRealFlagSpelling() throws {
        let text = try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/fleetest/RunCommonOptions.swift"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("customLong(\"align\")") && text.contains("customLong(\"tool-rev\")"))
    }

    /// 単一のリモート以外へ進む経路(機械分担・手元の run)の入口で断っていること。呼び出しが1つ消えると、
    /// その経路では `--align` / `--tool-rev` が**黙って無視される**(揃えたつもりで古い中身のまま走る)。
    /// 断る文言・条件は RunToolSyncScopeTests、ここは2実装の配線だけ
    func testEveryNonSingleRemotePathRefusesTheFlagsInBothCommands() throws {
        let call = "rejectToolSyncOutsideSingleRemote()"
        let cases: [(file: String, from: String, to: String)] = [
            ("Sources/fleetest/Fleetest.swift", "DeviceMachineRunner.plan(", "DeviceMachineRunner.run("),
            ("Sources/fleetest/Fleetest.swift", "dispatchToFleet(fleet)", "PhaseLog.mark(\"start\")"),
            ("Sources/fleetest/ApiRunCommand.swift", "DeviceMachineRunner.plan(", "ApiRunMachineFanout.run("),
            ("Sources/fleetest/ApiRunCommand.swift", "dispatchToRemoteHost(dispatch, project: testProject)",
             "\n        if !dryRun {"),
        ]
        for (file, from, to) in cases {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(file), encoding: .utf8)
            let start = try XCTUnwrap(text.range(of: from), "\(file): anchor \(from) not found")
            let end = try XCTUnwrap(text.range(of: to, range: start.upperBound..<text.endIndex),
                                    "\(file): anchor \(to) not found after \(from)")
            XCTAssertTrue(text[start.upperBound..<end.lowerBound].contains(call),
                          "\(file): the path between \(from) and \(to) must call \(call)")
        }
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
