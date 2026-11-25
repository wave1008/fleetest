// 探索の失敗文の回ごとの記録に、その回で動いた量と容器の高さを添える(前の回と重なっていたか = 飛び越しの有無を後から読む測る口)。
// witness: Google マップの場所シートで無いものを探して 38 秒(送り5本 + 逆走査5本)。記録が無く、飛び越しがあったかを言えなかった

import XCTest
@testable import FTCore

final class ScrollSearchTravelTraceTests: XCTestCase {

    /// 読むたびに一覧の行が 50 ずつ上へ動く(`shift` = 読みの番号)。`sameIDs` が false なら行は毎回別の id・容器は id 無し(共通要素が無い)
    private func screens(sameIDs: Bool, pinnedHeaders: Int = 0) -> [[ElementInfo]] {
        (0..<30).map { shift in
            var elements = [ElementInfo(ref: 1, type: "collectionView", identifier: sameIDs ? "list" : nil, label: nil, value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 0, y: 100, width: 400, height: 300), depth: 0, scrollable: true)]
            for row in 0..<12 {
                let y = 100 + Double(row) * 50 - Double(shift) * 50
                elements.append(ElementInfo(ref: 10 + row, type: "staticText",
                                            identifier: sameIDs ? "row_\(row)" : "row_\(shift)_\(row)",
                                            label: "行\(row)", value: nil, placeholder: nil, enabled: true,
                                            frame: FTRect(x: 0, y: y, width: 400, height: 40), depth: 1))
            }
            // 動かない id 付きの見出し(場所シートのタブ等)。中身が動いても、これが多いと全要素の中央値は 0 になる
            for header in 0..<pinnedHeaders {
                elements.append(ElementInfo(ref: 100 + header, type: "button", identifier: "tab_\(header)", label: "タブ\(header)",
                                            value: nil, placeholder: nil, enabled: true,
                                            frame: FTRect(x: Double(header) * 20, y: 100, width: 20, height: 30), depth: 1))
            }
            return elements
        }
    }

    private func failureMessage(sameIDs: Bool, pinnedHeaders: Int = 0) async -> String {
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"), direction: "up", maxSwipes: 2)
        // 共通要素の無い形は容器にも id が無い(動かない容器の id が共通だと 0 と測る)ので、名指しせず画面の高さが基準
        if sameIDs { step.scrollFrame = FlowLocator(id: "list") }
        let driver = FakeAppDriver(name: "d", log: CallLog(), snapshotElements: screens(sameIDs: sameIDs, pinnedHeaders: pinnedHeaders))
        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables(),
                                         uiFramework: .androidView).execute(step)
        guard case .failed(let message) = outcome.status else { XCTFail("\(outcome.status)"); return "" }
        return message
    }

    func testEachRoundSaysHowFarItMovedAgainstTheContainer() async {
        let message = await failureMessage(sameIDs: true)
        XCTAssertNotNil(message.range(of: #"round 1: not in the tree \(moved [1-9][0-9]* of 300, content went up\)"#, options: .regularExpression),
                        message)
    }

    /// 向きは中身が動いた向き(行が上へ動いた = 一覧は先へ送られた)。上向きの探索なのに `up` と出れば、払いが逆へ効いた
    func testContentDirectionFollowsTheSignOfTheTravel() {
        func snap(_ y: Double) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800), elements: [
                ElementInfo(ref: 1, type: "staticText", identifier: "row", label: nil, value: nil, placeholder: nil,
                            enabled: true, frame: FTRect(x: 0, y: y, width: 400, height: 40), depth: 0),
                ElementInfo(ref: 2, type: "button", identifier: "pinned", label: nil, value: nil, placeholder: nil,
                            enabled: true, frame: FTRect(x: 0, y: 0, width: 40, height: 40), depth: 0),
            ], truncatedCount: 0)
        }
        XCTAssertEqual(StepExecutor.measuredContentDirection(before: snap(300), after: snap(200), vertical: true), "up")
        XCTAssertEqual(StepExecutor.measuredContentDirection(before: snap(200), after: snap(300), vertical: true), "down")
        XCTAssertNil(StepExecutor.measuredContentDirection(before: snap(200), after: snap(200), vertical: true))
    }

    func testARoundWithNothingInCommonSaysTheTravelIsUnknown() async {
        let message = await failureMessage(sameIDs: false)
        XCTAssertTrue(message.contains("(moved ? of 800 — no element in common with the previous read)"), message)
    }

    func testPinnedHeadersDoNotHideTheTravelOfTheRows() async {
        let message = await failureMessage(sameIDs: true, pinnedHeaders: 20)
        XCTAssertNotNil(message.range(of: #"round 1: not in the tree \(moved [1-9][0-9]* of 300, content went up\)"#, options: .regularExpression),
                        message)
    }

    /// 何も動かない画面: 動かなかった払いは同じ回の番号で払い直し、唯一の容器の中でも1本払う。どの払いも記録に残し、
    /// 失敗文の本数と round 0(払う前の読み)より後の記録の数が一致する
    func testEverySwipeTheMessageCountsHasATraceEntry() async throws {
        let still = Array(repeating: screens(sameIDs: true)[0], count: 30)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "missing"), direction: "up")
        let driver = FakeAppDriver(name: "d", log: CallLog(), snapshotElements: still)
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables(),
                                         uiFramework: .swiftUI).execute(step)
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        let count = try XCTUnwrap(message.range(of: #"after (\d+) scroll"#, options: .regularExpression)
            .map { Int(message[$0].split(separator: " ")[1])! })
        let trace = try XCTUnwrap(message.components(separatedBy: "[search: ").last?.dropLast())
        let entries = trace.components(separatedBy: "; ")
        XCTAssertGreaterThan(count, 1, message)
        XCTAssertEqual(entries.count - 1, count, message)
    }

    /// 上限を超えた記録は round 0 と後ろを残し、省いた数を言う
    func testBoundedTraceKeepsRoundZero() {
        let trace = (0..<20).map { "round \($0)" }
        let bounded = StepExecutor.boundedTrace(trace)
        XCTAssertEqual(bounded.first, "round 0")
        XCTAssertEqual(bounded[1], "… 4 more")
        XCTAssertEqual(bounded.last, "round 19")
        XCTAssertEqual(bounded.count, StepExecutor.searchTraceLimit + 1)
        XCTAssertEqual(StepExecutor.boundedTrace(Array(trace.prefix(16))), Array(trace.prefix(16)))
    }
}
