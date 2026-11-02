import Foundation

/// **ref で指した要素を撃つ前の守りの判定を1箇所に置く**(CLI の `tap --ref` / `press --ref` / `type --ref` が呼ぶ。
/// MCP の `keyboardRefusal` / `keyboardCoverRefusal` / `preTapWarnings` / `overlapWarning` と同じ部品
/// `KeyboardOcclusion` / `PreFireGuard.keyboardCover` / `OverlayWindowOcclusion` / `TapTargetGeometry.occlusionAdvisory` を通す)。
/// 文言は呼び手ごとに持つ(CLI は英語・フラグ名で書く)。**撃つ手の入口を足したら呼ぶ**
/// (`RefFireGateWiringTests` が CLI の経路を固定する)。
public enum RefFireCheck {

    /// 撃たずに断る形(キーを押して欄へ文字が入る・触っても当たらない・入力欄でないものへの入力)
    public enum Refusal {
        /// 中心がソフトキーボードの下(`advisory` はその事実の文)
        case underKeyboard(advisory: String)
        /// キーボードの上へせり上がったバーに覆われた・枠が細い帯に潰れた
        case keyboardCover(PreFireGuard.KeyboardCover)
        /// type の対象が型で言い切れる非入力(ボタン等)。ドライバは先に対象をタップするので押してしまう
        /// (判定は DSL・MCP・ライブ操作と共有の `TapTargetGeometry.typeTargetVerdict`)
        case notATextField
    }

    public struct Result {
        public var refusal: Refusal?
        /// 撃つが別の物に当たりうるときの事実(画面の外・容器の外・覆い・オーバーレイ等)。無ければ nil
        public var advisory: String?
    }

    /// `snapshot` は撃つ直前に読んだ木、`element` はその中の対象。
    /// `typing`: 入力の道具(type)。対象が入力欄でなければ断り、対象が既に焦点を持つならドライバはタップせずに打つので
    /// キーボードの下・せり上がったバーの覆いでも断らない(触らないので「触っても当たらない」は理由にならない)
    public static func evaluate(_ element: ElementInfo, in snapshot: SnapshotResponse, isAndroid: Bool,
                                typing: Bool = false) -> Result {
        var containerNote: String?
        if typing {
            switch TapTargetGeometry.typeTargetVerdict(element, in: snapshot.elements) {
            case .notATextField(positively: true): return Result(refusal: .notATextField, advisory: nil)
            case .containerWithOneField(let note): containerNote = note
            case .textInput, .notATextField(positively: false): break
            }
        }
        let alreadyFocused = typing && element.focused == true
        let keyboard = KeyboardOcclusion.resolve(
            reported: snapshot.keyboardFrame, in: snapshot.elements, screen: snapshot.screen)
        if !alreadyFocused {
            if let advisory = keyboard.advisory(for: element) {
                return Result(refusal: .underKeyboard(advisory: advisory), advisory: nil)
            }
            if let cover = PreFireGuard.keyboardCover(of: element, in: snapshot, keyboard: keyboard) {
                return Result(refusal: .keyboardCover(cover), advisory: nil)
            }
        }
        let overlay = OverlayWindowOcclusion.resolve(reported: snapshot.overlayWindowFrames).advisory(for: element)
        let topBand = TapTargetGeometry.topSafeAreaAdvisory(
            for: element, safeAreaTop: snapshot.safeAreaTop, screen: snapshot.screen)
        let geometry = TapTargetGeometry.occlusionAdvisory(
            for: element, in: snapshot.elements, screen: snapshot.screen, isAndroid: isAndroid)
        // 画面の縁の丸め許容(`offscreenAdvisory` の 2pt)の内側に中心が居ると助言が出ないが、座標形は縁の外として断る
        // (`isPointOnScreen`)。ref の tap もブリッジは中心を撃つので、同じ点が座標なら断られる = 何も起きない
        let edge = geometry == nil && !TapTargetGeometry.isPointOnScreen(
            x: element.frame.centerX, y: element.frame.centerY, screen: snapshot.screen)
            ? "its centre (\(Int(element.frame.centerX)), \(Int(element.frame.centerY))) is on the edge of the visible screen"
                + " or just outside it, so this almost certainly did nothing"
            : nil
        let advisory = [overlay, topBand, geometry, edge, containerNote].compactMap { $0 }.joined(separator: "; ")
        return Result(refusal: nil, advisory: advisory.isEmpty ? nil : advisory)
    }
}
