// StepExecutor+VisibilityPipeline.swift
// テキストの可視性検証(occlusion-guard)の判定の流れ。段の順は `VisibilityStage` の宣言1か所だけ。
// 各段の出口・注記・門の扱いの表は docs/design/visibility-check.md DS-24.6(行ラベル V1〜V24 は表と同じ)。
// 挙動を固定するテストは `VisibilityCheckCharacterizationTests`。**段を足す・外す・並べ替える前に表を直す**。
// 待ちのループ側の締め切り延長は `GuardDeadlineExtension`。

import Foundation

/// 段の出口。`.next` = 次の段へ、`.pass` = 緑(今までの nil)、`.fail` = 赤。
/// **起動直後の門(`firstFrameGatePending`)を段が直接さわらない**: 出口が `FirstFrameGateUse` を運び、ループの1か所
/// (`occlusionFlip`)が適用する。門を消費しない出口(V12・V16・V2・V10・V11 など)は `.keep`
enum VisibilityStageOutcome {
    case next
    case pass(FirstFrameGateUse)
    case fail(StepResult.Status, FirstFrameGateUse)
}

/// 出口が起動直後の門をどう扱うか。`consume` の sd は `consumeFirstFrameGate` へそのまま渡す値
/// (Tier-1 を通っていなければ nil = 門が開いている回だけそこで測る)
enum FirstFrameGateUse {
    case keep
    case consume(visible: Bool, sd: Double?)
}

/// 判定の流れの段。**宣言の順がそのまま評価の順**(`allCases`)。各 case の行ラベルは DS-24.6 の表と同じ。
/// 出口が `.next` の段は表の「次へ」、緑・赤は表の「出口」。
enum VisibilityStage: CaseIterable {
    /// V1 入口(`visibilityGuardActive` が偽なら緑。`guardEnteredThisStep` も立てない)
    case entry
    /// V2 画面外(Tier-0。スクショも FM も要らない)
    case offscreen
    /// V3 覆いの下(塗り順が本物の木で tooThin なら注記だけ)
    case coveredByFront
    /// V4 行の確かめの判定(OCR だけで決める行か。最後の判定で `rowLabelNotRead` を付け外しする印を立てる)
    case rowCheckDecision
    /// V5 文字の子へ(同じラベルの文字の子が1つならその子で以降を見る)
    case sameLabelChild
    /// V6 段なし(FM の段も OCR の段も無ければ緑)
    case noStageConfigured
    /// V7 退化枠(幅か高さが 1 未満・期待が空)
    case degenerateFrame
    /// V8 枠の復元(Compose が削った枠)
    case frameRestore
    /// V9 対象の足切り(`OcclusionEligibility`)
    case eligibility
    /// V10 古い絵(新規撮影。撮り直しても古ければ緑)
    case staleFresh
    /// V11 既知の古い絵(使い回しの絵を含む)
    case staleKnown
    /// V12 インクの足切り(幾何の疑いなし・容器の縁でない・閾値 > 0・stdDev ≥ 閾値で緑)
    case inkCutoff
    /// V13 黒い絵
    case blackFrame
    /// V14 WebView の取り逃し
    case webViewMiss
    /// V15 OCR のコンパイル待ち
    case ocrCompileWait
    /// V16 OCR の近道(丸ごと読めて mode on なら緑)
    case ocrShortcut
    /// V17 行(V4 が真のとき OCR の読みだけで赤か緑)
    case rowByOCR
    /// V18 FM が使えない(`OCROnlyVisibility` で決める)
    case fmUnavailable
    /// V19 判定の控え(同じ絵・枠・期待なら FM を呼ばない)
    case verdictMemo
    /// V20 FM に訊く(無回答なら V18 と同じ出口。控えない)
    case fmAsk
    /// V21 空の転写の確かめ(OCR の確認か訊き直しで読めたら緑)
    case emptyTranscript
    /// V22 突き合わせ(`OCROnlyVisibility.merge` で可視なら緑。不可視の門の消費は V23・V24 の出口が運ぶ)
    case reconcile
    /// V23 前の値の古い絵
    case previousValueStale
    /// V24 FM の赤
    case fmRed
}

/// 段をまたぐ値。段はここへ積み、ローカル変数で渡さない。
struct VisibilityEvidence {
    var element: ElementInfo
    let expectedText: String
    let elements: [ElementInfo]
    let screen: FTRect
    let keyboardShown: Bool
    let looseMatch: Bool
    let expectedIsUserText: Bool
    let perStepGuard: Bool?
    /// V4 の結果。OCR の読みだけで決める行か
    var rowCheckByOCR = false
    /// V4 を通った印。V1〜V3 で返った出口には `rowLabelNotRead` の付け外しを掛けない(今の挙動)
    var rowNoteArmed = false
    var fmConfigured = false
    var fmAvailable = false
    var screenshot = Data()
    var geo = false
    var atScrollEdge = false
    var sd: Double?
    var ocrReading: RegionText.Reading?
    var ocrReadable = false
    var ocrOnly: (outcome: OCROnlyVisibility.Outcome, ink: Double?) = (.undetermined, nil)
    var memoKey: VisibilityVerdictMemo.Key
    var memoImageHash = 0
    /// FM の verdict(控えか実呼び出し)。`verdictObtained` が真のときだけ意味を持つ
    var verdict: VisibilityVerdictMemo.Verdict = (visible: true, state: "", reason: "", observedText: "")
    var verdictObtained = false
    var emptyTranscriptOnInk = ""

    init(element: ElementInfo, expectedText: String, elements: [ElementInfo], screen: FTRect,
         keyboardShown: Bool, looseMatch: Bool, expectedIsUserText: Bool, perStepGuard: Bool?) {
        self.element = element
        self.expectedText = expectedText
        self.elements = elements
        self.screen = screen
        self.keyboardShown = keyboardShown
        self.looseMatch = looseMatch
        self.expectedIsUserText = expectedIsUserText
        self.perStepGuard = perStepGuard
        self.memoKey = VisibilityVerdictMemo.key(frame: element.frame, screen: screen, expectedText: expectedText)
    }
}

extension StepExecutor {
    /// 可視性照合(`requireVisible`)がこのステップで効くか。ステップ指定(DSL の requireVisible)
    /// 優先、無ければ executor 既定。`occlusionGuardEnabled` はどちらより上位の実行プロファイル由来
    /// マスタースイッチ(`fmTextVisibilityCheck || ocrTextVisibilityCheck`)。**FM の有無は含めない** —— 幾何の Tier-0 は FM 無しで
    /// 効くので、FTRuntime の保持値の高速経路もこれを見て「照合が走る設定なら実機を見に行く」と決める
    /// (FM 前提の条件で判定すると、FM の無いホストで幾何の照合が静かに1つ消える)
    public func visibilityGuardActive(perStepGuard: Bool?) -> Bool {
        occlusionGuardEnabled && (perStepGuard ?? occlusionGuard)
    }

    /// launch storyboard を「何も描かれていない」と読む crop の輝度 stdDev の上限。
    /// 単位は 8-bit 輝度(0〜255)の段階。**1.0 = 量子化1段階未満** —— ディザや圧縮の揺らぎしか
    /// 無く、画素に構造が無いことの定義であって調整値ではない(実測: M1Max の launch storyboard は
    /// min=253 / max=255 で stdDev ≈ 0.1、厳密 0 ではなかった)。これ以上は「何か描かれている」
    /// (本物の覆い・減光)として扱う = 猶予を与えない
    static let firstFrameBlankStdDevCeiling: Double = 1.0

    /// FM の空の転写を OCR で確かめる読みの予算。ここで諦めると誤った赤になるので、`OcclusionVerifier.nearMissOCRBudget`
    /// (惜しい転写の確認・同じ理由)と同じく Vision の初回コンパイル(実測 25〜47 秒)を待ち切れる長さ。払うのは赤になりかけた回だけで、
    /// コンパイル済みなら数百 ms で返る。尽きたら判定は FM のまま(赤)
    static let emptyTranscriptOCRBudget: Duration = .seconds(60)

    /// [occlusion-guard] ツリー一致した要素が**見えているか**を段(`VisibilityStage`)の順に確かめ、見えていなければ
    /// 誤った緑として反転する失敗ステータスを返す。反転不要(可視 or 判定不能 or 無効)なら nil。
    /// OCR の段(ocrTextVisibilityCheck)と FM の段(fmTextVisibilityCheck = fmVisibilityCheckEnabled)は独立。
    /// 呼び出し側(exists/textEquals)は不可視を即失敗にせず timeout まで可視化を待つ(poll-until-visible)。
    /// keyboardShown: 判定に使った木の `KeyboardWait.isShown`(絵を XCUITest で撮るかの材料。`JudgmentCapture`)
    func occlusionFlip(element: ElementInfo, expectedText: String, elements: [ElementInfo],
                              screen: FTRect, keyboardShown: Bool, keyboard: FTRect? = nil,
                              looseMatch: Bool, perStepGuard: Bool?,
                              expectedIsUserText: Bool = false,
                              phase: inout PhaseAccumulator) async throws -> StepResult.Status? {
        // 段の外に残す: 段が読む状態の初期化(V1 より前 = 無効でも毎回行う今の順)
        guardFrameStaleThisEval = false
        guardKeyboardFrame = keyboard
        var evidence = VisibilityEvidence(
            element: element, expectedText: expectedText, elements: elements, screen: screen,
            keyboardShown: keyboardShown, looseMatch: looseMatch, expectedIsUserText: expectedIsUserText,
            perStepGuard: perStepGuard)
        for stage in VisibilityStage.allCases {
            switch try await runVisibilityStage(stage, &evidence, phase: &phase) {
            case .next:
                continue
            case .pass(let gate):
                applyFirstFrameGate(gate, evidence)
                return finishVisibility(nil, evidence)
            case .fail(let status, let gate):
                applyFirstFrameGate(gate, evidence)
                return finishVisibility(status, evidence)
            }
        }
        // V24 が必ず返すので来ない。来たら黙って緑にしない
        return .failed("text visibility check failed (on screen): the visibility pipeline ended without a verdict")
    }

    /// 起動直後の門の消費は**ここだけ**(段は出口で値を返す)
    private func applyFirstFrameGate(_ gate: FirstFrameGateUse, _ evidence: VisibilityEvidence) {
        guard case .consume(let visible, let sd) = gate else { return }
        consumeFirstFrameGate(visible: visible, sd: sd, screenshot: evidence.screenshot,
                              element: evidence.element, screen: evidence.screen)
    }

    /// 注記は最後の判定に合わせる(待ちの途中で一度だけ読めなかった回が、後で読めて緑になったら外す)。V4 を通った出口だけ
    private func finishVisibility(_ status: StepResult.Status?, _ evidence: VisibilityEvidence) -> StepResult.Status? {
        guard evidence.rowNoteArmed else { return status }
        if case .failed? = status {
            if evidence.rowCheckByOCR { noteCodesThisStep.insert(.rowLabelNotRead) }
        } else {
            noteCodesThisStep.remove(.rowLabelNotRead)
        }
        return status
    }

    private func runVisibilityStage(_ stage: VisibilityStage, _ e: inout VisibilityEvidence,
                                    phase: inout PhaseAccumulator) async throws -> VisibilityStageOutcome {
        switch stage {
        case .entry: return stageEntry(&e)
        case .offscreen: return stageOffscreen(&e)
        case .coveredByFront: return stageCoveredByFront(&e)
        case .rowCheckDecision: return stageRowCheckDecision(&e)
        case .sameLabelChild: return stageSameLabelChild(&e)
        case .noStageConfigured: return stageNoStageConfigured(&e)
        case .degenerateFrame: return stageDegenerateFrame(&e)
        case .frameRestore: return stageFrameRestore(&e)
        case .eligibility: return stageEligibility(&e)
        case .staleFresh: return try await stageStaleFresh(&e, phase: &phase)
        case .staleKnown: return try await stageStaleKnown(&e, phase: &phase)
        case .inkCutoff: return stageInkCutoff(&e)
        case .blackFrame: return stageBlackFrame(&e)
        case .webViewMiss: return stageWebViewMiss(&e)
        case .ocrCompileWait: return await stageOCRCompileWait(&e, phase: &phase)
        case .ocrShortcut: return await stageOCRShortcut(&e, phase: &phase)
        case .rowByOCR: return stageRowByOCR(&e)
        case .fmUnavailable: return stageFMUnavailable(&e)
        case .verdictMemo: return stageVerdictMemo(&e)
        case .fmAsk: return await stageFMAsk(&e, phase: &phase)
        case .emptyTranscript: return await stageEmptyTranscript(&e, phase: &phase)
        case .reconcile: return stageReconcile(&e)
        case .previousValueStale: return stagePreviousValueStale(&e)
        case .fmRed: return stageFMRed(&e)
        }
    }

    // MARK: - 段 V1〜V9

    /// V1
    private func stageEntry(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        guard visibilityGuardActive(perStepGuard: e.perStepGuard) else { return .pass(.keep) }
        // **ここより後ろに置かない** —— 足切り(型・ラベル・インク)で FM を呼ばずに
        // 降りた回もガードが責任を持ったアサーションの総数(分母)に入れるため
        guardEnteredThisStep = true
        return .next
    }

    /// V2 Tier-0: 画面外は見えていない。**スクショも FM も要らない**ので最初に置く。
    /// 足切り(型・ラベル)より前 —— アイコンや無ラベル要素は FM 照合の対象外でも、画面外なのは同じ。
    /// (`TapTargetGeometry.offscreenScrollGateCentre` = スクロール探索の「見つかった」ゲートと同じ述語。
    /// iOS の木は画面外の要素も frame ごと残すので、これが無いと通り過ぎた要素への exist が通る。
    /// FM 側は crop が画像の外に落ちると nil = 素通りなので、**FM が生きていてもこの形は FM では塞がらない**)
    private func stageOffscreen(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        guard let c = TapTargetGeometry.offscreenScrollGateCentre(for: e.element, screen: e.screen) else { return .next }
        return .fail(.failed("text visibility check failed (offscreen): present in the tree but its centre"
                             + " (\(Int(c.x)), \(Int(c.y))) is outside the screen, so it is not visible"
                             + " (scroll it into view before this step)"), .keep)
    }

    /// V3 塗り順が本物の木で、tap なら撃つ前に断る覆いの下にある要素(合否は変えない = StepNote.coveredByFrontElement)
    private func stageCoveredByFront(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        if paintOrderIsReal(e.elements), case .tooThin? = TapTargetGeometry.coveredTouch(
            for: e.element, in: e.elements, screen: e.screen, inferring: true, scale: driver.pointScale, zIsPaintOrder: true) {
            noteCodesThisStep.insert(.coveredByFrontElement)
        }
        return .next
    }

    /// V4 文字の子を持たない行(iOS の in-app の木のセル)は、その枠で読ませて見えていなければ赤(`OcclusionEligibility.isLabelledRowWithoutText`)。
    /// 判定は OCR の段だけ(FM は呼ばない)なので、OCR の段が無効な構成では行の確かめ自体を走らせない。
    /// **子への差し替え(V5)より前の element で決める**
    private func stageRowCheckDecision(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        e.rowCheckByOCR = !isAndroid && occlusionOCRMode != .off
            && OcclusionEligibility.isLabelledRowWithoutText(e.element, expectedText: e.expectedText, in: e.elements)
        e.rowNoteArmed = true
        return .next
    }

    /// V5 文字の型でない要素(行・ボタン)は、同じ label の文字の子を1つだけ持つならその子で確かめる
    /// (親は縁で切れて文字が消えていても枠の位置にインクがある。以降の全段 = 縁・容器の外の判定・インク・OCR・FM が子を見る)。
    /// 子が無い・複数なら従来どおり足切りで素通り(`OcclusionEligibility.sameLabelTextDescendant`)
    private func stageSameLabelChild(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        if let child = OcclusionEligibility.sameLabelTextDescendant(
            of: e.element, expectedText: e.expectedText, isUserText: e.expectedIsUserText, in: e.elements) {
            e.element = child
        }
        return .next
    }

    /// V6 FM の段(fmTextVisibilityCheck)と OCR の段(ocrTextVisibilityCheck)は独立。**どちらも無ければ Tier-0 の幾何だけ**
    private func stageNoStageConfigured(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        let fmConfigured = fmVisibilityCheckEnabled && delegate != nil
        e.fmConfigured = fmConfigured
        // FM に画像を渡せるか(macOS 27+、かつ陽性対照の注入が無いこと)。false でも
        // スクショ・ink・OCR 近道までは進み、FM だけを撃たずに OCROnlyVisibility へ落ちる(V18)
        let fmAvailable = fmConfigured && FMVisionSupport.isSupported && !FMNoVerdictInjection.isActive(environment: ProcessInfo.processInfo.environment)
        e.fmAvailable = fmAvailable
        guard fmConfigured || occlusionOCRMode != .off else { return .pass(.keep) }
        return .next
    }

    /// V7 退化 frame(サイズ 0・クランプで潰れた等)は視覚照合の意味がないのでスキップ(素通り)
    private func stageDegenerateFrame(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        guard e.element.frame.width >= 1, e.element.frame.height >= 1, !e.expectedText.isEmpty else { return .pass(.keep) }
        return .next
    }

    /// V8 Compose が兄弟のタッチ範囲で削った枠は、切り抜きに使う前に戻す(全段 = インク・OCR・FM が同じ枠を見る)
    private func stageFrameRestore(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        let element = e.element
        let elements = e.elements
        if let restored = TouchOverhangFrameRestore.restoredFrame(for: element, in: elements) {
            e.element.frame = restored
            noteCodesThisStep.insert(.a11yFrameRestored)
        }
        return .next
    }

    /// V9 足切り: label が verbatim 描画されない要素(アイコン/画像/絵文字/結合セマンティクス)は
    /// FM で約50%誤反転する(実機確認)ため対象外=素通り(pass)。textEquals の期待値は結合規則を外す。
    /// 行(rowCheckByOCR)は型で落とさず、ラベルの規則(結合・記号のみ)だけを当てる
    private func stageEligibility(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        guard OcclusionEligibility.eligible(type: e.rowCheckByOCR ? "staticText" : e.element.type, label: e.expectedText,
                                            isUserText: e.expectedIsUserText,
                                            value: e.element.value, placeholder: e.element.placeholder,
                                            web: e.element.web).ok
        else { return .pass(.keep) }
        return .next
    }

    // MARK: - 段 V10〜V14(絵の確かめ)

    /// V10 操作を挟まない連続ガードでは直近スクショを再利用(~125ms 削減)。
    /// [StaleFrameDetector] キャッシュ供給(同一 Data 使い回し)は判定しない —— 供給元が
    /// guardScreenshot 自身なので比較すると木のわずかな揺れで必ず偽 stale になる(guardScreenshot 参照)。
    /// 新規撮影のときだけ「木は変わったのに絵が前回とバイト同一」を確認し、疑いなら1回だけ撮り直す。
    /// それでも stale なら古い絵を根拠に誤った緑反転を宣言せず素通りする(flip しない)。
    private func stageStaleFresh(_ e: inout VisibilityEvidence,
                                 phase: inout PhaseAccumulator) async throws -> VisibilityStageOutcome {
        let element = e.element
        let elements = e.elements
        let screen = e.screen
        let expectedText = e.expectedText
        let keyboardShown = e.keyboardShown
        let captured = try await guardScreenshot(keyboardShown: keyboardShown, phase: &phase)
        var screenshot = captured.data
        if captured.freshlyCaptured {
            // **両方の判定を同じ元の baseline に対して行う**(2回目の判定を1回目の record に対して
            // 行うと、elements はこの呼び出し内で不変なので treeFingerprint が必ず一致し
            // 「撮り直しても stale のまま」が原理的に起こり得なくなる)。
            let baseline = lastGuardFrameRecord
            let (record, isStale) = StaleFrameDetector.judge(
                png: screenshot, elements: elements, previous: baseline)
            lastGuardFrameRecord = record
            if isStale {
                invalidateScreenshotCache()
                let retaken = try await guardScreenshot(keyboardShown: keyboardShown, phase: &phase)
                let (record2, stillStale) = StaleFrameDetector.judge(
                    png: retaken.data, elements: elements, previous: baseline)
                lastGuardFrameRecord = record2
                if stillStale {
                    if await staleFrameShowsExpectedText(retaken.data, expectedText: expectedText,
                                                         element: element, screen: screen, phase: &phase) {
                        return .pass(.keep)
                    }
                    knownStaleGuardImageHash = record2.imageHash
                    noteCodesThisStep.insert(.staleScreenshot)
                    guardFrameStaleThisEval = true
                    return .pass(.keep)
                }
                screenshot = retaken.data
            }
        }
        e.screenshot = screenshot
        return .next
    }

    /// V11 前に古いと判定した絵のままなら、撮り直してもなお同じときは見送る(StaleFrameDetector.isKnownStale)。
    /// **使い回しの絵にも掛ける** —— 操作を挟まない連続した検証はスクショを使い回すので、新規撮影のときだけ
    /// 見ると select → textIs の形で古い絵を判定してしまう
    private func stageStaleKnown(_ e: inout VisibilityEvidence,
                                 phase: inout PhaseAccumulator) async throws -> VisibilityStageOutcome {
        let element = e.element
        let elements = e.elements
        let screen = e.screen
        let expectedText = e.expectedText
        var screenshot = e.screenshot
        if StaleFrameDetector.isKnownStale(png: screenshot, knownStaleImageHash: knownStaleGuardImageHash) {
            invalidateScreenshotCache()
            let retaken = try await guardScreenshot(keyboardShown: e.keyboardShown, phase: &phase)
            if StaleFrameDetector.isKnownStale(png: retaken.data, knownStaleImageHash: knownStaleGuardImageHash) {
                if await staleFrameShowsExpectedText(retaken.data, expectedText: expectedText,
                                                     element: element, screen: screen, phase: &phase) {
                    knownStaleGuardImageHash = nil
                    return .pass(.keep)
                }
                noteCodesThisStep.insert(.staleScreenshot)
                guardFrameStaleThisEval = true
                return .pass(.keep)
            }
            screenshot = retaken.data
            lastGuardFrameRecord = StaleFrameDetector.judge(png: screenshot, elements: elements, previous: nil).record
        }
        knownStaleGuardImageHash = nil
        e.screenshot = screenshot
        return .next
    }

    /// V12 Tier-0 幾何(ツリーのみ)で疑わしければインク量に関わらず FM へ(部分覆いの取りこぼし対策)。
    /// Tier-1 事前フィルタ: 幾何的に無罪 かつ 領域に明瞭なインクがあれば FM を省略して素通り(pass)。
    /// 疑いのある低インク領域(覆い/空/減光)だけ FM に回すことで FM 呼出を大幅削減する。
    /// sd は後続の launch-storyboard 判定(V14・V21・門)でも再利用する(同じ crop へ二重に払わない)。
    /// **門は消費しない**(可視と決まった緑)
    private func stageInkCutoff(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        let element = e.element
        let elements = e.elements
        let screen = e.screen
        let geo = OcclusionSuspicion.geometric(element: element, in: elements, screen: screen,
                                               looseMatch: e.looseMatch)
        var sd: Double?
        // 容器の縁に接した・外へ出た要素(行のラベル含む)は、切れて読めない文字でも枠の位置にインクがある(隣の要素のものを含む)ので足切りで通さず読ませる
        let atScrollEdge = OcclusionSuspicion.touchesScrollEdge(element: element, in: elements)
            || OcclusionSuspicion.isScrollLeftover(element: element, in: elements, screen: screen)
        if !geo, !atScrollEdge, occlusionInkThreshold > 0 {
            sd = RegionInk.luminanceStdDev(pngData: e.screenshot, frame: element.frame, screen: screen)
            if let value = sd, value >= occlusionInkThreshold {
                // 入力欄・ボタンは枠や背景で構造が出るので、文字が描けた証拠にするのは文字の型だけ
                if RenderCollapse.textTypes.contains(element.type.lowercased()) {
                    pixelsShowedTextThisStep = true
                    noteGreenText(element: element, expectedText: e.expectedText)
                }
                return .pass(.keep)
            }
        }
        e.geo = geo
        e.atScrollEdge = atScrollEdge
        e.sd = sd
        return .next
    }

    /// V13 黒い絵(撮れていない・表示の凍結)は FM も OCR も「描かれていない」と読むので判定の根拠にしない。
    /// V12 の後ろに置く = 素通りの回(大半)は PNG をもう一度復号しない
    private func stageBlackFrame(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        if BlankFrameDetector.isBlackApartFromSystemBars(pngData: e.screenshot) {
            noteCodesThisStep.insert(.blankScreenshot)
            return .pass(.keep)
        }
        return .next
    }

    /// V14 WebView の内側の文字の領域が一色で、木の上では覆われていない = WebView の層を取り逃した絵(同じ理由で根拠にしない)。
    /// 閾値は「画素に構造が無い」の定義(firstFrameBlankStdDevCeiling)を共有する。sd は V12 で測っていれば使い回す
    /// **覆いの疑いは幾何だけで見る** —— looseMatch(ロケータのラベルの部分一致)は領域が覆われているかと
    /// 無関係なのに geo へ混ざる(OcclusionSuspicion.geometric が部分一致で無条件に true)。混ぜると
    /// `"wv_result=*"` のようなロケータで撮り逃した WebView を「描かれていない」の誤った赤にしていた
    private func stageWebViewMiss(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        let element = e.element
        let elements = e.elements
        let screen = e.screen
        let screenshot = e.screenshot
        let coveredInTree = e.looseMatch
            ? OcclusionSuspicion.geometric(element: element, in: elements, screen: screen, looseMatch: false)
            : e.geo
        if !coveredInTree, BlankFrameDetector.enclosingWebViewFrame(of: element, in: elements) != nil {
            let targetStdDev = e.sd ?? RegionInk.luminanceStdDev(pngData: screenshot, frame: element.frame, screen: screen)
            if BlankFrameDetector.webViewCaptureMissed(insideWebView: true, geometricSuspicion: coveredInTree,
                                                       targetStdDev: targetStdDev,
                                                       ceiling: Self.firstFrameBlankStdDevCeiling) {
                noteCodesThisStep.insert(.webViewCaptureBlank)
                return .pass(.keep)
            }
        }
        return .next
    }

    // MARK: - 段 V15〜V18(OCR)

    /// V15 Tier-2(FM の手前)の準備: **近道を実際に撃つ時点でコンパイルが終わっていなければ、終わるまで待つ**(受け皿。ふつうは
    /// ScenarioHost.awaitOCRModelCompile が最初のシナリオを起こす前に compile-ocr を待ち終えている)。諦めた読みが走っている間は待たない
    /// (shouldTakeShortcut と同じ理由 — 詰まった読みの後ろに積み増さない)。待った時間は
    /// DeadlineExclusion 経由で締め切り(FTSync/scenarioTimeout)から差し引かれるので、
    /// ここで払っても呼び出し元のステップ/シナリオが不当に打ち切られない
    private func stageOCRCompileWait(_ e: inout VisibilityEvidence,
                                     phase: inout PhaseAccumulator) async -> VisibilityStageOutcome {
        let clock = ContinuousClock()
        if occlusionOCRMode != .off, RegionText.abandonedInFlight == 0, !RegionText.isModelReady {
            let waitStart = clock.now
            let waitOutcome = await RegionText.awaitModelCompile(mode: occlusionOCRMode)
            let waitedMs = Self.ms(clock.now - waitStart)
            if waitedMs > 0 {
                phase.guardMs += waitedMs
                phase.ocrMs += waitedMs
                noteCodesThisStep.insert(.ocrCompileWaited)
            }
            if case .capped = waitOutcome { noteCodesThisStep.insert(.ocrCompileCapped) }
        }
        return .next
    }

    /// V16 Tier-2(FM の手前): 期待テキストが Vision OCR で丸ごと読めれば見えている(FM を呼ばず素通り)。
    /// 実 run で FM の段に届いた crop の 97% がここで片付く(p50 92ms。FM は 1.3〜2.8s)。
    /// 丸ごと読めなかったこと自体は反転の根拠にしない(反転は V22 の FM との突き合わせか、FM の段が無いときの OCROnlyVisibility)。
    /// 詳細は RegionText のコメントと OG-5.17。off のときはこの段を通らない。**門は消費しない**(可視と決まった緑)
    private func stageOCRShortcut(_ e: inout VisibilityEvidence,
                                  phase: inout PhaseAccumulator) async -> VisibilityStageOutcome {
        let clock = ContinuousClock()
        if RegionText.shouldTakeShortcut(mode: occlusionOCRMode, ready: RegionText.isModelReady,
                                         abandonedInFlight: RegionText.abandonedInFlight) {
            // **この段は guardMs に計上する** —— スクショ(actionMs)と違いどの内訳にも入って
            // いなかった
            let ocrStart = clock.now
            switch await RegionText.resolveWithinBudget(expected: e.expectedText, pngData: e.screenshot,
                                                        frame: e.element.frame, screen: e.screen) {
            case .read(let readable, let reading):
                e.ocrReading = reading
                e.ocrReadable = readable
            case .unreadable:
                break
            case .budgetExhausted:
                // 近道が本道より高くついた。**黙らない** —— 率が上がれば Vision の劣化が分かる
                noteCodesThisStep.insert(.ocrBudgetExhausted)
            }
            let ocrElapsed = Self.ms(clock.now - ocrStart)
            phase.guardMs += ocrElapsed
            phase.ocrMs += ocrElapsed
            if occlusionOCRMode == .on, e.ocrReadable {
                pixelsShowedTextThisStep = true
                return .pass(.keep)
            }
        } else if occlusionOCRMode != .off {
            // 近道を見送った**理由**を残す(見送り自体は正しい判断。薄いテキストの witness が FM に
            // 落ちて反転した回に、未コンパイルか予算切れの読みが残っていたかを後から切り分けるため)
            noteCodesThisStep.insert(RegionText.isModelReady ? .ocrShortcutBusy : .ocrShortcutNotReady)
        }
        return .next
    }

    /// V17 行は**ここで OCR の読みだけで決める**(FM は呼ばない)。読めた文字があるのに期待文字列が無い・先頭だけのときだけ赤。
    /// 1行も読めない行はラベルが文字として描かれていない(アイコン・画像・色の箱のセル)ので赤にしない
    private func stageRowByOCR(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        guard e.rowCheckByOCR else { return .next }
        guard OCROnlyVisibility.rowLabelNotRead(lines: e.ocrReading?.lines, expected: e.expectedText) else { return .pass(.keep) }
        let read = (e.ocrReading?.lines ?? []).map { "\"\($0)\"" }.joined(separator: ", ")
        return .fail(.failed("text visibility check failed (on screen): present in the tree but the row's label \"\(e.expectedText)\""
            + " is not drawn in its frame — the text read there is \(read) (judged by OCR)"), .keep)
    }

    /// V18 OCR の読みだけの判定。**FM の段が使えるときは赤でも FM に回す**(ユーザー決定。最終判定は V22 の突き合わせ)。
    /// 読んでいない(nil)は judge が判定不能を返す。FM の段を使わない(fmTextVisibilityCheck off・delegate 無し)/
    /// 使えない(macOS 26・陽性対照の注入)なら OCR の読みだけで決める。**訊いてすらいない**ので visibilityGuardSkipped は立てない
    /// (「静的に無効な構成では出ない」契約を保つ。applyOCROnlyVisibility の countsAsSkipped)
    private func stageFMUnavailable(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        let element = e.element
        let elements = e.elements
        let screen = e.screen
        let screenshot = e.screenshot
        let expectedText = e.expectedText
        let ocrReading = e.ocrReading
        let fmConfigured = e.fmConfigured
        let ocrOnly = ocrOnlyOutcome(ocrReading: ocrReading, expectedText: expectedText, sd: e.sd,
                                     screenshot: screenshot, element: element, screen: screen)
        e.ocrOnly = ocrOnly
        let fmAvailable = e.fmAvailable
        guard fmAvailable, delegate != nil else {
            if occlusionOCRMode == .measure {
                dumpOCRCorpus(tier: e.geo ? "geo" : "ink", sd: e.sd, ocrReading: ocrReading,
                              ocrReadable: e.ocrReadable, expectedText: expectedText,
                              screenshot: screenshot, element: element, screen: screen,
                              fmVisible: nil, fmState: nil, fmObserved: nil)
            }
            let outcome = applyOCROnlyVisibility(ocrOnly, ocrReading: ocrReading, screenshot: screenshot, elements: elements,
                                                 element: element, screen: screen, countsAsSkipped: false,
                                                 fmGaveNoVerdict: fmConfigured)
            // 文字を読む段が両方とも無い(OCR 非対応 + FM 無し)のに通った = 描かれた文字は確かめていない。黙って緑にしない
            if case .pass = outcome, !OCRSupport.isSupported { noteCodesThisStep.insert(.visualTextCheckUnsupported) }
            return outcome
        }
        return .next
    }

    // MARK: - 段 V19〜V24(FM)

    /// V19 同じスクショ(バイト同一)・同じ frame・同じ期待文字列なら FM に訊き直さない
    /// (VisibilityVerdictMemo。答えは同じで、払うのは FM の数秒だけ)
    private func stageVerdictMemo(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        let memoKey = VisibilityVerdictMemo.key(frame: e.element.frame, screen: e.screen, expectedText: e.expectedText)
        let memoImageHash = StaleFrameDetector.hashBytes(e.screenshot)
        e.memoKey = memoKey
        e.memoImageHash = memoImageHash
        if let cached = visibilityVerdictMemo.lookup(imageHash: memoImageHash, key: memoKey) {
            e.verdict = cached
            e.verdictObtained = true
        }
        return .next
    }

    /// V20 控えが無ければ FM に訊く。答えが無ければ V18 と同じ出口(控えない)
    private func stageFMAsk(_ e: inout VisibilityEvidence,
                            phase: inout PhaseAccumulator) async -> VisibilityStageOutcome {
        if !e.verdictObtained {
            let clock = ContinuousClock()
            let element = e.element
            let elements = e.elements
            let screen = e.screen
            let screenshot = e.screenshot
            let expectedText = e.expectedText
            let ocrReading = e.ocrReading
            // FM の段も guardMs に入れる(fm は run 単位の集計で、ステップの内訳には出ない)
            let fmStart = clock.now
            // delegate は V6 で非 nil と確かめ済み(fmAvailable は fmConfigured を含む)。無ければ「無回答」と同じ出口
            let freshVerdict: VisibilityVerdictMemo.Verdict?
            if let delegate {
                freshVerdict = await delegate.verifyElementVisible(
                    expectedText: expectedText, frame: element.frame, screen: screen, screenshotPNG: screenshot)
            } else {
                freshVerdict = nil
            }
            phase.guardMs += Self.ms(clock.now - fmStart)
            guard let fresh = freshVerdict
            else {
                // **訊いたのに答えが無い**(FM の失敗・ブレーカ開・呼び出しの枠の待ちの期限切れ・画像不正)。
                // OCR/インクだけの代替判定へ落ちる(countsAsSkipped: true が visibilityGuardSkipped を立てる)。
                // **控えない**(次は必ず訊き直す)
                if occlusionOCRMode == .measure {
                    dumpOCRCorpus(tier: e.geo ? "geo" : "ink", sd: e.sd, ocrReading: ocrReading,
                                  ocrReadable: e.ocrReadable, expectedText: expectedText,
                                  screenshot: screenshot, element: element, screen: screen,
                                  fmVisible: nil, fmState: nil, fmObserved: nil)
                }
                return applyOCROnlyVisibility(e.ocrOnly, ocrReading: ocrReading, screenshot: screenshot, elements: elements,
                                              element: element, screen: screen, countsAsSkipped: true,
                                              fmGaveNoVerdict: true)
            }
            visibilityVerdictMemo.store(imageHash: e.memoImageHash, key: e.memoKey, verdict: fresh)
            e.verdict = fresh
            e.verdictObtained = true
        }
        if occlusionOCRMode == .measure {
            dumpOCRCorpus(tier: e.geo ? "geo" : "ink", sd: e.sd, ocrReading: e.ocrReading,
                          ocrReadable: e.ocrReadable, expectedText: e.expectedText,
                          screenshot: e.screenshot, element: e.element, screen: e.screen,
                          fmVisible: e.verdict.visible, fmState: e.verdict.state, fmObserved: e.verdict.observedText)
        }
        return .next
    }

    /// V21 **FM の転写が空なのに要素の領域に構造がある**事実(判定は変えない。率を見る)。空の転写は呼び出しとしては
    /// 成功なので FMHealth / FMLiveness に出ず、OCR の近道が撃てない機械では FM の1回の空振りがそのまま赤になる
    /// (実測: 赤 157 件のうち 17 件が読める文字への空の転写 → MN-84.4)。構造の有無は
    /// firstFrameBlankStdDevCeiling(「画素に構造が無い」の定義)で分ける = 白紙・一色の画面では立たない
    private func stageEmptyTranscript(_ e: inout VisibilityEvidence,
                                      phase: inout PhaseAccumulator) async -> VisibilityStageOutcome {
        let v = e.verdict
        let element = e.element
        let screen = e.screen
        let screenshot = e.screenshot
        let expectedText = e.expectedText
        let sd = e.sd
        guard !v.visible, v.observedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let ink = sd ?? RegionInk.luminanceStdDev(pngData: screenshot, frame: element.frame, screen: screen),
              ink > Self.firstFrameBlankStdDevCeiling
        else { return .next }
        let clock = ContinuousClock()
        // **OCR の段がオンで、近道が撃てなかった(読みが無い)ときだけ**、同じ領域を OCR に読ませて確かめる。
        // 近道は「起動時の探りが読めた」ことを条件にするので、負荷の下ではそのプロセスの最初のガードで撃てず、
        // FM の1回の空振りがそのまま赤になった(MN-92.1)。OCR は素通りの根拠にだけ使う
        // (丸ごと読めたら緑・読めなければ判定は FM のまま)。**オフの構成では読まない**(利用者が切った段を使わない)
        var ocrConfirmationFact = ""
        if occlusionOCRMode == .on, e.ocrReading == nil {
            let ocrStart = clock.now
            var confirmation = await RegionText.resolveWithinBudget(
                expected: expectedText, pngData: screenshot, frame: element.frame, screen: screen,
                budget: Self.emptyTranscriptOCRBudget)
            // ここへ来るのは近道の準備ができていない(このプロセスの Vision がまだ空を返す)ときなので、確かめの読みも
            // 空で返りやすい。空なら読めるようになるまで待って1回だけ読み直す(誤読は読み直さない = 読めている Vision の答え)
            if Self.confirmationSawNothing(confirmation), await awaitReadableVision() {
                confirmation = await RegionText.resolveWithinBudget(
                    expected: expectedText, pngData: screenshot, frame: element.frame, screen: screen,
                    budget: Self.emptyTranscriptOCRBudget)
            }
            let ocrElapsed = Self.ms(clock.now - ocrStart)
            phase.guardMs += ocrElapsed
            phase.ocrMs += ocrElapsed
            if case .read(readable: true, _) = confirmation {
                noteCodesThisStep.insert(.ocrReadWhatFMMissed)
                pixelsShowedTextThisStep = true
                return .pass(.consume(visible: true, sd: sd))
            }
            ocrConfirmationFact = Self.emptyTranscriptOCRFact(confirmation)
        }
        // **OCR で確かめられなかった回は FM に1回だけ訊き直す**: OCR の段がオフ、またはオンでも確かめの読みが読めなかった
        // (Vision が空を返した = 突き合わせる相手が居ない)
        if occlusionOCRMode == .off || (occlusionOCRMode == .on && e.ocrReading == nil),
           reaskedEmptyTranscripts.insert(ReaskKey(imageHash: e.memoImageHash, key: e.memoKey)).inserted {
            // 訊き直す理由: 空振りがそのまま赤になる。
            // **同じ絵には1回だけ**(控えが空振りの答えを返す撮り直しの周ごとに訊き直さない = reaskedEmptyTranscripts)。
            // 計測(.measure)は訊き直さない(採取した FM の判定と結果が食い違う)。
            // 訊き直しで読めたら緑・控えも読めた答えに替える(空振りの答えを次の周へ持ち越さない)
            let retryStart = clock.now
            let retried: VisibilityVerdictMemo.Verdict?
            if let delegate {
                retried = await delegate.verifyElementVisible(
                    expectedText: expectedText, frame: element.frame, screen: screen, screenshotPNG: screenshot)
            } else {
                retried = nil
            }
            phase.guardMs += Self.ms(clock.now - retryStart)
            if let retried, retried.visible {
                visibilityVerdictMemo.store(imageHash: e.memoImageHash, key: e.memoKey, verdict: retried)
                // 空の転写の注記も残す(マシンの健全性の「FM が読める文字を落とす率」を、救えた回で数え落とさない)
                noteCodesThisStep.insert(.fmEmptyTranscriptOnInk)
                noteCodesThisStep.insert(.fmReaskedEmptyTranscript)
                notePartialVisibility(TranscriptMatch.State(rawValue: retried.state))
                pixelsShowedTextThisStep = true
                return .pass(.consume(visible: true, sd: sd))
            }
        }
        noteCodesThisStep.insert(.fmEmptyTranscriptOnInk)
        e.emptyTranscriptOnInk = " — FM transcribed nothing, but the element's area is not blank"
            + " (luminance stdDev \(String(format: "%.1f", ink)))" + ocrConfirmationFact
        return .next
    }

    /// V22 **OCR と FM の突き合わせ: 見えていると読めた側を採る**(赤はどちらも見えないと言った回だけ)。
    /// どちらも期待文字列を知らずに読んだ文字を同じ TranscriptMatch で照合するので、「読めた」は描かれている
    /// 直接の証拠で、「読めなかった」は読み手の失敗でも起きる(OCR の短い文字列の誤読・FM の字形の取り違え)。
    /// 根拠と実測は OG-5.22。measure は FM の判定を採取するので突き合わせない。
    /// **起動直後の門はここで消費する(可視・不可視とも)** —— launch 直後(noteAppLaunched)は launch storyboard(全画素同一 =
    /// crop の stdDev が厳密に 0)を実 occlusion と見分けられない。門は一度きりで、可視なら描画は済んでいるので猶予は要らない。
    /// blank だったときだけ StepExecutor 側のフラグを立てる。**flip 自体は今までどおり返す**
    /// (nil にして素通りさせると誤った緑になる。呼び出し側の poll ループが deadline を一度だけ延ばす)。
    /// 不可視の消費は続く V23・V24 の出口が運ぶ(どちらかが必ず返す)
    private func stageReconcile(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        let v = e.verdict
        let ocrOnly = e.ocrOnly
        let merged = OCROnlyVisibility.merge(fmVisible: v.visible, fmState: TranscriptMatch.State(rawValue: v.state),
                                             ocr: occlusionOCRMode == .on ? ocrOnly.outcome : .undetermined)
        if let note = merged.disagreement { noteCodesThisStep.insert(note) }
        guard merged.visible else { return .next }
        notePartialVisibility(merged.state)
        pixelsShowedTextThisStep = true
        if merged.state == .fullyVisible { noteGreenText(element: e.element, expectedText: e.expectedText) }
        return .pass(.consume(visible: true, sd: e.sd))
    }

    /// V23 FM が読んだ文字が「この要素の1つ前の緑の値」なら、文字の不一致ではなく古い絵として既存の経路へ合流する
    /// (締め切りまで撮り直し、最後まで古ければ素通り + stale-screenshot。判定は StaleFrameDetector.showsPreviousValue)
    private func stagePreviousValueStale(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        let v = e.verdict
        if v.state == TranscriptMatch.State.textMismatch.rawValue,
           let id = Self.greenTextKey(e.element),
           StaleFrameDetector.showsPreviousValue(observed: v.observedText, expected: e.expectedText,
                                                 previous: lastGreenTextByElement[id]) {
            knownStaleGuardImageHash = e.memoImageHash
            noteCodesThisStep.insert(.staleScreenshot)
            guardFrameStaleThisEval = true
            return .pass(.consume(visible: false, sd: e.sd))
        }
        return .next
    }

    /// V24 FM の赤。observedText は原因切り分けの鍵: 空なら「FM に画像が渡っていない/白紙を見た」
    /// (SCA 劣化で添付が落ちる仮説・起動遷移画面)、期待どおりの文字列なら「読めたのに
    /// 覆われていると答えた」= 純粋な判定誤り。これが無くて切り分けに窮した。
    private func stageFMRed(_ e: inout VisibilityEvidence) -> VisibilityStageOutcome {
        let v = e.verdict
        if v.state == TranscriptMatch.State.notRendered.rawValue {
            lastNotRenderedFrame = (e.screenshot, e.elements, e.screen)
        }
        return .fail(.failed("text visibility check failed (on screen): present in the tree but not visually visible [\(v.state)] \(v.reason)"
                             + " observed=\"\(v.observedText)\""
                             + e.emptyTranscriptOnInk
                             + Self.undrawnScreenFact(screenshot: e.screenshot, elements: e.elements, screen: e.screen,
                                                      keyboard: guardKeyboardFrame, inkThreshold: occlusionInkThreshold)),
                     .consume(visible: false, sd: e.sd))
    }

    // MARK: - 補助

    /// 空の転写を確かめた OCR が「読めた」以外を返したときの事実(判定は変えない)。無いと、同じ絵を後から読むと
    /// 読めるのに赤だった回(負荷テストの E2E-CMP の `wv_result=-`)で、OCR の誤読か Vision の不調かを読み分けられない
    static func emptyTranscriptOCRFact(_ confirmation: RegionText.BudgetedReading) -> String {
        switch confirmation {
        case .read(readable: true, _):
            return ""
        case .read(readable: false, let reading):
            let lines = reading.lines.joined(separator: " / ")
            return lines.isEmpty ? "; OCR found no text there"
                : "; OCR read \"\(lines.prefix(Self.ocrFactMaxCharacters))\" there, not the expected text"
        case .unreadable:
            return "; OCR returned no reading (the crop could not be made or Vision failed)"
        case .budgetExhausted:
            return "; OCR did not finish within \(Self.emptyTranscriptOCRBudget)"
        }
    }

    /// 確かめの読みが**何も返さなかった**か(空の行・読み自体が無い)。誤読(何か読めた)と予算切れは含めない
    static func confirmationSawNothing(_ confirmation: RegionText.BudgetedReading) -> Bool {
        switch confirmation {
        case .read(readable: false, let reading): return reading.lines.isEmpty
        case .unreadable: return true
        case .read(readable: true, _), .budgetExhausted: return false
        }
    }

    /// 失敗文に載せる OCR の読みの上限(文字)。行が長い画面で失敗文が埋もれない程度
    static let ocrFactMaxCharacters = 80

    /// 絵の**アプリ領域全体が一色**だったときに失敗文へ添える事実(そうでなければ空文字)。判定は変えない —— テキストの
    /// 可視性検証は白を「描かれていない」の事実として扱う(`BlankFrameDetector.isUnjudgeable` の doc)。添えないと、
    /// 1つの要素が隠れているのか画面全体に何も描かれていないのかを読み分けられない(実測: XCUITest の run で CMP の画面が
    /// 真っ白に撮れ、木は中身を持つのに、要素ごとに「木にはあるが見えない」と 18 本が赤になった)。失敗の経路だけで払う
    /// **上端で除く帯は木から決める**(いちばん上の要素の上端まで・下限は従来の2行)。ステータスバーの高さは機種で違い
    /// (iPhone 17 Pro は 62pt = 7.1% で、固定の2行 = 6.25% から時計がはみ出して一色と判定されなかった)、
    /// 一律に増やすと上端近くにだけ中身のある画面を「何も描かれていない」と言う。上端近くの中身は木に載るので帯は広がらない
    static func blankAppAreaFact(screenshot: Data, elements: [ElementInfo], screen: FTRect) -> String {
        let contentTop = elements.map(\.frame.y).filter { $0 > screen.y }.min().map { $0 - screen.y } ?? 0
        let rows = screen.height > 0
            ? Int((contentTop / screen.height * Double(BlankFrameDetector.blackFrameGrid)).rounded(.up)) : 0
        guard BlankFrameDetector.isUniform(pngData: screenshot,
                                           ignoringTopRows: max(rows, BlankFrameDetector.blackFrameIgnoredTopRows))
        else { return "" }
        return " — the whole app area of the screenshot is a single colour (nothing is drawn anywhere on screen,"
            + " not just at this element)"
    }

    /// 失敗文へ添える「画面全体が描かれていない」の事実。一色(`blankAppAreaFact`)でなければ、**枠は描けて文字だけが
    /// 画面のどこにも描かれていない**形(描画崩壊の `RenderCollapse.noTextDrawn` と同じ基準 = 描画崩壊の判定と
    /// 「描かれている」の定義を共有する)を確かめる。添えないと、1つの要素の問題か端末側の描画の崩れかを読み分けられない
    /// (実測: Simulator の CMP で文字だけが画面ごと消え、要素ごとの「木にはあるが見えない」として赤になった)
    static func undrawnScreenFact(screenshot: Data, elements: [ElementInfo], screen: FTRect,
                                  keyboard: FTRect?, inkThreshold: Double) -> String {
        let blank = blankAppAreaFact(screenshot: screenshot, elements: elements, screen: screen)
        guard blank.isEmpty else { return blank }
        guard case .noTextDrawn(let count) = RenderCollapse.judge(
            pngData: screenshot, elements: elements, screen: screen, keyboard: keyboard,
            inkThreshold: inkThreshold, minimumTextElements: RenderCollapse.minimumTextElements) else { return "" }
        return " — none of the \(count) text element(s) the tree reports on screen is drawn in the screenshot"
            + " (not just this element; shapes may be drawn, text is not)"
    }

    /// 「絵が古い」(StaleFrameDetector: 絵はバイト同一なのに木が変わった)と判定した絵に、**期待する文字が
    /// 丸ごと描かれていれば古くない**とみなす(true = 見送らず合格にしてよい)。木が絵より遅れる画面では、
    /// 絵は既に新しい状態なのに木が後から追いつき、同じ条件を満たす(実測: Compose の iOS で
    /// スイッチを叩いた直後、絵は `location=on` なのに木は `location=off`。静止した画面の絵が変わるのを
    /// 撮り直しの予算いっぱい待っていた)。本当に古い絵(E2E-RN の WebView で `wv_result=-` のまま)には
    /// 期待する文字が無いので従来どおり待つ。OCR の近道が撃てない(off・未コンパイル・詰まり)ときは確かめない
    private func staleFrameShowsExpectedText(_ png: Data, expectedText: String, element: ElementInfo,
                                             screen: FTRect, phase: inout PhaseAccumulator) async -> Bool {
        guard RegionText.shouldTakeShortcut(mode: occlusionOCRMode, ready: RegionText.isModelReady,
                                            abandonedInFlight: RegionText.abandonedInFlight) else { return false }
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await RegionText.resolveWithinBudget(expected: expectedText, pngData: png,
                                                           frame: element.frame, screen: screen)
        let elapsed = Self.ms(clock.now - start)
        phase.guardMs += elapsed
        phase.ocrMs += elapsed
        guard case .read(let readable, _) = outcome, readable else { return false }
        noteCodesThisStep.insert(.staleFrameTextVisible)
        return true
    }

    /// launch 直後の一度きりの門(DS-24.4)。**呼ぶのは `applyFirstFrameGate` だけ**。FM の判定と OCR だけの判定の両方が
    /// 判定を出した回に消費する —— 片方だけにすると、FM が答えない run で launch storyboard を覆いと読む
    private func consumeFirstFrameGate(visible: Bool, sd: Double?, screenshot: Data,
                                       element: ElementInfo, screen: FTRect) {
        guard firstFrameGatePending else { return }
        firstFrameGatePending = false
        if !visible,
           let blank = sd ?? RegionInk.luminanceStdDev(pngData: screenshot,
                                                        frame: element.frame, screen: screen),
           blank < Self.firstFrameBlankStdDevCeiling {
            firstFrameBlankObserved = true
        }
    }

    /// 緑で抜けた要素の文字を控える(`lastGreenTextByElement`)。操作では消さない —— 操作を挟んだ後の古い絵を見分ける材料
    private func noteGreenText(element: ElementInfo, expectedText: String) {
        guard let id = Self.greenTextKey(element) else { return }
        lastGreenTextByElement[id] = expectedText
    }

    static func greenTextKey(_ element: ElementInfo) -> String? {
        element.identifier.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 緑の判定のうち、先頭だけ読めた形を注記に残す(FM の判定と OCR だけの判定の両方から呼ぶ)
    private func notePartialVisibility(_ state: TranscriptMatch.State?) {
        switch state {
        case .partiallyHidden: noteCodesThisStep.insert(.textPartiallyHidden)
        case .ellipsized: noteCodesThisStep.insert(.textEllipsized)
        default: break
        }
    }

    /// OCR の読みとインク量だけの判定(`OCROnlyVisibility`)を段の出口にする。呼ぶのは2つの場合 ——
    /// ①不可視と言い切れた回(FM の有無に関わらず FM を省く)②FM が判定を返せない回(macOS 26・
    /// 陽性対照の注入・実呼び出しの失敗)。**不可視なら FM の反転と同じく赤**。
    /// `countsAsSkipped` は FM に**実際に訊いた**のに答えが無かった回だけ true
    /// (macOS 26・注入・①は訊いていないので `visibilityGuardSkipped` を立てない)。
    /// `fmGaveNoVerdict` は失敗文言の出し分けだけに使う。
    /// 門: 可視・不可視は消費(sd は judge が測ったインク量)、判定不能は残す
    private func applyOCROnlyVisibility(_ judged: (outcome: OCROnlyVisibility.Outcome, ink: Double?),
                                        ocrReading: RegionText.Reading?, screenshot: Data, elements: [ElementInfo],
                                        element: ElementInfo, screen: FTRect, countsAsSkipped: Bool,
                                        fmGaveNoVerdict: Bool) -> VisibilityStageOutcome {
        let ink = judged.ink
        switch judged.outcome {
        case .visible(let state):
            notePartialVisibility(state)
            pixelsShowedTextThisStep = true
            return .pass(.consume(visible: true, sd: ink))
        case .notVisible(let state):
            if countsAsSkipped { noteCodesThisStep.insert(.visibilityGuardSkipped) }
            // FM の反転と同じ扱い(呼び出し側の poll が見えるまで撮り直し、尽きたら赤)
            if state == .notRendered {
                lastNotRenderedFrame = (screenshot, elements, screen)
            }
            let judgedBy = fmGaveNoVerdict ? "judged by OCR alone because FM gave no verdict" : "judged by OCR"
            return .fail(.failed("text visibility check failed (on screen, \(judgedBy)):"
                                 + " present in the tree but not visually visible [\(state.rawValue)]"
                                 + " observed=\"\(ocrReading.map { $0.lines.joined(separator: " ") } ?? "")\""
                                 + Self.undrawnScreenFact(screenshot: screenshot, elements: elements, screen: screen,
                                                          keyboard: guardKeyboardFrame, inkThreshold: occlusionInkThreshold)),
                         .consume(visible: false, sd: ink))
        case .undetermined:
            if countsAsSkipped { noteCodesThisStep.insert(.visibilityGuardSkipped) }
            return .pass(.keep)
        }
    }

    /// 同じ呼び出しの中で既に読んだ `ocrReading`(近道が撃たれていなければ nil = 判定不能)と
    /// `sd`(無ければここで測る)だけで判定する —— **追加の OCR は撃たない**
    private func ocrOnlyOutcome(ocrReading: RegionText.Reading?, expectedText: String, sd: Double?,
                                screenshot: Data, element: ElementInfo,
                                screen: FTRect) -> (outcome: OCROnlyVisibility.Outcome, ink: Double?) {
        // インク量を judge が使うのは「読んで何も無かった」ときだけ。それ以外で測らない —— PNG 全体の
        // 復号を FM の前(OCR off を含む全回)に払うことになる。nil は consumeFirstFrameGate が自分で測る
        let ink = sd ?? (ocrReading?.lines.isEmpty == true
            ? RegionInk.luminanceStdDev(pngData: screenshot, frame: element.frame, screen: screen) : nil)
        return (OCROnlyVisibility.judge(lines: ocrReading?.lines, expected: expectedText,
                                        inkStdDev: ink, inkThreshold: occlusionInkThreshold), ink)
    }

    /// [occlusion-guard Tier-2 measure] OCR と FM の判定を並べてコーパスへ書く。run の成否には
    /// 影響しない(`OcclusionCorpusDump.write` が書き出し失敗を握りつぶす)
    private func dumpOCRCorpus(tier: String, sd: Double?, ocrReading: RegionText.Reading?,
                               ocrReadable: Bool, expectedText: String, screenshot: Data,
                               element: ElementInfo, screen: FTRect,
                               fmVisible: Bool?, fmState: String?, fmObserved: String?) {
        let entry = OcclusionCorpusDump.Entry(
            expectedText: expectedText, tier: tier, inkStdDev: sd,
            ocrLines: ocrReading?.lines ?? [], ocrReadable: ocrReadable,
            ocrMs: ocrReading?.elapsedMs ?? 0, fmVisible: fmVisible, fmState: fmState,
            fmObserved: fmObserved)
        OcclusionCorpusDump.write(pngData: screenshot, frame: element.frame, screen: screen, entry: entry)
    }
}
