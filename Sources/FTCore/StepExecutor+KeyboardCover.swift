// StepExecutor+KeyboardCover.swift
// キーボードの出現・消滅待ち(type / 欄の tap / hideKeyboard の後)と、縁の帯・キーボードに潜った対象を容器を送って外す
// liftCoveredTarget、キーボードの失敗文の節。本体は StepExecutor.swift(instance 状態はそちらに置く)

import Foundation

extension StepExecutor {
    /// Android で入力欄を叩く tap の後、次のロケータ操作の解決の前にキーボードが木に出るのを待たせる(`pendingTypeKeyboardCheck` の
    /// 出現待ちをそのまま使う)。叩いた直後の木は上がる途中のキーボードを持たず、CMP の横向きでは欄が押し出されて木から消える
    /// 直前の位置で解決され、続く type がタップ点に欄を見つけず 500 で落ちる(Emulator の横向き CMP で 1/2)。
    /// 既にキーボードが出ている・この端末で出なかったと観測済み(`keyboardKnownAbsent`)なら立てない(毎回の上限待ちを避ける)
    func armKeyboardAppearanceWaitAfterFieldTap(_ element: ElementInfo, in snapshot: SnapshotResponse) {
        guard isAndroid, !keyboardKnownAbsent, TypeReadback.isTextInput(element),
              !KeyboardWait.onScreen(snapshot.keyboardFrame, screen: snapshot.screen) else { return }
        keyboardFrameBeforeType = snapshot.keyboardFrame
        pendingTypeEndedWithNewline = false
        pendingTypeKeyboardCheck = true
        keyboardWaitFollowsFieldTap = true
    }

    /// `pendingTypeKeyboardCheck` を消化する: 直前の type の前後でキーボードが動いた(出た・出る途中・出し直しで隠れた)なら、
    /// 出きるまで待って整定を見る。ロケータ操作の解決と、ロケータを持たない `back()`(`awaitKeyboardBeforeBack`)・`hideKeyboard` が呼ぶ
    /// —— back() が待たずに撃つと、上がってくる途中のキーボードの前に戻るが届き、横取りの確認ダイアログが出ない
    /// (E2EY-iOS の XCUITest の戻るの横取り S0040)
    func consumePendingTypeKeyboardCheck(_ snapshot: SnapshotResponse,
                                         phase: inout PhaseAccumulator) async throws -> SnapshotResponse {
        guard pendingTypeKeyboardCheck else { return snapshot }
        let clock = ContinuousClock()
        var snapshot = snapshot
        pendingTypeKeyboardCheck = false
        let followsFieldTap = keyboardWaitFollowsFieldTap
        keyboardWaitFollowsFieldTap = false
        keyboardWaitExhausted = false
        // 出し直しの途中で隠れているなら、戻るまで待ってから整定を見る(keyboardHiddenAfterType の doc)。
        // 上限は焦点待ちの共有値(戻らなければ正当に閉じたと見てそのまま進む)
        // 戻りを待った回は、戻った位置が打つ前と同じでも中身はこれから動くので必ず整定を見る
        let waitedForKeyboard = Self.keyboardHiddenAfterType(
            before: keyboardFrameBeforeType, after: snapshot.keyboardFrame,
            screen: snapshot.screen, typedNewline: pendingTypeEndedWithNewline)
        if waitedForKeyboard {
            let deadline = clock.now + .milliseconds(Int(FocusWait.waitSeconds * 1000))
            while clock.now < deadline,
                  !Self.keyboardOnScreen(snapshot.keyboardFrame, screen: snapshot.screen) {
                let waitStart = clock.now
                try await Task.sleep(for: .milliseconds(Int(FocusWait.pollSeconds * 1000)))
                phase.waitMs += Self.ms(clock.now - waitStart)
                let start = clock.now
                snapshot = try await freshSnapshot(.afterOwnMove)
                phase.snapshotMs += Self.ms(clock.now - start)
            }
        }
        // type はキーボードの表示を待たずに返る(Android・iOS は画面の外の申告のとき): 出るまで撮り直す(KeyboardWait の doc)。
        // 出れば下の keyboardShifted(nil → 矩形)が true になり整定へつながる
        keyboardKnownAbsent = KeyboardWait.knownAbsent(
            current: keyboardKnownAbsent, before: keyboardFrameBeforeType, after: snapshot.keyboardFrame,
            screen: snapshot.screen, waitExhausted: false)
        if KeyboardWait.shouldAwaitAppearance(
            isAndroid: isAndroid, before: keyboardFrameBeforeType, after: snapshot.keyboardFrame,
            screen: snapshot.screen, typedNewline: pendingTypeEndedWithNewline,
            keyboardKnownAbsent: keyboardKnownAbsent) {
            let deadline = clock.now + .milliseconds(Int(KeyboardWait.appearSeconds * 1000))
            while clock.now < deadline,
                  !Self.keyboardOnScreen(snapshot.keyboardFrame, screen: snapshot.screen) {
                let waitStart = clock.now
                try await Task.sleep(for: .milliseconds(Int(KeyboardWait.pollSeconds * 1000)))
                phase.waitMs += Self.ms(clock.now - waitStart)
                let start = clock.now
                snapshot = try await freshSnapshot(.afterOwnMove)
                phase.snapshotMs += Self.ms(clock.now - start)
            }
            if !Self.keyboardOnScreen(snapshot.keyboardFrame, screen: snapshot.screen) {
                noteCodesThisStep.insert(followsFieldTap ? .keyboardNotShownAfterTap : .keyboardNotShownAfterType)
                keyboardWaitExhausted = true
            }
            keyboardKnownAbsent = KeyboardWait.knownAbsent(
                current: keyboardKnownAbsent, before: keyboardFrameBeforeType, after: snapshot.keyboardFrame,
                screen: snapshot.screen, waitExhausted: true)
        }
        if waitedForKeyboard
            || Self.keyboardShifted(before: keyboardFrameBeforeType, after: snapshot.keyboardFrame) {
            // **settledSignature が自分で phase へ計上する**ので、ここでは足さない
            // (足すと待ち時間を snapshotMs へ二重計上する)
            let settled = try await settledSignature(phase: &phase)
            snapshot = settled.snapshot
            // **待っている間に実際に木が変わった回だけ**数える(settledAfterKeyboard の doc)
            if settled.changed { noteCodesThisStep.insert(.settledAfterKeyboard) }
        }
        return snapshot
    }

    /// `pendingHideKeyboardWait` を消化する: 木がまだキーボードを申告していれば消えるまで待ち、消えたら整定を見る
    /// (下端の要素が戻り、中身が伸びる)。印が無ければ渡した木をそのまま返す。ロケータ操作の解決が呼ぶ
    func consumePendingHideKeyboardWait(_ snapshot: SnapshotResponse,
                                        phase: inout PhaseAccumulator) async throws -> SnapshotResponse {
        guard let cap = pendingHideKeyboardWait else { return snapshot }
        pendingHideKeyboardWait = nil
        guard Self.keyboardOnScreen(snapshot.keyboardFrame, screen: snapshot.screen) else { return snapshot }
        let clock = ContinuousClock()
        var snapshot = snapshot
        let deadline = clock.now + .milliseconds(Int(cap * 1000))
        while clock.now < deadline, Self.keyboardOnScreen(snapshot.keyboardFrame, screen: snapshot.screen) {
            let waitStart = clock.now
            try await Task.sleep(for: .milliseconds(Int(KeyboardWait.goneRereadSeconds * 1000)))
            phase.waitMs += Self.ms(clock.now - waitStart)
            let start = clock.now
            snapshot = try await freshSnapshot(.afterOwnMove)
            phase.snapshotMs += Self.ms(clock.now - start)
        }
        // **settledSignature が自分で phase へ計上する**(ここでは足さない)
        return try await settledSignature(phase: &phase).snapshot
    }

    /// **ロケータを持たない `back()` の前に、直前の type のキーボードが出きるのを待つ**(consumePendingTypeKeyboardCheck)。
    /// iOS の XCUITest の /type はキーボードが出る前に返り、待たずに撃った戻るは上がってくる途中のキーボードの前に届いて
    /// 横取りの確認ダイアログが出なかった(E2EY-iOS の XCUITest の戻るの横取り S0040)。印が無ければ何も読まない(費用ゼロ)
    public func awaitKeyboardBeforeBack() async throws {
        guard pendingTypeKeyboardCheck else { return }
        var phase = PhaseAccumulator()
        _ = try await consumePendingTypeKeyboardCheck(try await freshSnapshot(.afterOwnMove), phase: &phase)
    }

    /// **縁の帯に潜っている対象を、容器を送って外す**(tap と type が共有する)。
    /// 覆いは2種類: 木に載る操作可能な帯(タブバー・固定フッタ = `overlayCoveringForUncover`)と、
    /// 木に要素として渡せないソフトキーボード(`KeyboardOcclusion.frame`)。
    /// 何も送らなかったら nil(呼び手は警告付きで撃つ。**拒否はしない**)。
    ///
    /// **1回でも送ったら、撃つ前の木の ref は使えない**: 撮り直しでブリッジの ref の表が振り直される
    /// (in-app は最後の `/snapshot` の表しか持たない)。外れきらなくても `.stillCovered` で撮り直した木の要素を
    /// 返す —— 古い ref で撃つと表に無ければ 404、**有れば別の要素を黙って押す**(E2EY-iOS の OTP で 404 が
    /// 3/3 再現)。撮り直しは**撃つドライバ**の木で行う(`snapshotSource`。既定値を置かない = 呼び手の渡し忘れを
    /// コンパイルで止める。主ドライバで撮ると、フォールバックへ切り替えた回で in-app の ref を XCUITest へ撃つ)。
    ///
    /// **1回では足りないことがあるので、動いている限り最大 `maxLifts` 回送る**
    /// (実測: 191pt 要求して実際の移動は 144pt で、中心がまだ覆いの内側だった)。
    /// 動かなくなったら諦める = 端まで来ている画面で無限に粘らない。
    /// verb は注記の文言(touching / typing / clearing)。判定は共通で、言い回しだけ呼び手が持つ
    /// **private ではない**: StepExecutor+Hold.swift の executeHoldStart からも呼ぶ
    func liftCoveredTarget(_ element: ElementInfo, in snapshot: SnapshotResponse,
                           step: FlowStep, verb: String, snapshotSource: CoverLiftSnapshotSource,
                           maxLifts: Int = 3,
                           phase: inout PhaseAccumulator) async throws -> CoverLift? {
        var current = element
        var currentSnapshot = snapshot
        // 焦点を立てるタップを撃つ操作か(verb は呼び手の言い回し: typing / clearing / touching)
        let takesFocus = verb == "typing" || verb == "clearing"
        var coverName: String?
        var retook = false
        let clock = ContinuousClock()
        for _ in 0..<maxLifts {
            // 対象を含む容器が無い(隠れるバー等)なら、画面の主たる縦の容器を送り先にする
            // (`uncoverOutsideScrollJump`。覆いが名前つきで容器の縁に接しているときだけ jump が出る)
            let ownContainer = ContainerGeometry.clippingContainer(
                of: current, in: currentSnapshot.elements, inferring: step.containerInference ?? true)
            let outsideContainer = ownContainer == nil
                ? TapTargetGeometry.primaryScrollContainer(in: currentSnapshot.elements,
                                                           screen: currentSnapshot.screen)?.frame
                : nil
            guard let container = ownContainer ?? outsideContainer else {
                return retook ? .stillCovered(element: current, snapshot: currentSnapshot) : nil
            }
            let keyboard = KeyboardOcclusion.resolve(reported: currentSnapshot.keyboardFrame,
                                                     in: currentSnapshot.elements, screen: currentSnapshot.screen)
            var jump: Double?
            var coverRect: FTRect?
            var coverIsKeyboard = false
            // 申告が無い木では chrome から推定する(意味は変えない。理由は keyboardBandFromChrome)。
            // **申告が画面の外(隠れた)なら推定しない** —— 申告がある以上「無い」ではない
            let keyboardBand = keyboard.frame
                ?? (currentSnapshot.keyboardFrame == nil
                    ? TapTargetGeometry.keyboardBandFromChrome(in: currentSnapshot.elements,
                                                               screen: currentSnapshot.screen) : nil)
            if let keyboardFrame = keyboardBand,
               TapTargetGeometry.keyboardCoveredAdvisory(current, keyboardFrame: keyboardFrame) != nil {
                jump = TapTargetGeometry.uncoverKeyboardScrollJump(target: current, keyboard: keyboardFrame,
                                                                   container: container)
                coverName = coverName ?? "the keyboard"
                coverRect = keyboardFrame
                coverIsKeyboard = jump != nil
            }
            // 木に載る覆い・貼り付く見出しを外す送りは手前の判定に頼るので、塗り順のある木だけ(キーボード・下端の見切れは申告と枠で決まる)
            let paintOrderKnown = paintOrderIsReal(currentSnapshot.elements)
            if jump == nil, paintOrderKnown,
               let over = TapTargetGeometry.overlayCoveringForUncover(
                   current, in: currentSnapshot.elements, screen: currentSnapshot.screen) {
                jump = outsideContainer == nil
                    ? TapTargetGeometry.uncoverScrollJump(target: current, coveredBy: over,
                                                          container: container)
                    : TapTargetGeometry.uncoverOutsideScrollJump(target: current, coveredBy: over,
                                                                 container: container)
                coverName = coverName ?? TapTargetGeometry.describe(over)
                coverRect = over.frame
            }
            // **容器の縁に貼り付いた見出しの下に潜った対象**(木の並びでは見出しが奥 = 上の判定は拾えない。pinnedBandCovering の doc)
            if jump == nil, paintOrderKnown, ownContainer != nil,
               let band = TapTargetGeometry.pinnedBandCovering(current, in: currentSnapshot.elements,
                                                               container: container) {
                jump = TapTargetGeometry.uncoverScrollJump(target: current, coveredBy: band, container: container)
                coverName = coverName ?? TapTargetGeometry.describe(band)
                coverRect = band.frame
            }
            // **iOS: 容器の下端で見切れた対象**(覆いは無いが中心が描かれていない。bottomEdgeClipLift の doc)。
            // 指は見切れた行より上に当てる(行そのものを覆いとして避ける)
            if jump == nil, !isAndroid,
               let lift = TapTargetGeometry.bottomEdgeClipLift(current, in: currentSnapshot.elements) {
                jump = lift
                coverName = coverName ?? "the bottom edge of its scroll container"
                coverRect = FTRect(x: container.x, y: current.frame.y, width: container.width,
                                   height: max(0, container.y + container.height - current.frame.y))
            }
            // **焦点を立てる操作(type / clearInput)の前に、欄の中心が容器の上端の外なら、容器を逆向きに送って中へ戻す**
            // (直前の送りで上へ押し出された欄。中心を叩くと容器の外に当たり焦点が前の欄に残る。
            // topEdgeCentreLift の doc)。キーボードの下から出す送りと同じ手順(slowDrag・撮り直し・収まったか)を通す
            if jump == nil, takesFocus, ownContainer != nil,
               let lift = TapTargetGeometry.topEdgeCentreLift(current, container: container) {
                jump = lift
                coverName = coverName ?? "the top edge of its scroll container"
                coverRect = FTRect(x: container.x, y: container.y, width: container.width,
                                   height: max(0, current.frame.y + current.frame.height - container.y))
            }
            // **指を当てるのは覆いを避けた領域**(理由は uncoverDragArea)
            guard let jump, let coverRect,
                  let dragArea = coverIsKeyboard
                      ? TapTargetGeometry.keyboardUncoverDragArea(container: container, keyboard: coverRect)
                      : TapTargetGeometry.uncoverDragArea(container: container, cover: coverRect),
                  await slowDrag(jump: jump, container: dragArea,
                                 avoidingInputsIn: currentSnapshot.elements, phase: &phase) else {
                return retook ? .stillCovered(element: current, snapshot: currentSnapshot) : nil
            }
            let start = clock.now
            let after: SnapshotResponse
            switch snapshotSource {
            case .primary: after = try await freshSnapshot(.afterOwnMove)
            case .driver(let other): after = try await other.snapshot(bypassingCache: true)
            }
            phase.snapshotMs += Self.ms(clock.now - start)
            retook = true
            guard let (moved, _) = SameTargetResolution.resolve(step: step, original: current,
                                                                originalElements: currentSnapshot.elements, in: after) else {
                return .lost(snapshot: after)
            }
            let afterBand = KeyboardOcclusion.resolve(reported: after.keyboardFrame,
                                                      in: after.elements, screen: after.screen).frame
                ?? (after.keyboardFrame == nil
                    ? TapTargetGeometry.keyboardBandFromChrome(in: after.elements, screen: after.screen) : nil)
            let stillCovered = (afterBand.flatMap {
                    TapTargetGeometry.keyboardCoveredAdvisory(moved, keyboardFrame: $0)
                } != nil)
                || (paintOrderIsReal(after.elements) && TapTargetGeometry.overlayCoveringForUncover(
                       moved, in: after.elements, screen: after.screen) != nil)
                || (!isAndroid && TapTargetGeometry.bottomEdgeClipLift(moved, in: after.elements) != nil)
                || (takesFocus && ownContainer != nil && TapTargetGeometry.topEdgeCentreLift(moved, container: container) != nil)
                || (paintOrderIsReal(after.elements)
                    && TapTargetGeometry.pinnedBandCovering(moved, in: after.elements, container: container) != nil)
            if !stillCovered {
                return .lifted(element: moved, snapshot: after,
                               note: "scrolled the container to bring the target out from under"
                                   + " \(coverName ?? "the cover") before \(verb) it")
            }
            // 動かなくなったら諦める(端まで来ている・容器がスクロールしない画面)。
            // **y だけで比べない**: 容器の縁で切られた対象は、動いても y が縁のまま高さだけ変わる
            // (実測 RN Android: 行の上端が容器の上端 403 に張り付いたまま 109 へ伸びた)
            guard moved.frame.y != current.frame.y
                || moved.frame.height != current.frame.height else {
                return .stillCovered(element: moved, snapshot: after)
            }
            current = moved
            currentSnapshot = after
        }
        return retook ? .stillCovered(element: current, snapshot: currentSnapshot) : nil
    }

    /// 呼び手が撃つ ref を、送った後の木から取り直すための結果(`liftCoveredTarget` の doc)
    enum CoverLift {
        case lifted(element: ElementInfo, snapshot: SnapshotResponse, note: String)
        /// 送ったが外れきらなかった。**要素と木は撮り直した後のもの**(撃つ前の ref は無効)
        case stillCovered(element: ElementInfo, snapshot: SnapshotResponse)
        /// 送った後の木で対象を引き当てられない(撃つ前の ref で撃ってはいけない)
        case lost(snapshot: SnapshotResponse)

        var element: ElementInfo? {
            switch self {
            case .lifted(let element, _, _), .stillCovered(let element, _): return element
            case .lost: return nil
            }
        }
        var snapshot: SnapshotResponse {
            switch self {
            case .lifted(_, let snapshot, _), .stillCovered(_, let snapshot), .lost(let snapshot): return snapshot
            }
        }
        var note: String? {
            if case .lifted(_, _, let note) = self { return note }
            return nil
        }
    }

    /// `liftCoveredTarget` が撮り直す木の取得元 = **撃つドライバ**(ref の名前空間を合わせる)
    enum CoverLiftSnapshotSource {
        /// 主ドライバ(`freshSnapshot` の迂回の規則を通す)
        case primary
        /// フォールバック・typeDriver で撃つとき
        case driver(AppDriver)
    }

    /// キーボードを閉じた後の木にも対象が無かったときの節
    static func keyboardClosedNotFoundClause(_ closedNote: String) -> String {
        " (the soft keyboard was up: \(closedNote); the target is not on the screen after it closed either"
            + " — the keyboard is closed now, so closing it is not the fix)"
    }

    /// キーボードを閉じられなかったときの節。**対処は条件付き**: Done のような閉じる部品が無い画面(WebView 等)では従えない
    static func keyboardNotClosedClause(_ tried: String) -> String {
        " (the soft keyboard is up and the target is not in the tree; closing it without side effects failed:"
            + " \(tried). While the keyboard is up the screen may be shifted or shrunk to make room for it, so an element"
            + " can leave the tree whether it sat above or below the keyboard; waiting does not bring it back while the"
            + " keyboard stays up — if the screen has a control that closes it (a Done button, for example), use that first)"
    }

    /// 対象が、キーボードの出る前に読んだ木に居たか。木が無い・居なかったときは false = キーボードの帰属を言わない
    static func targetWasInTreeBeforeKeyboard(_ step: FlowStep, _ before: SnapshotResponse?) -> Bool {
        guard let before else { return false }
        return LocatorResolver.resolve(step: step, in: before) != nil
    }
}
