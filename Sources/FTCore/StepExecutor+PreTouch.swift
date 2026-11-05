import Foundation

extension StepExecutor {

    /// 撃つ前に対象へ届かせた結果
    enum PreTouch {
        /// 撃ってよい。**element / snapshot は撮り直した後のもの**(撃つ前の ref は無効)
        case proceed(element: ElementInfo, snapshot: SnapshotResponse, note: String?)
        case refused(String, kind: StepFailureKind?)
    }

    /// 撃つ前の入口の使い方
    enum EntrancePlan: Equatable {
        /// 通さない(tap の押すだけの形は自前の経路 / 要素を触らない操作 / 大きな面への swipeBy)
        case skip
        case full
        /// 容器を送って覆いを外す段(`liftCoveredTarget`)を除く。大きな面へのピンチ・ジェスチャは対象そのものが容器で、送ると
        /// 操作の対象が動く
        case withoutLift
    }

    /// 大きな面か: スクロールの容器と申告した・高さが画面の半分以上。**キーボードの下まで伸びるのが通常**で、中心が下でも
    /// swipeBy の払いは画面の中で切られる = 閉じて撃つ・断る対象にしない(緑を赤にしない)
    static func isSurfaceTarget(_ element: ElementInfo, screen: FTRect) -> Bool {
        element.scrollable == true || (screen.height > 0 && element.frame.height >= screen.height / 2)
    }

    /// この手が撃つ前の入口(`reachBeforeTouch`)を通るか。分類は `StepAction.touchClass`(手書きの集合を持たない)。
    /// tap の押すだけの形は自前の経路(lift → 閉じる → 撃つ)で同じ部品を通るので含めない。tap の hold > 0 は通す
    static func entrancePlan(action: String, step: FlowStep, element: ElementInfo, screen: FTRect) -> EntrancePlan {
        guard let known = StepAction(rawValue: action) else { return .skip }
        switch known.touchClass {
        case .noElementTouch: return .skip
        case .ownGuardedPath:
            return known == .tap && (step.duration ?? FlowStep.defaultTapHoldSeconds) > 0 ? .full : .skip
        case .touchesElement:
            guard isSurfaceTarget(element, screen: screen) else { return .full }
            switch known {
            case .swipeBy: return .skip
            case .pinchOut, .pinchIn, .gesture: return .withoutLift
            case .doubleTap, .holdStart, .swipeElementToElement: return .full
            case .tap, .type, .clearInput, .findImage, .findImages, .existImage, .swipe, .scroll, .scrollToEdge,
                 .flick, .scrollTo, .swipePointToPoint, .fold, .unfold, .hinge, .rotateTo, .pressEnter,
                 .hideKeyboard, .holdEnd, .waitForSettle, .select:
                return .full
            }
        }
    }

    /// **要素を指で触る操作の撃つ前の入口**: 容器の縁の帯に潜っていれば送って外す → キーボードで潰れた・せり上がったバーに
    /// 覆われた対象はキーボードを閉じて引き直す → なお中心がキーボードの下なら閉じてから届かせる(閉じられなければ断る)。
    /// tap と type が使う部品(`liftCoveredTarget` / `closeKeyboardWithoutSideEffects` / `reachPastKeyboard`)をそのまま通す。
    /// 覆いの判定は `PreFireGuard` + `OcclusionGeometry` の1つ。**木の並びで手前が読めない覆い**(Flutter の貼り付く見出し)は
    /// `pinnedBandCovering` の帯の推定の範囲でだけ送る(推定の外は注記に止める = 誤って断らない)
    func reachBeforeTouch(_ element: ElementInfo, in snapshot: SnapshotResponse, step: FlowStep, action: String,
                          snapshotSource: CoverLiftSnapshotSource, liftsTarget: Bool, keyboardClosedEarlier: Bool,
                          phase: inout PhaseAccumulator) async throws -> PreTouch {
        var keyboardClosed = keyboardClosedEarlier
        var element = element
        var snapshot = snapshot
        var notes: [String?] = []
        if liftsTarget,
           let lifted = try await liftCoveredTarget(element, in: snapshot, step: step, verb: "touching",
                                                    snapshotSource: snapshotSource, phase: &phase) {
            guard let liftedElement = lifted.element else {
                return .refused(Self.coverLiftLostMessage(step, verb: "touching", after: lifted.snapshot)
                    + (await leftForegroundSuffix(snapshot.sessionBundleID)), kind: .notFound)
            }
            element = liftedElement
            snapshot = lifted.snapshot
            notes.append(lifted.note)
        }
        let keyboard = KeyboardOcclusion.resolve(reported: snapshot.keyboardFrame, in: snapshot.elements,
                                                 screen: snapshot.screen)
        var onlyDismissesKeyboard = false
        if case .primary = snapshotSource {
            onlyDismissesKeyboard = PreFireGuard.tapOnlyDismissesKeyboard(element, in: snapshot, framework: uiFramework)
        }
        var keyboardCloseOutcome: KeyboardClose?
        if case .primary = snapshotSource,
           PreFireGuard.keyboardCover(of: element, in: snapshot, keyboard: keyboard) != nil || onlyDismissesKeyboard {
            keyboardCloseOutcome = try await closeKeyboardWithoutSideEffects(step: step, phase: &phase)
        }
        // 閉じられなかった(叩ける空きが無い・閉じなかった)まま撃つ形を黙って ok にしない(反転チャットは行が画面を埋めて空きが無く、
        // RN の iOS は最初のタップが閉じるだけで行へ届かなかった)。撃つ判断は変えず、事実を注記に残す
        if onlyDismissesKeyboard, case .notClosed(let why)? = keyboardCloseOutcome {
            notes.append(Self.keyboardStayedUpNote(why))
        }
        if case .closed(let closedNote, _)? = keyboardCloseOutcome {
            let start = ContinuousClock().now
            let after = try await freshSnapshot(.afterOwnMove)
            phase.snapshotMs += Self.ms(ContinuousClock().now - start)
            // 引けなければ撃たない(閉じる前の要素は前の木の ref と枠 = 撃つと別の物に当たる。寄せの後と同じ)
            guard let (reached, _) = SameTargetResolution.resolve(step: step, original: element,
                                                                  originalElements: snapshot.elements, in: after) else {
                return .refused(Self.keyboardClosedLostMessage(step, closedNote: closedNote)
                    + (await leftForegroundSuffix(snapshot.sessionBundleID)), kind: .notFound)
            }
            snapshot = after
            element = reached
            keyboardClosed = true
            notes.append(closedNote + " — the target was collapsed or covered by a bar raised above the keyboard while it was up")
        }
        switch try await reachPastKeyboard(element, in: snapshot, step: step, action: "tap", allowsVisiblePart: false,
                                           priorTap: nil, snapshotSource: snapshotSource, phase: &phase) {
        case nil: break
        case .refused(let message)?: return .refused(message, kind: nil)
        case .visiblePart?: preconditionFailure("allowsVisiblePart is false for this action")
        case .reached(let reached, let after, let note)?:
            element = reached
            snapshot = after
            keyboardClosed = true
            notes.append(note)
        }
        if keyboardClosed, liftsTarget {
            switch try await settleCoverAfterKeyboardClose(element, in: snapshot, step: step, verb: "touching",
                                                           relift: liftsTarget, allowsVisiblePart: true, snapshotSource: snapshotSource, phase: &phase) {
            case .refused(let message, let kind): return .refused(message, kind: kind)
            case .settled(let settledElement, let settledSnapshot, let note):
                element = settledElement
                snapshot = settledSnapshot
                notes.append(note)
            }
        }
        return .proceed(element: element, snapshot: snapshot,
                        note: notes.compactMap { $0 }.isEmpty ? nil : notes.compactMap { $0 }.joined(separator: " / "))
    }

    /// **指で触る操作が、中心を操作可能な帯に覆われた対象をどう撃つか**(判定は `TapTargetGeometry.coveredTouch` = FTCore に1か所)。
    /// 撃つ段の直前に、送り(`liftCoveredTarget`)・キーボードを閉じる段を終えた木で呼ぶ。
    /// 覆われていなければ `.none`(従来どおり)。見えている部分が床以上なら `.part`(その中心を押す・注記つき)、
    /// 届かなければ `.refuse`(撃たない = 覆いを押して遷移するのを防ぐ。文言は事実だけ)
    enum CoveredTouchPlan {
        case none
        case part(FTRect, note: String)
        case refuse(String)
    }

    /// DSL で `scroll:` を書ける触る操作(tap・hold = holdStart)。断り文の対処(`Add scroll:`)はこれだけに出す
    static func coveredTouchAcceptsScroll(_ action: String?) -> Bool {
        action == "tap" || action == "holdStart"
    }

    /// 容器の外で、1回の送りでは外せない覆いの下に潜った対象への断り文(撃たない)。nil = その形ではない。
    /// **触る操作の全経路が撃つ点を決める前に通す**(tap は「中心が容器の外なら見えている部分を押す」分岐が先にあり、
    /// そこを通る形 = 横向きの隠れたバー・CMP の縮み切ったヘッダでこの断りを素通りしていた。10周目の探索 iultra F2・F6)
    /// この木の z が本物の塗り順か(`PaintOrder.isReal` の転送。手前の推測で撃ち方を変えてよいか)
    func paintOrderIsReal(_ elements: [ElementInfo]) -> Bool {
        PaintOrder.isReal(in: elements, isAndroid: isAndroid, framework: uiFramework)
    }

    /// 覆いの下の対象を出す直し方(撃つ前の断り・失敗後の案内 `coveredTouchHint` で共有)。名指す覆いは中心を覆う最前面の要素
    /// (シートの中の行のことがある)なので、閉じる・畳む相手は「それを持つシート・パネル」と言う。`step` が分かれば `scroll:` の
    /// 書き方を出し分ける(書いた手 = 探索が送っても出せなかったので足せと言わない・`scroll:` を受けないコマンドは先に送る手)。
    /// nil = scroll: を勧めない(失敗後の案内・探索が覆いを見ない経路 = iOS の当たり判定の断り)
    static func uncoverRemedy(cover: String, step: FlowStep?) -> String {
        let close = "If \(cover) is part of a sheet or panel, close or collapse it first"
        guard let step else { return close + "; otherwise scroll the list before this step until the target is clear of it" }
        if step.direction != nil {
            return close + "; scrolling in the step's scroll: direction did not bring the target out, so scroll the other way"
        }
        if coveredTouchAcceptsScroll(step.action) { return close + "; otherwise add scroll: so the target is scrolled clear of it" }
        return close + "; otherwise scroll the list before this step (scrollUp() / scrollDown()) until the target is clear of it"
            + " — this command has no scroll: argument"
    }

    func buriedOutsideContainerRefusal(_ element: ElementInfo, in snapshot: SnapshotResponse, step: FlowStep) -> String? {
        // 判定は探索の「見つかった」・最初に掴む一致と同じ `TapTargetGeometry.touchBlock`(1か所)。撃つ前に断る形:
        // 一覧の外で1回の送りでは外せない覆い(ナビゲーションバー・折りたたみヘッダ)の下・入れ子の外側の一覧に切り取られた対象。
        // 見えている部分を押しても覆いや画面の上端に当たり、何も起きないまま ok になった(9〜11周目の探索)
        guard let block = TapTargetGeometry.touchBlock(
            element, in: snapshot.elements, screen: snapshot.screen, safeAreaTop: snapshot.safeAreaTop,
            scale: driver.pointScale, inferring: step.containerInference ?? true, searchFinger: nil,
            paintOrderIsReal: paintOrderIsReal(snapshot.elements)) else { return nil }
        let head = "did not touch \(step.locatorSummary): its centre is under \(block.cover), and touching it there would"
            + " land on something else (nothing was touched). "
        // `scroll:` を書いた手がここへ来た = 探索が送っても出せなかった(探索は同じ判定で見つかったにしない)。足せとは言わない
        if step.direction != nil {
            return head + "Scrolling in the written direction did not bring it out; scroll the other way, or point at an"
                + " element that is not hidden"
        }
        // `scroll:` を受けるのは tap と hold だけ(doubleTap・ドラッグ・swipeElementToElement 等は引数が無い = 先に送る手を案内する)
        if Self.coveredTouchAcceptsScroll(step.action) {
            return head + "Add scroll: \(block.scroll) so the list is scrolled until the target comes out"
        }
        let call = [".up": "scrollUp()", ".down": "scrollDown()", ".left": "scrollLeft()", ".right": "scrollRight()"][block.scroll]
            ?? "scrollUp()"
        return head + "Scroll the list first (for example \(call) before this step) until the target comes out"
            + " — this command has no scroll: argument"
    }

    func coveredTouchPlan(_ element: ElementInfo, in snapshot: SnapshotResponse, step: FlowStep) async -> CoveredTouchPlan {
        if let message = buriedOutsideContainerRefusal(element, in: snapshot, step: step) { return .refuse(message) }
        // 見えている部分を押す/薄ければ断るは手前の判定に頼るので、塗り順のある木だけ(`PaintOrder.isReal`)
        let covered = paintOrderIsReal(snapshot.elements)
            ? TapTargetGeometry.coveredTouch(for: element, in: snapshot.elements, screen: snapshot.screen,
                                             inferring: step.containerInference ?? true, scale: driver.pointScale,
                                             zIsPaintOrder: true)
            : nil
        switch covered {
        case nil:
            // 塗り順の無い木(iOS)で別の層の押せる要素が中心に重なるときだけプラットフォームに聞く。断るのは false の答えだけ
            // (true・引き当て不能・答えられないは従来どおり = true は誤ることがある。門の doc 参照)。
            // **見えている部分を押す判定(上の .visiblePart)より後に聞く**: 中心だけ帯に覆われた対象は中心で聞くと false になり、
            // 見えている部分を押せば通る形を断ってしまう
            // **撃つ前の重なりの疑いは、ここでは言わない**(緑の run では黙る)。直前の操作の記録に控え、後続のステップが赤に
            // なったときだけ失敗の文言で名指す(`lastTapHint`)。重なりは画面の大きさで変わり書く時点では避けられないので、
            // 実際に効かなかった回(= 赤)にだけ、直す先(シナリオ)を案内する。判定は足さない(既存の疑いを写すだけ)
            var suspect: ElementInfo?
            if case .overlayCovering(let over)? = TapTargetGeometry.advisoryKind(for: element, in: snapshot.elements,
                                                                                 screen: snapshot.screen) {
                suspect = over
            }
            if !isAndroid,
               let cover = TapTargetGeometry.otherLayerCoverSuspect(element, in: snapshot.elements, screen: snapshot.screen) {
                if await driver.hitTest(query: HitTestQuery(element)) == .hittable(false) {
                    let name = TapTargetGeometry.describe(cover)
                    return .refuse("did not touch \(step.locatorSummary): the platform reports it cannot be hit at its position —"
                        + " \(name) is drawn over it, so a touch would land there (nothing was touched). "
                        // scroll: は勧めない: 塗り順の無い木の探索は当たり判定を見ないので、足しても同じ断りになる
                        + Self.uncoverRemedy(cover: name, step: nil))
                }
                suspect = suspect ?? cover
            }
            if let suspect { noteCoverSuspect(TapTargetGeometry.describe(suspect), for: element) }
            return .none
        case .visiblePart(let rect, let over)?:
            return .part(rect, note: "touched the part of the target not covered by \(TapTargetGeometry.describe(over))"
                + " or anything else in front (the target's centre is under it)")
        case .tooThin(let visible, let floor, let over)?:
            func n(_ v: Double) -> String { String(format: "%g", (v * 10).rounded() / 10) }
            let name = TapTargetGeometry.describe(over)
            return .refuse("did not touch \(step.locatorSummary): its centre is covered by \(name),"
                + " and only \(n(visible)) of the target is left uncovered by what is in front of it"
                + " (the minimum is \(n(floor)), in the snapshot's units), so a touch would land on \(name)"
                + " (nothing was touched). " + Self.uncoverRemedy(cover: name, step: step))
        }
    }

    enum KeyboardCloseSettle {
        case settled(element: ElementInfo, snapshot: SnapshotResponse, note: String?)
        case refused(String, kind: StepFailureKind?)
    }

    /// **キーボードを閉じて窓が伸びた後の木で、覆いの送り(`liftCoveredTarget`)をやり直し、外れなければ撃たずに断る**。
    /// キーボードが出ている間はタブ列も対象も窓の外(縮んだ窓の下)で最初の送りは何もせず、閉じた後に初めて下のタブ列が
    /// 中心を覆うことがある(Android の横向き: 覆いを注記だけにして撃つと、タブを押して別の画面へ遷移した)。
    /// 閉じたのは自分の手なので、閉じた後の画面で人が見る状態に対して判断する: 木に載る操作可能な帯が中心を覆っているなら、
    /// 送って外せたときだけ撃つ。`relift` = 呼び手がこの直前に送りを済ませていない(閉じた後の木へは未適用)。
    /// 断るときは何も撃たない(送りのドラッグは撃っている)。
    func settleCoverAfterKeyboardClose(_ element: ElementInfo, in snapshot: SnapshotResponse, step: FlowStep, verb: String,
                                       relift: Bool, allowsVisiblePart: Bool, snapshotSource: CoverLiftSnapshotSource,
                                       phase: inout PhaseAccumulator) async throws -> KeyboardCloseSettle {
        var element = element
        var snapshot = snapshot
        var note: String?
        if relift,
           let lifted = try await liftCoveredTarget(element, in: snapshot, step: step, verb: verb,
                                                    snapshotSource: snapshotSource, phase: &phase) {
            guard let liftedElement = lifted.element else {
                return .refused(Self.coverLiftLostMessage(step, verb: verb, after: lifted.snapshot)
                    + (await leftForegroundSuffix(snapshot.sessionBundleID)), kind: .notFound)
            }
            element = liftedElement
            snapshot = lifted.snapshot
            note = lifted.note
        }
        // 指で触る操作(allowsVisiblePart)は覆われていない見えている部分を押すか、薄ければ撃つ段(`coveredTouchPlan`)が断る。
        // 打鍵・消去は欄の ref に撃つので部分を選べない = 覆われたままなら断る
        let done = verb == "typing" ? "typed" : verb == "clearing" ? "cleared" : "touched"
        // 木に載る覆いの再判定は手前の判定に頼るので、塗り順のある木だけ(`PaintOrder.isReal`)
        let paintOrderKnown = paintOrderIsReal(snapshot.elements)
        if !allowsVisiblePart, paintOrderKnown,
           let over = TapTargetGeometry.overlayCoveringForUncover(element, in: snapshot.elements, screen: snapshot.screen) {
            return .refused("the soft keyboard was closed before \(verb) \(step.locatorSummary), and the target's centre"
                + " (\(Int(element.frame.centerX)), \(Int(element.frame.centerY))) is now covered by \(TapTargetGeometry.describe(over)),"
                + " which scrolling its container did not clear — a touch there would land on \(TapTargetGeometry.describe(over))"
                + " (nothing was \(done))", kind: nil)
        }
        // 見えている部分を押す形(覆いが残っている)は、窓が伸びきるまで読み直す(閉じた直後の木は窓が伸びる途中で、タブ列を
        // 実際より下に申告する = その木で決めた部分がタブを押して遷移した。Flutter の Android 横向き 5 回中 1 回)。
        // 対象と覆いの枠が続けて2回同じになったら決める。少なくとも1回は読み直し、上限はステップの待ちの予算(新しい数字を置かない)。
        // 読み直しはブリッジの ref の表を作り直すので、引けなくなったら前の木の要素では撃たない
        if allowsVisiblePart, paintOrderKnown,
           TapTargetGeometry.overlayCoveringForUncover(element, in: snapshot.elements, screen: snapshot.screen) != nil {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(step.timeout ?? tunables.defaultTimeout)
            var settled = false
            var lost: SnapshotResponse?
            repeat {
                let start = clock.now
                let next: SnapshotResponse
                switch snapshotSource {
                case .primary: next = try await freshSnapshot(.afterOwnMove)
                case .driver(let other): next = try await other.snapshot(bypassingCache: true)
                }
                phase.snapshotMs += Self.ms(clock.now - start)
                // 伸びる途中の1枚で一瞬引けないことはあるので、予算の内は読み直す。予算を使い切っても引けなければ撃たない
                guard let (moved, _) = SameTargetResolution.resolve(step: step, original: element,
                                                                    originalElements: snapshot.elements, in: next)
                else { lost = next; continue }
                lost = nil
                settled = TapTargetGeometry.coverGeometryUnchanged(element, in: snapshot, moved, in: next)
                element = moved
                snapshot = next
            } while !settled && clock.now < deadline
            if lost != nil {
                return .refused("the soft keyboard was closed before \(verb) \(step.locatorSummary), and the target was not on the"
                    + " screen while the window grew back (nothing was \(done))", kind: .notFound)
            }
            if !settled {
                note = Self.joinNotes(note, "the target or what covers it was still moving when the step's wait ran out —"
                    + " the uncovered part was chosen from the last reading")
            }
        }
        return .settled(element: element, snapshot: snapshot, note: note)
    }

    /// **frame の中心を撃つ指の操作で、中心が画面の外なら撃たずに断る文**(長押し・doubleTap・要素から要素へのドラッグの始点と終点・
    /// Android のピンチ)。ウィンドウ外のタッチは黙って落ちるので撃っても何も起きず ok になる。
    /// 判定は `TapTargetGeometry.offscreenScrollGateCentre`(MCP・スクロール探索の「見つかった」ゲートと共有。画面より大きい軸は免除)。
    /// **tap の押すだけの形は対象外**(`visibleTapRect` で見えている部分へ寄せる経路があり、助言に止めている)。
    /// iOS のピンチは XCUITest が identifier の要素へ撃つので対象外(中心の外を撃つとは限らない)。文言は呼び手ごと
    static func offscreenCentreRefusal(action: String, step: FlowStep, element: ElementInfo,
                                       screen: FTRect, isAndroid: Bool, role: String? = nil) -> String? {
        let fires: Bool
        switch action {
        case "doubleTap", "swipeElementToElement": fires = true
        case "tap": fires = (step.duration ?? FlowStep.defaultTapHoldSeconds) > 0
        case "pinchOut", "pinchIn": fires = isAndroid
        default: fires = false
        }
        guard fires, let c = TapTargetGeometry.offscreenScrollGateCentre(for: element, screen: screen) else { return nil }
        return "cannot \(action): the \(role ?? "target")'s centre (\(Int(c.x)), \(Int(c.y))) is outside the visible screen"
            + " (\(Int(screen.width))x\(Int(screen.height))), so the touch would land nowhere and nothing was sent."
            + " Bring it into view first (scroll: / scrollTo)"
    }
}
