import Foundation

extension StepExecutor {

    /// 撃つ前に対象へ届かせた結果
    enum PreTouch {
        /// 撃ってよい。**element / snapshot は撮り直した後のもの**(撃つ前の ref は無効)
        case proceed(element: ElementInfo, snapshot: SnapshotResponse, note: String?)
        case refused(String, kind: StepFailureKind?)
    }

    /// この手が撃つ前の入口(`reachBeforeTouch`)を通るか。tap の押すだけの形は自前の経路(lift → 閉じる → 撃つ)で
    /// 同じ部品を通るので含めない。**長押し(tap の hold > 0)・doubleTap・要素から要素へのドラッグ・holdStart** が対象
    static func reachesTargetBeforeTouch(action: String, step: FlowStep) -> Bool {
        if PreFireGuard.elementTouchActions.contains(action) { return true }
        return action == "tap" && (step.duration ?? FlowStep.defaultTapHoldSeconds) > 0
    }

    /// **要素を指で触る操作の撃つ前の入口**: 容器の縁の帯に潜っていれば送って外す → キーボードで潰れた・せり上がったバーに
    /// 覆われた対象はキーボードを閉じて引き直す → なお中心がキーボードの下なら閉じてから届かせる(閉じられなければ断る)。
    /// tap と type が使う部品(`liftCoveredTarget` / `closeKeyboardWithoutSideEffects` / `reachPastKeyboard`)をそのまま通す。
    /// 覆いの判定は `PreFireGuard` + `OcclusionGeometry` の1つ。**木の並びで手前が読めない覆い**(Flutter の貼り付く見出し)は
    /// `pinnedBandCovering` の帯の推定の範囲でだけ送る(推定の外は注記に止める = 誤って断らない)
    func reachBeforeTouch(_ element: ElementInfo, in snapshot: SnapshotResponse, step: FlowStep, action: String,
                          snapshotSource: CoverLiftSnapshotSource,
                          phase: inout PhaseAccumulator) async throws -> PreTouch {
        var element = element
        var snapshot = snapshot
        var notes: [String?] = []
        if let lifted = try await liftCoveredTarget(element, in: snapshot, step: step, verb: "touching",
                                                    snapshotSource: snapshotSource, phase: &phase) {
            guard let liftedElement = lifted.element else {
                return .refused(Self.coverLiftLostMessage(step, verb: "touching")
                    + (await leftForegroundSuffix(snapshot.sessionBundleID)), kind: .notFound)
            }
            element = liftedElement
            snapshot = lifted.snapshot
            notes.append(lifted.note)
        }
        let keyboard = KeyboardOcclusion.resolve(reported: snapshot.keyboardFrame, in: snapshot.elements,
                                                 screen: snapshot.screen)
        if case .primary = snapshotSource,
           PreFireGuard.keyboardCover(of: element, in: snapshot, keyboard: keyboard) != nil,
           case .closed(let closedNote, _) = try await closeKeyboardWithoutSideEffects(step: step, phase: &phase) {
            let start = ContinuousClock().now
            let after = try await freshSnapshot(.afterOwnMove)
            phase.snapshotMs += Self.ms(ContinuousClock().now - start)
            if let (reached, _) = LocatorResolver.resolve(step: step, in: after) {
                snapshot = after
                element = reached
                notes.append(closedNote + " — the target was collapsed or covered by a bar raised above the keyboard while it was up")
            }
        }
        switch try await reachPastKeyboard(element, in: snapshot, step: step, action: "tap",
                                           snapshotSource: snapshotSource, phase: &phase) {
        case nil: break
        case .refused(let message)?: return .refused(message, kind: nil)
        case .reached(let reached, let after, let note)?:
            element = reached
            snapshot = after
            notes.append(note)
        }
        return .proceed(element: element, snapshot: snapshot,
                        note: notes.compactMap { $0 }.isEmpty ? nil : notes.compactMap { $0 }.joined(separator: " / "))
    }
}
