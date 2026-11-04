// StepExecutor+TypedEchoOCR.swift
// 読み返しの後に画面の欄を OCR で確かめ、打った文字列が描かれていなければ警告の注記を付ける(赤にしない)

import Foundation

extension StepExecutor {
    /// 対象は `TypedEchoOCRCheck.shouldCheck` を通った入力だけ。読めなかった(`.unreadable`・予算切れ)ときは何も言わない
    /// (言えるのは「読めたが打った文字列が無かった」ときだけ)。
    /// **切り出しの枠は打った後に読み直した木から取る** —— 打鍵で欄が動く(キーボードの押し上げ・Flutter のスクロール)ので、
    /// 打つ前の枠では別の所を読んで誤検知する。見つからなければ確認をしない(黙る)
    func noteIfTypedTextNotDrawn(driver: AppDriver, text: String, phase: inout PhaseAccumulator) async {
        let clock = ContinuousClock()
        let start = clock.now
        guard let after = try? await driver.snapshot(bypassingCache: true),
              let frame = TypedEchoOCRCheck.typedFieldFrame(in: after, text: text) else { return }
        guard let shot = try? await judgmentScreenshot(keyboardShown: true, phase: &phase) else { return }
        let reading = await RegionText.resolveWithinBudget(expected: text, pngData: shot,
                                                           frame: frame, screen: after.screen)
        let elapsed = Self.ms(clock.now - start)
        phase.guardMs += elapsed
        phase.ocrMs += elapsed
        if case .read(readable: false, _) = reading { noteCodesThisStep.insert(.typedTextNotDrawn) }
    }
}
