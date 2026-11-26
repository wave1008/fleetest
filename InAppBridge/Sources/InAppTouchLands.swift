// InAppTouchLands.swift
// POST /touchlands: 点で実際にタッチを受ける view(UIKit の当たり判定 = 本物のタッチの配送先)が、各 ref の要素の view か
// その子孫か。XCUITest の isHittable は SwiftUI の隠れるバーの画面で送って戻した FAB に false を返す(本物のタッチは FAB に届く)ので、
// ホストはこの答えで「対象に届き、覆いの候補のどれにも届かない」ことを確かめる。契約は BridgeDTO の TouchLandsRequest / Response。
// 祖先方向は見ない(isReachable と違う): 根の HostingView が受けた点を、その子孫の view を持つ要素に「届く」と読まない

import UIKit

extension FTInAppBridge {

    func handleTouchLands(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(TouchLandsRequest.self, body)
        let answer: TouchLandsResponse = mainSync {
            let point = CGPoint(x: req.x, y: req.y)
            let axHit = self.axHitRef(at: point)
            guard let (hit, _) = Self.topmostHitView(at: point) else {
                return TouchLandsResponse(receiver: nil, lands: [], unresolved: req.refs, axHit: axHit)
            }
            var lands: [Int] = []
            var unresolved: [Int] = []
            for ref in req.refs {
                guard let node = self.nodes.object(forKey: NSNumber(value: ref)) as? NSObject,
                      let anchor = (node as? UIView) ?? Self.nearestView(of: node) else {
                    unresolved.append(ref)
                    continue
                }
                if hit === anchor || hit.isDescendant(of: anchor) { lands.append(ref) }
            }
            return TouchLandsResponse(receiver: String(describing: type(of: hit)), lands: lands, unresolved: unresolved, axHit: axHit)
        }
        return .json(answer)
    }

    /// 窓の非公開 `_accessibilityHitTest:withEvent:` の答えを直近の木の ref へ引く(木の要素でない・セレクタが無いは nil)。
    /// 窓の並びは `topmostHitView` と同じ(手前から、点を含む最初の窓)。答えは Compose の最小タッチ領域で枠の外の要素になりうる = 警告材料だけ
    private func axHitRef(at point: CGPoint) -> Int? {
        let selector = NSSelectorFromString("_accessibilityHitTest:withEvent:")
        for window in Self.backToFront(UIApplication.shared.windows).reversed() {
            guard !window.isHidden, window.alpha > 0.01 else { continue }
            let local = window.convert(point, from: nil)
            guard window.bounds.contains(local) else { continue }
            guard let method = class_getInstanceMethod(type(of: window), selector) else { return nil }
            typealias HitTest = @convention(c) (AnyObject, Selector, CGPoint, UIEvent?) -> AnyObject?
            let call = unsafeBitCast(method_getImplementation(method), to: HitTest.self)
            // 何も答えない窓は飛ばす(キーボードの UITextEffectsWindow は全面で手前にあり、キーの外では nil を返す = 実測)
            guard let answer = call(window, selector, local, nil) else { continue }
            let enumerator = nodes.keyEnumerator()
            while let key = enumerator.nextObject() as? NSNumber {
                if nodes.object(forKey: key) === answer { return key.intValue }
            }
            return nil
        }
        return nil
    }
}
