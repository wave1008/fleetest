// 縁をまたいだ行の寄せのドラッグは、始点が押せる行に乗るとその行の押下になることがある
// (RN の iOS の横向き: 始点 289.6 が「WebView」の行 249..297 の上で、寄せが行を押して遷移した)。
// 木は E2E-RN のホームを横向きにした実物の枠(容器 = 一覧 40..333.67)

import XCTest
@testable import FTCore

final class DragStartOffPressablesTests: XCTestCase {

    private func row(_ ref: Int, y: Double, type: String = "button") -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: "r\(ref)", label: "行\(ref)", value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 78, y: y, width: 718, height: 48), depth: 2)
    }

    /// 行 81・137・193・249・305(高さ 48・隙間 8)
    private var rnHome: [ElementInfo] { [81, 137, 193, 249, 305].enumerated().map { row($0.offset + 1, y: $0.element) } }
    private let area = FTRect(x: 62, y: 40, width: 750, height: 293.67)

    func testStartOnARowMovesIntoTheGapBetweenRows() {
        let y = TapTargetGeometry.dragStartOffPressables(
            fromY: 289.6, x: 437, distance: 54, fingerUp: true, area: area, elements: rnHome)
        XCTAssertEqual(y, 301, accuracy: 0.001, "行 249..297 と 305..353 の隙間(297 + 4)が最も近い")
    }

    /// 隙間が無い一覧(行が詰まって並ぶ)では元の始点のまま(寄せを止めない)
    func testRowsWithoutGapsKeepTheStart() {
        // 容器 40..333.67 を行 40..328 で埋め尽くす(残りの 5pt は縁から離す量 4 を引くと置けない)
        let packed = [40.0, 88, 136, 184, 232, 280].enumerated().map { row($0.offset + 1, y: $0.element) }
        XCTAssertEqual(TapTargetGeometry.dragStartOffPressables(
            fromY: 289.6, x: 437, distance: 54, fingerUp: true, area: area, elements: packed), 289.6)
    }

    /// 一覧そのものが押せる要素(容器の半分以上の高さ)は避ける対象にしない
    func testListSizedClickableIsNotAvoided() {
        // 容器 40..600 の上側 40..333.67 を占める押せる一覧(容器の半分以上)。避けると一覧の下(337.67)へずれてしまう
        let tall = FTRect(x: 62, y: 40, width: 750, height: 560)
        let whole = ElementInfo(ref: 9, type: "clickable", identifier: "list", label: nil, value: nil, placeholder: nil,
                                enabled: true, frame: area, depth: 1)
        XCTAssertEqual(TapTargetGeometry.dragStartOffPressables(
            fromY: 289.6, x: 437, distance: 54, fingerUp: true, area: tall, elements: [whole]), 289.6)
    }
}
