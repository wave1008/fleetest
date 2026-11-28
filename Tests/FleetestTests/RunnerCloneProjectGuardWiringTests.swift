import Foundation
import XCTest

/// `RunnerCloneProjectCheck` の呼び手(`run` / `api run` / `DeviceRosterLoad` / ApiDeviceOperation)と、
/// 印を書く側(align の全経路)の配線をソース走査で固定する。片方の入口だけ外れると、その経路だけ緑のまま通る
final class RunnerCloneProjectGuardWiringTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testRunAndApiRunCallTheGuardAndSkipDryRun() throws {
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let code = try source(path)
            XCTAssertEqual(code.components(separatedBy: "RunnerCloneProjectCheck.rejectIfRunnerClone").count - 1, 1,
                           "\(path) がランナーのクローンの検査を1回呼んでいない")
            XCTAssertTrue(code.contains("if !dryRun {\n            try RunnerCloneProjectCheck")
                          || code.contains("if !dryRun { try RunnerCloneProjectCheck"),
                          "\(path): 検査は dry-run を除いた分岐の中")
            // `--runner local` の明示は通す(Scripts/e2ex.sh・e2ey.sh の --on がランナーのクローンの中で回す運用)
            XCTAssertTrue(code.contains("explicitLocalRunner: MachineDispatch.isExplicitLocal(runner)"),
                          "\(path): --runner local の明示を検査へ渡していない")
        }
    }

    func testDeviceCommandsHaveNoRunnerExemption() throws {
        // デバイスの操作には --runner が無い = 明示の local で通す口を持たない
        for path in ["Sources/fleetest/DevicesCommand.swift", "Sources/fleetest/ApiDeviceCommands.swift"] {
            let code = try source(path)
            XCTAssertTrue(code.contains("explicitLocalRunner: false"), path)
            XCTAssertFalse(code.contains("explicitLocalRunner: true"), path)
        }
    }

    func testDeviceRosterLoadAndDeviceOperationCallTheGuard() throws {
        let roster = try source("Sources/fleetest/DevicesCommand.swift")
        XCTAssertTrue(roster.contains("if touchesDevices {\n            try RunnerCloneProjectCheck.rejectIfRunnerClone"))
        let operation = try source("Sources/fleetest/ApiDeviceCommands.swift")
        XCTAssertTrue(operation.contains("try RunnerCloneProjectCheck.rejectIfRunnerClone"))
    }

    func testOnlyObservationOnlyCallersOptOut() throws {
        // touchesDevices: false は配信(観測だけ)の1箇所だけ。他の呼び手が外れたら落ちる
        var optOuts: [String] = []
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
            let code = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            if code.contains("touchesDevices: false") { optOuts.append(name) }
        }
        XCTAssertEqual(optOuts, ["ApiDeviceStreamCommand.swift"])
    }

    func testAlignWritesTheMarkerOnEveryPath() throws {
        let align = try source("Sources/fleetest/RemoteAlign.swift")
        XCTAssertEqual(align.components(separatedBy: "writeRunnerCloneMarker(hostSpec: hostSpec, layout: layout").count - 1, 2,
                       "sendAndBuildAlignment の成功と execute の「揃っている」の2箇所")
        XCTAssertTrue(align.contains("if status == 0 { writeRunnerCloneMarker"))
        let setup = try source("Sources/fleetest/RemoteSetupCommand.swift")
        XCTAssertTrue(setup.contains("writeRunnerCloneMarker(hostSpec: hostSpec, layout: layout)"),
                      "remote setup の「揃っている」分岐が印を書いていない")
    }
}
