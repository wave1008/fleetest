// PaintOrder.swift
// 「どちらが手前に描かれているか」の唯一の判定。**MCP(RefGuard)と DSL(OcclusionSuspicion)が
// 共有する** —— 別々に持つと片方だけ直したときに「同じ画面で遮蔽の判定が食い違う」が起きる。
//
// **ツリーの並び順は描画順ではない**。「後に出るほど手前」で近似できる画面が多いが、production では
// 裏返る —— Google マップは地図の chrome(FAB・ストリートビュー)を**シートより後**に出すのに、
// 描画はシートが手前。MCP 側でこれを踏み、`#mylocation_button` を無警告でタップして
// 裏の広告を押し、**Chrome が起動**した。
//
// **本物の順序はブリッジが送る**(`ElementInfo.z`。Android は `getDrawingOrder` を根から積んで
// 通し番号にする)。iOS の in-app は木の全要素が UIView のとき(UIKit・RN)だけ、ビュー階層の前順 +
// `layer.zPosition` の通し番号を送る(全か無か。SwiftUI・Compose・Flutter・WebView の DOM が混じれば全 nil)。
// 持たないブリッジ(XCUITest には描画順を読む API が無い)ではツリー順へ落ちる。

import Foundation

public enum PaintOrder {

    /// **木の z が本物の塗り順か**(手前の判定で撃ち方を変えてよいか)の唯一の判定。iOS = 全要素が z を持つ(in-app が UIKit・RN の
    /// ときだけ送る。全か無か)。Android = z は必ず来るが、自前描画(Flutter・Compose)は木の順と同じ = 塗り順ではないので、
    /// 自前描画でないと分かっているときだけ。フレームワークが分からなければ false(推測しない側)。
    /// **false の木では、手前の推測で撃ち方を変えない**(断る・替える・撃つ点をずらす・送る)—— 実際に重なっていたかは撃った後の結果で
    /// 分かり、赤になれば失敗の文言が直前の手の重なりの疑いと直し方を言う(`StepExecutor.coveredTouchHint`)。注記は出してよい
    public static func isReal(in elements: [ElementInfo], isAndroid: Bool, framework: AppUIFramework?) -> Bool {
        guard !elements.isEmpty else { return false }
        if isAndroid { return framework.map { !$0.isSelfRendered } ?? false }
        return elements.allSatisfy { $0.z != nil }
    }

    /// `candidate` が `element` より手前に描かれているか。
    ///
    /// **両方が `z` を持つときだけ z を信じる** —— 片方だけ nil の木(打ち切りや別ブリッジの混在)で
    /// 大小を比べても意味が無い。落ちる先はツリー順(`ref` は木の並びに沿って 1 から振られる)。
    public static func drawnAbove(_ candidate: ElementInfo, _ element: ElementInfo) -> Bool {
        if let candidateZ = candidate.z, let elementZ = element.z { return candidateZ > elementZ }
        return candidate.ref > element.ref
    }
}
