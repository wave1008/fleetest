// BridgeRouter+Renderer.swift
// POST /renderer: 直近の /snapshot の ref の要素の「描画の出どころ」を、XCTest の非公開属性(本当のクラス名)と祖先から答える。
// 判定の表は FTCore の IOSRendererMarkers(ホストと共有)。ホストは UI フレームワークが不明のときの空打ちの判断にだけ使う。

import Foundation
import XCTest

extension BridgeRouter {

    /// 祖先をたどる上限。UIKit の木は深くても数十段で、尽きたら手前までの鎖で決める
    private static let rendererMaxDepth = 64

    private static let elementTypeAttribute = "XC_kAXXCAttributeElementType"
    private static let baseTypeAttribute = "XC_kAXXCAttributeElementBaseType"
    private static let viewControllerAttribute = "XC_kAXXCAttributeViewControllerClassName"

    /// **常に 200**(409 は `requireApp()` 専用)。控えに無い ref・期待との食い違い(古い ref)・非公開属性の失敗は
    /// `renderer` 無し = 不明。何も撃たない照会なので、断りではなく不明で返す
    func handleRenderer(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(RendererRequest.self, body)
        guard let stored = refElements[req.ref], let link = refNodeLinks[req.ref],
              !StaleRefGuard.contradicts(req.expect, stored: stored) else {
            return .json(RendererResponse(renderer: nil))
        }
        let names = [Self.elementTypeAttribute, Self.baseTypeAttribute, Self.viewControllerAttribute]
        var chain: [(className: String, viewControllerClassName: String?)] = []
        var elementBaseType: String?
        var cursor: NodeLink? = link
        while let current = cursor, chain.count < Self.rendererMaxDepth {
            guard let attributes = FTElementClassAttributes(current.node as AnyObject, names),
                  let className = attributes[Self.elementTypeAttribute], !className.isEmpty else {
                // 要素本人で取れなければ問い合わせの失敗(Xcode の版で変わった等)。祖先で取れなければ、そこまでの鎖で決める
                if chain.isEmpty { elementClassQueryOutcome = false }
                break
            }
            if chain.isEmpty {
                elementClassQueryOutcome = true
                elementBaseType = attributes[Self.baseTypeAttribute]
            }
            let controller = attributes[Self.viewControllerAttribute].flatMap { $0.isEmpty ? nil : $0 }
            chain.append((className: className, viewControllerClassName: controller))
            // 最も近い目印が勝つので、当たったらそれ以上の祖先は引かない
            if IOSRendererMarkers.marker(className: className, viewControllerClassName: controller) != nil { break }
            cursor = current.parent
        }
        guard !chain.isEmpty else { return .json(RendererResponse(renderer: nil)) }
        return .json(RendererResponse(renderer: IOSRendererMarkers.renderer(chain: chain, elementBaseType: elementBaseType)))
    }
}
