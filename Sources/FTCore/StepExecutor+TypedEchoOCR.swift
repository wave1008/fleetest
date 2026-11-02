// StepExecutor+TypedEchoOCR.swift
// 読み返しの後に画面の欄を OCR で確かめ、打った文字列が描かれていなければ警告の注記を付ける(OI-40。赤にしない)

import Foundation

extension StepExecutor {
    /// 対象は `TypedEchoOCRCheck.shouldCheck` を通った入力だけ。読めなかった(`.unreadable`・予算切れ)ときは何も言わない
    /// (言えるのは「読めたが打った文字列が無かった」ときだけ)
    func noteIfTypedTextNotDrawn(element: ElementInfo, text: String, screen: FTRect,
                                 phase: inout PhaseAccumulator) async {
        let clock = ContinuousClock()
        let start = clock.now
        guard let shot = try? await judgmentScreenshot(keyboardShown: true, phase: &phase) else { return }
        let reading = await RegionText.resolveWithinBudget(expected: text, pngData: shot,
                                                           frame: element.frame, screen: screen)
        let elapsed = Self.ms(clock.now - start)
        phase.guardMs += elapsed
        phase.ocrMs += elapsed
        if case .read(readable: false, _) = reading { noteCodesThisStep.insert(.typedTextNotDrawn) }
    }
}
