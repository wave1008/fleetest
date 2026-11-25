import Foundation
import XCTest
@testable import fleetest

/// live serve の command watchdog は「進まない時間」を測る。観測の各段(前面追従・screenshot・snapshot・
/// springboard 退避・失敗の注記)は個別に期限があるので、段の手前で窓を張り直す
/// (`ResidentProcessGuard.noteCommandProgress`)。命令全体を1本の窓で数えると、劣化したランナー
/// (AX の1問に 20 秒超)で進んでいるのに serve ごと強制終了する(MN-68.1)。
/// ①張り直しの意味(アイドル中は何もしない)②観測の段の手前に張り直しがあることをソース走査で固定する。
/// ②は ApiLiveCommand.swift の全関数の `await driver.` / `await annotated(` を走査し、直前が張り直しでない箇所は
/// 理由付きの許可表(operationStageExemptions)に無ければ落ちる(新しい段・新しい関数の足し忘れを拾う)。
final class LiveWatchdogProgressScanTests: XCTestCase {

    // MARK: - 張り直しの意味

    func testProgressRestartsTheWindowOnlyWhileACommandIsActive() throws {
        ResidentProcessGuard.noteCommandEnd()
        ResidentProcessGuard.noteCommandProgress()
        XCTAssertNil(ResidentProcessGuard.commandStartedAtForTesting, "アイドル中に窓を開けてはいけない")

        ResidentProcessGuard.noteCommandStart(allowanceSeconds: 0)
        let started = try XCTUnwrap(ResidentProcessGuard.commandStartedAtForTesting)
        Thread.sleep(forTimeInterval: 0.01)
        ResidentProcessGuard.noteCommandProgress()
        let restarted = try XCTUnwrap(ResidentProcessGuard.commandStartedAtForTesting)
        XCTAssertGreaterThan(restarted.uptimeNanoseconds, started.uptimeNanoseconds)
        ResidentProcessGuard.noteCommandEnd()
    }

    // MARK: - ソース走査

    private static var source: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
    }

    /// コメントを落とし、空行を除いた行
    private static func codeLines() throws -> [String] {
        try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//")[0] }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// `name` の本体(次の宣言の手前まで)
    private static func body(of name: String, in lines: [String]) throws -> [String] {
        let start = try XCTUnwrap(lines.firstIndex { $0.contains("func \(name)(") }, "\(name) が見つからない")
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("    private func ") || $0.hasPrefix("    func ")
            || $0.hasPrefix("    static func ") || $0.hasPrefix("    private static func ") } ?? lines.endIndex
        return Array(lines[start..<end])
    }

    func testFollowGoesThroughTheHelperOnly() throws {
        let lines = try Self.codeLines()
        XCTAssertFalse(lines.contains { $0.contains("follower?.follow(") },
                       "前面追従は followFrontmost を通す(窓の張り直しが漏れる)")
        XCTAssertEqual(lines.filter { $0.contains(".follow(driver:") }.count, 1)
        let helper = try Self.body(of: "followFrontmost", in: lines)
        XCTAssertEqual(helper.filter { $0.contains("noteCommandProgress()") }.count, 2)
    }

    /// 直前の行が張り直しでなくてよい `await driver.` / `await annotated(`。キーは「所有する関数名: 行に含まれる文字列」。
    /// 操作の段は `watchdogWindowAllowanceSeconds` の猶予で守られ、観測の段(前面追従・screenshot・snapshot・
    /// springboard 退避・失敗の注記)だけが手前で窓を張り直す規則
    private static let operationStageExemptions: [String: String] = [
        "requireOnScreen: await driver.snapshot()": "操作の前提確認。perform の一部で操作の猶予の内側",
        "perform: await driver.": "操作そのもの(tap/type/drag/pinch/press/gesture/home 等)と、その座標検証の snapshot。操作の猶予で守る",
        "performFold: setHingeAngle": "折りたたみの送り出し。performFold 内の観測(foldObservation)の手前では張り直している",
        "performFold: continueAfterFold": "折りたたみ後の再開。操作の猶予の内側",
    ]

    /// 全関数の観測の段(`await driver.` / `await annotated(`)を走査する。許可表に載らない行は直前が張り直しであること。
    /// 許可表に載っているのに該当する行が無い(消した・直した)ときも落とす
    func testEveryAwaitInTheFileIsPrecededByProgressOrExempt() throws {
        let lines = try Self.codeLines()
        var owner = "?"
        var unmatched: [String] = []
        var usedExemptions: Set<String> = []
        var checked = 0
        for (i, line) in lines.enumerated() {
            if let range = line.range(of: #"func (\w+)\("#, options: .regularExpression) {
                owner = String(line[range].dropFirst(5).dropLast())
            }
            guard line.contains("await driver.") || line.contains("await annotated(") else { continue }
            checked += 1
            if i > 0, lines[i - 1].contains("noteCommandProgress()") { continue }
            if let key = Self.operationStageExemptions.keys.first(where: { key in
                let parts = key.components(separatedBy: ": ")
                return parts[0] == owner && line.contains(parts[1])
            }) {
                usedExemptions.insert(key)
            } else {
                unmatched.append("\(owner): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 15, "走査が観測・操作の段に届いていない")
        XCTAssertEqual(unmatched, [],
                       "観測の段の手前に ResidentProcessGuard.noteCommandProgress() が無い(窓の張り直し漏れ = 劣化したランナーで"
                       + " serve ごと強制終了)。観測の段なら直前の行へ足し、操作の段なら operationStageExemptions へ理由付きで足す")
        XCTAssertEqual(usedExemptions, Set(Self.operationStageExemptions.keys),
                       "許可表に該当する行が無い項目がある(行を消した・張り直しを足したなら表から外す)")
    }

    func testEveryObservationStepRestartsTheWindowFirst() throws {
        let lines = try Self.codeLines()
        var checked = 0
        for name in ["emitObservation", "snapshotWithSessionFallback"] {
            let body = try Self.body(of: name, in: lines)
            for (i, line) in body.enumerated()
            where line.contains("await driver.") || line.contains("await annotated(") {
                // 直前の行が張り直し(同じ段の中で前置きの計算を挟まない)
                let previous = i > 0 ? body[i - 1] : ""
                XCTAssertTrue(previous.contains("noteCommandProgress()"),
                              "\(name): 「\(line.trimmingCharacters(in: .whitespaces))」の手前に noteCommandProgress が無い")
                checked += 1
            }
        }
        // 走査が段に届いていること(screenshot 1・snapshot 2・launch 1・annotated 1)
        XCTAssertEqual(checked, 5)
    }
}
