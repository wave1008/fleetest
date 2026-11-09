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
            guard let (hit, _) = Self.topmostHitView(at: CGPoint(x: req.x, y: req.y)) else {
                return TouchLandsResponse(receiver: nil, lands: [], unresolved: req.refs)
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
            return TouchLandsResponse(receiver: String(describing: type(of: hit)), lands: lands, unresolved: unresolved)
        }
        return .json(answer)
    }
}
