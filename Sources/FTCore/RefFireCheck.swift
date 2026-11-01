import Foundation

/// **ref で指した要素を撃つ前の守りの判定を1箇所に置く**(CLI の `tap --ref` / `press --ref` / `type --ref` が呼ぶ。
/// MCP の `keyboardRefusal` / `keyboardCoverRefusal` / `preTapWarnings` / `overlapWarning` と同じ部品
/// `KeyboardOcclusion` / `PreFireGuard.keyboardCover` / `OverlayWindowOcclusion` / `TapTargetGeometry.occlusionAdvisory` を通す)。
/// 文言は呼び手ごとに持つ(CLI は英語・フラグ名で書く)。**撃つ手の入口を足したら呼ぶ**
/// (`RefFireCheckWiringTests` が CLI の経路を固定する)。
public enum RefFireCheck {

    /// 撃たずに断る形(キーを押して欄へ文字が入る・触っても当たらない)
    public enum Refusal {
        /// 中心がソフトキーボードの下(`advisory` はその事実の文)
        case underKeyboard(advisory: String)
        /// キーボードの上へせり上がったバーに覆われた・枠が細い帯に潰れた
        case keyboardCover(PreFireGuard.KeyboardCover)
    }

    public struct Result {
        public var refusal: Refusal?
        /// 撃つが別の物に当たりうるときの事実(画面の外・容器の外・覆い・オーバーレイ等)。無ければ nil
        public var advisory: String?
    }

    /// `snapshot` は撃つ直前に読んだ木、`element` はその中の対象。
    /// `allowFocused`: 入力の道具(type)で対象が既に焦点を持つなら、ドライバはタップせずに打つのでキーボードの下でも断らない
    public static func evaluate(_ element: ElementInfo, in snapshot: SnapshotResponse, isAndroid: Bool,
                                allowFocused: Bool = false) -> Result {
        let keyboard = KeyboardOcclusion.resolve(
            reported: snapshot.keyboardFrame, in: snapshot.elements, screen: snapshot.screen)
        if let advisory = keyboard.advisory(for: element), !(allowFocused && element.focused == true) {
            return Result(refusal: .underKeyboard(advisory: advisory), advisory: nil)
        }
        if let cover = PreFireGuard.keyboardCover(of: element, in: snapshot, keyboard: keyboard) {
            return Result(refusal: .keyboardCover(cover), advisory: nil)
        }
        let overlay = OverlayWindowOcclusion.resolve(reported: snapshot.overlayWindowFrames).advisory(for: element)
        let geometry = TapTargetGeometry.occlusionAdvisory(
            for: element, in: snapshot.elements, screen: snapshot.screen, isAndroid: isAndroid)
        let advisory = [overlay, geometry].compactMap { $0 }.joined(separator: "; ")
        return Result(refusal: nil, advisory: advisory.isEmpty ? nil : advisory)
    }
}
