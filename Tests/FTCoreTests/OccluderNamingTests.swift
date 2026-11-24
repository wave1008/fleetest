// 覆いの名指しの可否(`OccluderNaming`)と、描いた文字を説明に入れる作りか(`DescriptionHoldsDrawnText`)。

import XCTest
@testable import FTCore

final class OccluderNamingTests: XCTestCase {
    private func el(_ ref: Int, _ id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                    overlay: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: "clickable", identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: 2,
                    inOverlayWindow: overlay)
    }

    private let frameworks: [AppUIFramework?] = [nil, .flutter, .compose, .androidView, .reactNative]

    /// 偽になるのは Android・Flutter・同じウィンドウの組だけ(それ以外の全組合せは真)
    func testTruthTable() {
        for isAndroid in [false, true] {
            for framework in frameworks {
                for (o, t) in [(nil, nil), (true, true), (true, nil), (nil, true), (false, nil)] as [(Bool?, Bool?)] {
                    let sameWindow = (o == true) == (t == true)
                    let expected = !(isAndroid && framework == .flutter && sameWindow)
                    XCTAssertEqual(
                        OccluderNaming.mayName(occluder: el(1, "o", 0, 0, 1, 1, overlay: o),
                                               target: el(2, "t", 0, 0, 1, 1, overlay: t),
                                               isAndroid: isAndroid, framework: framework),
                        expected, "android=\(isAndroid) fw=\(String(describing: framework)) o=\(String(describing: o)) t=\(String(describing: t))")
                }
            }
        }
    }

    func testAlwaysNameNeverSuppresses() {
        let a = el(1, "a", 0, 0, 1, 1), b = el(2, "b", 0, 0, 1, 1)
        XCTAssertTrue(OccluderNamingContext.alwaysName.mayName(a, b))
    }

    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)

    /// 実測形(nav_heal / tab_controls)。Android の Flutter の同じウィンドウでは overlayCovering の段だけ飛ばし、抑止を報告する
    func testAdvisoryKindSkipsOnlyTheOverlayStageForFlutter() {
        let target = el(1, "nav_heal", 16, 788, 370, 62)
        let overlay = el(2, "tab_controls", 134, 778, 134, 62)
        let tree = [target, overlay]
        let flutter = OccluderNamingContext(isAndroid: true, framework: .flutter)

        let named = TapTargetGeometry.advisoryKindResult(for: target, in: tree, screen: screen, naming: .alwaysName)
        guard case .overlayCovering? = named.kind else { return XCTFail("前提: 幾何は覆いと読む") }
        XCTAssertFalse(named.namingSuppressed)

        let suppressed = TapTargetGeometry.advisoryKindResult(for: target, in: tree, screen: screen, naming: flutter)
        if case .overlayCovering? = suppressed.kind { XCTFail("名指さない組で overlayCovering を返した") }
        XCTAssertTrue(suppressed.namingSuppressed)

        let text = TapTargetGeometry.occlusionAdvisoryResult(for: target, in: tree, screen: screen,
                                                             isAndroid: true, framework: .flutter)
        XCTAssertNil(text.text)
        XCTAssertTrue(text.namingSuppressed)
        let compose = TapTargetGeometry.occlusionAdvisoryResult(for: target, in: tree, screen: screen,
                                                                isAndroid: true, framework: .compose)
        XCTAssertTrue(compose.text?.contains("#tab_controls") == true)
        XCTAssertFalse(compose.namingSuppressed)
    }

    func testDescriptionHoldsDrawnTextAnswers() {
        let e = el(1, "x", 0, 0, 1, 1)
        XCTAssertNil(DescriptionHoldsDrawnText.answer(element: e, framework: nil))
        XCTAssertEqual(DescriptionHoldsDrawnText.answer(element: e, framework: .flutter), true)
        for fw in [AppUIFramework.compose, .androidView, .reactNative] {
            XCTAssertEqual(DescriptionHoldsDrawnText.answer(element: e, framework: fw), false)
        }
    }

    private func decl(_ renderer: String?, host: Int? = nil) -> ElementInfo {
        ElementInfo(ref: 1, type: "clickable", identifier: "x", label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: 0, width: 1, height: 1), depth: 2,
                    renderer: renderer, renderHost: host)
    }

    private func may(_ o: ElementInfo, _ t: ElementInfo, _ fw: AppUIFramework? = nil) -> Bool {
        OccluderNaming.mayName(occluder: o, target: t, isAndroid: true, framework: fw)
    }

    func testDeclaredBranchTruthTable() {
        XCTAssertFalse(may(decl("virtual", host: 5), decl("virtual", host: 5)))
        XCTAssertTrue(may(decl("virtual", host: 5), decl("virtual", host: 6)))
        XCTAssertTrue(may(decl("view"), decl("virtual", host: 5)))
        XCTAssertTrue(may(decl("virtual", host: 5), decl("view")))
        XCTAssertTrue(may(decl("compose"), decl("compose")))
        XCTAssertTrue(may(decl("web"), decl("web")))
        // 申告が決める: Flutter のアプリでも view どうし・view+virtual は名指す
        XCTAssertTrue(may(decl("view"), decl("view"), .flutter))
        XCTAssertTrue(may(decl("view"), decl("virtual", host: 5), .flutter))
        XCTAssertTrue(may(decl("virtual", host: 5), decl("virtual", host: 6), .flutter))
        XCTAssertFalse(may(decl("virtual", host: 5), decl("virtual", host: 5), nil))
    }

    func testDeclaredBranchFallsBackToAppWhenUndeclaredOrHostMissing() {
        // renderHost が片方でも欠けた virtual 同士 = 申告の無い組 → アプリの枝
        XCTAssertFalse(may(decl("virtual", host: 5), decl("virtual"), .flutter))
        XCTAssertTrue(may(decl("virtual", host: 5), decl("virtual"), .androidView))
        XCTAssertTrue(may(decl("virtual", host: 5), decl("virtual"), nil))
        // renderer が片方でも nil = アプリの枝
        XCTAssertFalse(may(decl(nil), decl("virtual", host: 5), .flutter))
        XCTAssertTrue(may(decl("view"), decl(nil), .compose))
        XCTAssertFalse(may(decl("view"), decl(nil), .flutter))
        // iOS には効かない
        XCTAssertTrue(OccluderNaming.mayName(occluder: decl("virtual", host: 5), target: decl("virtual", host: 5),
                                             isAndroid: false, framework: nil))
    }

    func testDescriptionHoldsDrawnTextDeclared() {
        for r in ["view", "compose"] {
            XCTAssertEqual(DescriptionHoldsDrawnText.answer(element: decl(r), framework: nil), false)
            XCTAssertEqual(DescriptionHoldsDrawnText.answer(element: decl(r), framework: .flutter), false)
        }
        for r in ["web", "virtual", nil] as [String?] {
            XCTAssertNil(DescriptionHoldsDrawnText.answer(element: decl(r), framework: nil))
            XCTAssertEqual(DescriptionHoldsDrawnText.answer(element: decl(r), framework: .flutter), true)
            XCTAssertEqual(DescriptionHoldsDrawnText.answer(element: decl(r), framework: .compose), false)
        }
    }

    func testContainsCompose() {
        XCTAssertFalse(ElementRenderer.containsCompose([]))
        XCTAssertFalse(ElementRenderer.containsCompose([decl("view"), decl("virtual", host: 1), decl(nil)]))
        XCTAssertTrue(ElementRenderer.containsCompose([decl("view"), decl("compose")]))
    }

    func testRendererJSONDecode() throws {
        let base = #"{"ref":1,"type":"button","enabled":true,"frame":{"x":0,"y":0,"width":1,"height":1},"depth":2"#
        let with = try JSONDecoder().decode(ElementInfo.self, from: Data((base + #","renderer":"virtual","renderHost":9}"#).utf8))
        XCTAssertEqual(with.renderer, "virtual")
        XCTAssertEqual(with.renderHost, 9)
        let without = try JSONDecoder().decode(ElementInfo.self, from: Data((base + "}").utf8))
        XCTAssertNil(without.renderer)
        XCTAssertNil(without.renderHost)
    }

    func testStepNoteIsRegistered() {
        XCTAssertEqual(StepNote.occluderNamingSuppressed.rawValue, "occluder-naming-suppressed")
        XCTAssertFalse(StepNote.occluderNamingSuppressed.text.isEmpty)
    }
}
