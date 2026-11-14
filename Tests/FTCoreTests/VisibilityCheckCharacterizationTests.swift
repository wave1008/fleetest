// テキストの可視性検証(occlusion-guard。`StepExecutor.occlusionFlip` → `occlusionFlipOnScreen`)の**今の挙動を出口ごとに等号で固定する特性テスト**。
// 段の並べ替え・宣言化のリファクタが挙動を変えていないことを確かめる物差しで、期待値は「今こう出る」の記録(正しさの判断は含まない)。
// 1行 = 合否の種類(失敗なら失敗文の先頭の分類部分)・注記の集合・FM の呼び出し回数・起動直後の門・黒い絵の観測・画素で文字が見えたか。
// 駆動は production の入口(`StepExecutor.execute`)だけ。行ラベル V1〜V24 は各テストの doc コメントに対応する。
import XCTest
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import FTCore

final class VisibilityCheckCharacterizationTests: XCTestCase {

    // MARK: - 部品

    private static let label = "こんにちは"

    private static func element(id: String = "msg", label: String = VisibilityCheckCharacterizationTests.label,
                                type: String = "staticText", ref: Int = 1,
                                frame: FTRect = FTRect(x: 0, y: 0, width: 100, height: 20), depth: Int = 0,
                                z: Int? = nil, scrollable: Bool? = nil) -> ElementInfo {
        var e = ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                            placeholder: nil, enabled: true, frame: frame, depth: depth)
        e.z = z
        e.scrollable = scrollable
        return e
    }

    private static let fullFrame = FTRect(x: 0, y: 0, width: 400, height: 800)

    /// 400x800 の白地に文字を描いた PNG(要素の枠が全画面なら crop は全画面)
    private static func textPNG(_ text: String) -> Data {
        let width = 400, height = 800
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("CGContext") }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)])
        ctx.textPosition = CGPoint(x: 20, y: CGFloat(height) / 2)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        return encode(ctx)
    }

    /// 黒一色(BlankFrameDetector.isBlackApartFromSystemBars が真になる絵)
    private static let blackPNG: Data = {
        guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("CGContext") }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return encode(ctx)
    }()

    private static func encode(_ ctx: CGContext) -> Data {
        guard let image = ctx.makeImage() else { fatalError("CGImage") }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { fatalError("dest") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { fatalError("finalize") }
        return output as Data
    }

    /// FM が observedText と state を指定どおりに返す偽 delegate(`FakeVisibilityDelegate` は observedText を返さない)
    private final class ScriptedVerdictDelegate: ReplayDelegate {
        struct Verdict { var visible: Bool; var state: String; var observed: String }
        private let verdicts: [Verdict]
        private(set) var calls = 0
        init(_ verdicts: [Verdict]) { self.verdicts = verdicts }
        func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? { nil }
        func verifyElementVisible(expectedText: String, frame: FTRect, screen: FTRect,
                                  screenshotPNG: Data) async
            -> (visible: Bool, state: String, reason: String, observedText: String)? {
            let v = verdicts[min(calls, verdicts.count - 1)]
            calls += 1
            return (v.visible, v.state, "scripted", v.observed)
        }
    }

    /// 1ステップぶんの観測を1行へ畳む
    private struct Rig {
        let executor: StepExecutor
        let driver: FakeAppDriver
        let fmCalls: () -> Int

        func step(timeout: Double = 0, guardOn: Bool = true, id: String = "msg") async -> String {
            let outcome = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: id),
                                                          timeout: timeout, occlusionGuard: guardOn))
            let result: String
            switch outcome.status {
            case .passed: result = "passed"
            case .failed(let message): result = "failed " + (message.components(separatedBy: ":").first ?? message)
            default: result = "other \(outcome.status)"
            }
            // slow-snapshot は所要(timeout 0 の予算を偽ドライバの撮影が越えたか)だけで決まり、負荷の下で揺れる。判定の流れの出口ではないので外す
            let notes = outcome.notes.filter { $0 != .slowSnapshot }.map(\.rawValue).sorted().joined(separator: ",")
            return "\(result) | notes=[\(notes)] | fm=\(fmCalls()) | gate=\(executor.firstFrameGatePending)"
                + " | blank=\(executor.firstFrameBlankObserved) | pixels=\(executor.pixelsShowedTextThisStep)"
        }
    }

    private func rig(_ trees: [[ElementInfo]], shots: [Data], delegate: ReplayDelegate?,
                     ocr: RegionTextGateMode = .off, ink: Double = 12, fmEnabled: Bool = true,
                     armGate: Bool = false, isAndroid: Bool = false, uiFramework: AppUIFramework? = nil) -> Rig {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: trees, screenshots: shots)
        let executor = StepExecutor(driver: driver, delegate: delegate, occlusionInkThreshold: ink,
                                    occlusionOCRMode: ocr, fmVisibilityCheckEnabled: fmEnabled,
                                    isAndroid: isAndroid, tunables: RunTunables(), uiFramework: uiFramework)
        if armGate { executor.noteAppLaunched() }
        let calls: () -> Int
        switch delegate {
        case let d as FakeVisibilityDelegate: calls = { d.visibleCalls }
        case let d as NoVerdictVisibilityDelegate: calls = { d.visibleCalls }
        case let d as SequenceVisibilityDelegate: calls = { d.calls }
        case let d as ScriptedVerdictDelegate: calls = { d.calls }
        default: calls = { 0 }
        }
        return Rig(executor: executor, driver: driver, fmCalls: calls)
    }

    private func check(_ name: String, _ actual: String, _ expected: String, line: UInt = #line) {
        XCTAssertEqual(actual, expected, name, line: line)
    }

    /// `lines` を渡すと判定の読み(Vision)をその行で決める(`RegionText.readRecognizeOverrideForTesting`。負荷の下で本物の Vision が
    /// 予算を越えて揺れるのを避ける)。nil = 差し替えない(読みが走らない構成だけ)。必ず nil に戻す
    private func withModelReady<T>(_ ready: Bool, compileFinish: Bool = false, lines: [String]? = nil,
                                   _ body: () async -> T) async -> T {
        RegionText.modelReadyOverrideForTesting = ready
        if compileFinish { RegionText.modelCompileFinishOverrideForTesting = {} }
        if let lines { RegionText.readRecognizeOverrideForTesting = { _ in lines } }
        defer {
            RegionText.modelReadyOverrideForTesting = nil
            RegionText.modelCompileFinishOverrideForTesting = nil
            RegionText.readRecognizeOverrideForTesting = nil
        }
        return await body()
    }

    private func withFMNoVerdictInjection<T>(_ body: () async -> T) async -> T {
        let saved = ProcessInfo.processInfo.environment[FMNoVerdictInjection.environmentKey]
        setenv(FMNoVerdictInjection.environmentKey, "1", 1)
        defer {
            if let saved { setenv(FMNoVerdictInjection.environmentKey, saved, 1) }
            else { unsetenv(FMNoVerdictInjection.environmentKey) }
        }
        return await body()
    }

    private let blank = StepExecutorTests.blankPNG
    private let inked = StepExecutorTests.inkedPNG
    private let nearBlank = StepExecutorTests.nearBlankPNG

    // MARK: - Tier-0・入口

    /// V1: 入口(ステップの occlusionGuard が false)→ 素通り。門は消費しない
    func testV1GuardDisabledPassesThrough() async {
        let delegate = FakeVisibilityDelegate(visible: false)
        let r = rig([[Self.element()]], shots: [blank], delegate: delegate, armGate: true)
        check("V1", await r.step(guardOn: false), "passed | notes=[] | fm=0 | gate=true | blank=false | pixels=false")
    }

    /// V2: 画面外(中心が画面外)→ 赤(offscreen)。門は消費しない
    func testV2OffscreenCentreFails() async {
        let delegate = FakeVisibilityDelegate(visible: true)
        let e = Self.element(frame: FTRect(x: 0, y: 1000, width: 100, height: 20))
        let r = rig([[e]], shots: [blank], delegate: delegate, armGate: true)
        check("V2", await r.step(), "failed text visibility check failed (offscreen) | notes=[] | fm=0 | gate=true | blank=false | pixels=false")
    }

    /// V3: 塗り順が本物の木(全要素が z を持つ)で、覆いの下にある要素 → 注記 covered-by-front-element(合否は変えない)
    func testV3CoveredByFrontElementNote() async {
        let target = Self.element(ref: 1, z: 0)
        let cover = Self.element(id: "cover", label: "cover", type: "button", ref: 2, z: 1)
        let delegate = FakeVisibilityDelegate(visible: true)
        let r = rig([[target, cover]], shots: [blank], delegate: delegate)
        check("V3", await r.step(), "passed | notes=[covered-by-front-element] | fm=1 | gate=false | blank=false | pixels=true")
    }

    /// V8: Compose の削られた枠の復元(対象の下端に、容器の上端より上へはみ出した要素の上端が接している)→ 注記 a11y-frame-restored
    func testV8TouchOverhangFrameRestoredNote() async {
        let target = Self.element(ref: 1, frame: FTRect(x: 0, y: 100, width: 100, height: 20))
        let container = Self.element(id: "list", label: "list", type: "scrollView", ref: 2,
                                     frame: FTRect(x: 0, y: 200, width: 400, height: 600), depth: 0, scrollable: true)
        let overhang = Self.element(id: "row", label: "row", type: "button", ref: 3,
                                    frame: FTRect(x: 0, y: 120, width: 100, height: 50), depth: 1)
        let delegate = FakeVisibilityDelegate(visible: true)
        let r = rig([[target, container, overhang]], shots: [blank], delegate: delegate)
        check("V8", await r.step(), "passed | notes=[a11y-frame-restored] | fm=1 | gate=false | blank=false | pixels=true")
    }

    // MARK: - 足切り

    /// V6: FM の段も OCR の段も無い(delegate nil かつ OCR off)→ 素通り
    func testV6NoStagesPassesThrough() async {
        let r = rig([[Self.element()]], shots: [blank], delegate: nil)
        check("V6", await r.step(), "passed | notes=[] | fm=0 | gate=false | blank=false | pixels=false")
    }

    /// V6': FM の段を切り(fmVisibilityCheckEnabled false)OCR も off → 素通り(delegate はあっても呼ばない)
    func testV6FMStageOffAndOCROffPassesThrough() async {
        let delegate = FakeVisibilityDelegate(visible: false)
        let r = rig([[Self.element()]], shots: [blank], delegate: delegate, fmEnabled: false)
        check("V6b", await r.step(), "passed | notes=[] | fm=0 | gate=false | blank=false | pixels=false")
    }

    /// V7: 退化した枠(幅 0)→ 素通り
    func testV7DegenerateFramePassesThrough() async {
        let delegate = FakeVisibilityDelegate(visible: false)
        let e = Self.element(frame: FTRect(x: 0, y: 0, width: 0, height: 20))
        let r = rig([[e]], shots: [blank], delegate: delegate)
        check("V7", await r.step(), "passed | notes=[] | fm=0 | gate=false | blank=false | pixels=false")
    }

    /// V9: 対象の足切り(画像の型は eligible でない)→ 素通り
    func testV9IneligibleTypePassesThrough() async {
        let delegate = FakeVisibilityDelegate(visible: false)
        let r = rig([[Self.element(type: "image")]], shots: [blank], delegate: delegate)
        check("V9", await r.step(), "passed | notes=[] | fm=0 | gate=false | blank=false | pixels=false")
    }

    /// V5: 文字の型でない要素(ボタン)は、同じ label の文字の子が1つならその子で確かめる(FM が1回呼ばれる)。
    /// 子が無いボタンは足切りで素通り(FM 0 回)
    func testV5SameLabelTextChildSubstitution() async {
        let button = Self.element(id: "msg", type: "button", ref: 1, frame: FTRect(x: 0, y: 0, width: 200, height: 40))
        let child = Self.element(id: "child", type: "staticText", ref: 2, frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 1)
        let d1 = FakeVisibilityDelegate(visible: true)
        let r1 = rig([[button, child]], shots: [blank], delegate: d1)
        check("V5 with child", await r1.step(), "passed | notes=[] | fm=1 | gate=false | blank=false | pixels=true")
        let d2 = FakeVisibilityDelegate(visible: true)
        let r2 = rig([[button]], shots: [blank], delegate: d2)
        check("V5 without child", await r2.step(), "passed | notes=[] | fm=0 | gate=false | blank=false | pixels=false")
    }

    // MARK: - 古い絵・インク・黒い絵・WebView

    /// V10: 古い絵(木が変わったのに絵がバイト同一)→ 素通り + stale-screenshot。同じ executor で2ステップ
    func testV10StaleFramePassesWithNote() async {
        let delegate = FakeVisibilityDelegate(visible: true)
        let first = Self.element(ref: 1)
        let second = [Self.element(ref: 1), Self.element(id: "extra", label: "extra", ref: 2, frame: FTRect(x: 0, y: 100, width: 50, height: 20))]
        let r = rig([[first], second], shots: [blank], delegate: delegate, ink: 0)
        check("V10 step1", await r.step(), "passed | notes=[] | fm=1 | gate=false | blank=false | pixels=true")
        r.executor.invalidateScreenshotCache()
        check("V10 step2", await r.step(), "passed | notes=[stale-screenshot] | fm=1 | gate=false | blank=false | pixels=false")
    }

    /// V11: 既知の古い絵(V10 の後、木は変えず同じ絵のまま3ステップ目)→ 素通り + stale-screenshot
    func testV11KnownStaleFramePassesWithNote() async {
        let delegate = FakeVisibilityDelegate(visible: true)
        let first = Self.element(ref: 1)
        let second = [Self.element(ref: 1), Self.element(id: "extra", label: "extra", ref: 2, frame: FTRect(x: 0, y: 100, width: 50, height: 20))]
        let r = rig([[first], second, second], shots: [blank], delegate: delegate, ink: 0)
        _ = await r.step()
        r.executor.invalidateScreenshotCache()
        _ = await r.step()
        r.executor.invalidateScreenshotCache()
        check("V11 step3", await r.step(), "passed | notes=[stale-screenshot] | fm=1 | gate=false | blank=false | pixels=false")
    }

    /// V10 + 門: 古い絵で素通りしても起動直後の門は消費しない
    func testV10StaleFrameKeepsFirstFrameGate() async {
        let delegate = FakeVisibilityDelegate(visible: true)
        let first = Self.element(ref: 1)
        let second = [Self.element(ref: 1), Self.element(id: "extra", label: "extra", ref: 2, frame: FTRect(x: 0, y: 100, width: 50, height: 20))]
        let r = rig([[first], second], shots: [blank], delegate: delegate, ink: 0)
        _ = await r.step()
        r.executor.noteAppLaunched()
        r.executor.invalidateScreenshotCache()
        check("V10 gate", await r.step(), "passed | notes=[stale-screenshot] | fm=1 | gate=true | blank=false | pixels=false")
    }

    /// V12: インクの足切り(高インク・幾何の疑いなし)→ 素通り。文字の型なので pixelsShowedText が true・門は消費しない
    func testV12InkCutoffPassesAndKeepsGate() async {
        let delegate = FakeVisibilityDelegate(visible: false)
        let r = rig([[Self.element()]], shots: [inked], delegate: delegate, armGate: true)
        check("V12 text type", await r.step(), "passed | notes=[] | fm=0 | gate=true | blank=false | pixels=true")
    }

    /// V12': 文字の型でない(入力欄)要素はインクで素通りしても pixelsShowedText を立てない
    func testV12InkCutoffNonTextTypeDoesNotMarkPixels() async {
        let delegate = FakeVisibilityDelegate(visible: false)
        let e = Self.element(type: "textField")
        let r = rig([[e]], shots: [inked], delegate: delegate)
        check("V12 textField", await r.step(), "passed | notes=[] | fm=0 | gate=false | blank=false | pixels=false")
    }

    /// V13: 黒い絵(`isBlackApartFromSystemBars`)→ 素通り + blank-screenshot
    func testV13BlackScreenshotPassesWithNote() async {
        let delegate = FakeVisibilityDelegate(visible: false)
        let r = rig([[Self.element()]], shots: [Self.blackPNG], delegate: delegate, armGate: true)
        check("V13", await r.step(), "passed | notes=[blank-screenshot] | fm=0 | gate=true | blank=false | pixels=false")
    }

    /// V14: WebView の内側で領域が一色・木の上で覆われていない → 素通り + webview-capture-blank
    func testV14WebViewCaptureMissedPassesWithNote() async {
        let web = Self.element(id: "web", label: "web", type: "webView", ref: 1, frame: FTRect(x: 0, y: 0, width: 400, height: 300))
        let text = Self.element(ref: 2, frame: FTRect(x: 10, y: 10, width: 100, height: 20), depth: 1)
        let delegate = FakeVisibilityDelegate(visible: false)
        let r = rig([[web, text]], shots: [blank], delegate: delegate)
        check("V14", await r.step(), "passed | notes=[webview-capture-blank] | fm=0 | gate=false | blank=false | pixels=false")
    }

    // MARK: - OCR の段

    /// V15: OCR のコンパイル待ち(未コンパイル・完了の上書き)→ 近道を見送り(ocr-shortcut-not-ready)FM へ
    func testV15OCRNotReadyDefersToFM() async {
        let delegate = FakeVisibilityDelegate(visible: true)
        let result = await withModelReady(false, compileFinish: true) { () -> String in
            let r = rig([[Self.element(frame: Self.fullFrame)]], shots: [Self.textPNG(Self.label)], delegate: delegate,
                        ocr: .on, ink: 1000)
            return await r.step()
        }
        check("V15", result, "passed | notes=[ocr-shortcut-not-ready] | fm=1 | gate=false | blank=false | pixels=true")
    }

    /// V16: OCR の近道(丸ごと読めた)→ 素通り・FM 0 回・pixelsShowedText・門は消費しない
    func testV16OCRShortcutReadablePassesAndKeepsGate() async throws {
        await StepExecutorTests.awaitAbandonedOCRReads()
        let delegate = FakeVisibilityDelegate(visible: false)
        let result = await withModelReady(true, lines: [Self.label]) { () -> String in
            let r = rig([[Self.element(frame: Self.fullFrame)]], shots: [Self.textPNG(Self.label)], delegate: delegate,
                        ocr: .on, ink: 1000, armGate: true)
            return await r.step()
        }
        check("V16", result, "passed | notes=[] | fm=0 | gate=true | blank=false | pixels=true")
    }

    /// V16': OCR の近道が予算(`RegionText.occlusionBudget`)を越える → ocr-budget-exhausted・近道は撃たず FM へ(読みは override で2秒待たせる)
    func testV16OCRBudgetExhaustedDefersToFM() async throws {
        await StepExecutorTests.awaitAbandonedOCRReads()
        let delegate = FakeVisibilityDelegate(visible: true)
        RegionText.modelReadyOverrideForTesting = true
        RegionText.readRecognizeOverrideForTesting = { _ in
            try? await Task.sleep(for: .seconds(2))
            return [VisibilityCheckCharacterizationTests.label]
        }
        defer {
            RegionText.modelReadyOverrideForTesting = nil
            RegionText.readRecognizeOverrideForTesting = nil
        }
        let r = rig([[Self.element(frame: Self.fullFrame)]], shots: [Self.textPNG(Self.label)], delegate: delegate,
                    ocr: .on, ink: 1000)
        let result = await r.step()
        await StepExecutorTests.awaitAbandonedOCRReads()
        check("V16 budget", result, "passed | notes=[ocr-budget-exhausted] | fm=1 | gate=false | blank=false | pixels=true")
    }

    /// V4/V17: 行の確かめ(iOS・OCR on・文字の子を持たない行): 読めた文字が別なら赤(row-label-not-read)・期待の文字なら緑
    func testV4V17RowCheckByOCR() async throws {
        await StepExecutorTests.awaitAbandonedOCRReads()
        let row = Self.element(type: "cell", frame: Self.fullFrame)
        let d1 = FakeVisibilityDelegate(visible: true)
        let wrong = await withModelReady(true, lines: ["Different Words"]) { () -> String in
            let r = rig([[row]], shots: [Self.textPNG("Different Words")], delegate: d1, ocr: .on, ink: 1000)
            return await r.step()
        }
        check("V17 other text", wrong, "failed text visibility check failed (on screen) | notes=[row-label-not-read] | fm=0 | gate=false | blank=false | pixels=false")
        await StepExecutorTests.awaitAbandonedOCRReads()
        let d2 = FakeVisibilityDelegate(visible: true)
        let right = await withModelReady(true, lines: [Self.label]) { () -> String in
            let r = rig([[row]], shots: [Self.textPNG(Self.label)], delegate: d2, ocr: .on, ink: 1000)
            return await r.step()
        }
        check("V17 expected text", right, "passed | notes=[] | fm=0 | gate=false | blank=false | pixels=true")
    }

    // MARK: - FM の段が使えない(OCR だけの判定)

    /// V18: FM の段が使えない(陽性対照の注入)→ OCR だけの判定。読みが無い(近道未実施)= 判定不能で素通り / 別の文字 = 不可視で赤
    func testV18OCROnlyJudgement() async throws {
        await StepExecutorTests.awaitAbandonedOCRReads()
        let delegate = FakeVisibilityDelegate(visible: true)
        let undetermined = await withFMNoVerdictInjection { () -> String in
            await withModelReady(false, compileFinish: true) { () -> String in
                let r = rig([[Self.element(frame: Self.fullFrame)]], shots: [Self.textPNG("Different Words")], delegate: delegate,
                            ocr: .on, ink: 1000)
                return await r.step()
            }
        }
        check("V18 undetermined", undetermined, "passed | notes=[ocr-shortcut-not-ready] | fm=0 | gate=false | blank=false | pixels=false")
        await StepExecutorTests.awaitAbandonedOCRReads()
        let notVisible = await withFMNoVerdictInjection { () -> String in
            await withModelReady(true, lines: ["Different Words"]) { () -> String in
                let r = rig([[Self.element(frame: Self.fullFrame)]], shots: [Self.textPNG("Different Words")], delegate: delegate,
                            ocr: .on, ink: 1000)
                return await r.step()
            }
        }
        check("V18 notVisible", notVisible, "failed text visibility check failed (on screen, judged by OCR alone because FM gave no verdict) | notes=[] | fm=0 | gate=false | blank=false | pixels=false")
        await StepExecutorTests.awaitAbandonedOCRReads()
        let partial = await withFMNoVerdictInjection { () -> String in
            await withModelReady(true, lines: ["Hello World"]) { () -> String in
                let e = Self.element(label: "Hello World Foo", frame: Self.fullFrame)
                let r = rig([[e]], shots: [Self.textPNG("Hello World")], delegate: delegate, ocr: .on, ink: 1000)
                return await r.step()
            }
        }
        check("V18 partially visible", partial, "passed | notes=[text-partially-hidden] | fm=0 | gate=false | blank=false | pixels=true")
    }

    // MARK: - FM の段

    /// V19: 判定の控え(同じ絵・同じ枠・同じ期待で2回)→ FM は1回
    func testV19VerdictMemoCallsFMOnce() async {
        let delegate = FakeVisibilityDelegate(visible: true)
        let e = Self.element()
        let r = rig([[e], [e]], shots: [blank], delegate: delegate, ink: 0)
        check("V19 step1", await r.step(), "passed | notes=[] | fm=1 | gate=false | blank=false | pixels=true")
        check("V19 step2", await r.step(), "passed | notes=[] | fm=1 | gate=false | blank=false | pixels=true")
    }

    /// V20: FM 無回答(訊いたが nil)→ OCR だけの代替判定へ落ちて素通り + visibility-guard-skipped
    func testV20FMNoVerdictNotesSkipped() async {
        let delegate = NoVerdictVisibilityDelegate()
        let r = rig([[Self.element()]], shots: [blank], delegate: delegate)
        check("V20", await r.step(), "passed | notes=[visibility-guard-skipped] | fm=1 | gate=false | blank=false | pixels=false")
    }

    /// V21: 空の転写かつ領域にインク → 赤 + fm-empty-transcript-on-ink / 訊き直しで読めた(fm-reasked-empty-transcript)
    func testV21EmptyTranscriptOnInk() async {
        let d1 = FakeVisibilityDelegate(visible: false)
        let r1 = rig([[Self.element()]], shots: [inked], delegate: d1, ink: 10_000)
        check("V21 red", await r1.step(), "failed text visibility check failed (on screen) | notes=[fm-empty-transcript-on-ink] | fm=2 | gate=false | blank=false | pixels=false")
        let d2 = FakeVisibilityDelegate(visible: false)
        d2.visibleFromCall = 2
        let r2 = rig([[Self.element()]], shots: [inked], delegate: d2, ink: 10_000)
        check("V21 reasked", await r2.step(), "passed | notes=[fm-empty-transcript-on-ink,fm-reasked-empty-transcript] | fm=2 | gate=false | blank=false | pixels=true")
    }

    /// V21': 空の転写を OCR の確認で読めた(ocr-read-what-fm-missed)。近道は未コンパイルで見送り・確認の読みで緑
    func testV21OCRConfirmedWhatFMMissed() async throws {
        await StepExecutorTests.awaitAbandonedOCRReads()
        let delegate = FakeVisibilityDelegate(visible: false)
        let result = await withModelReady(false, compileFinish: true, lines: [Self.label]) { () -> String in
            let r = rig([[Self.element(frame: Self.fullFrame)]], shots: [Self.textPNG(Self.label)], delegate: delegate,
                        ocr: .on, ink: 1000, armGate: true)
            return await r.step()
        }
        check("V21 ocr confirmed", result, "passed | notes=[ocr-read-what-fm-missed,ocr-shortcut-not-ready] | fm=1 | gate=false | blank=false | pixels=true")
    }

    /// V22: OCR と FM の突き合わせ。FM 可視 → 緑 / FM 不可視かつ OCR 判定不能 → 赤 / FM 可視で OCR が不可視(割れた回)→ 緑 + 注記
    func testV22OCRAndFMMerge() async throws {
        let d1 = FakeVisibilityDelegate(visible: true)
        let r1 = rig([[Self.element()]], shots: [blank], delegate: d1)
        check("V22 fm visible", await r1.step(), "passed | notes=[] | fm=1 | gate=false | blank=false | pixels=true")

        let d2 = FakeVisibilityDelegate(visible: false)
        let undetermined = await withModelReady(false, compileFinish: true) { () -> String in
            let r = rig([[Self.element()]], shots: [blank], delegate: d2, ocr: .on, ink: 12)
            return await r.step()
        }
        check("V22 fm invisible ocr undetermined", undetermined, "failed text visibility check failed (on screen) | notes=[ocr-shortcut-not-ready] | fm=1 | gate=false | blank=false | pixels=false")

        await StepExecutorTests.awaitAbandonedOCRReads()
        let d3 = FakeVisibilityDelegate(visible: true)
        let split = await withModelReady(true, lines: ["Different Words"]) { () -> String in
            let r = rig([[Self.element(frame: Self.fullFrame)]], shots: [Self.textPNG("Different Words")], delegate: d3,
                        ocr: .on, ink: 1000)
            return await r.step()
        }
        check("V22 fm visible ocr notVisible", split, "passed | notes=[fm-read-what-ocr-missed] | fm=1 | gate=false | blank=false | pixels=true")
    }

    /// V23: FM が読んだ文字が前の緑の値 → 素通り + stale-screenshot(同じ id の要素で1回緑 → ラベルを変えて FM が前の値を返す)
    func testV23FMReadPreviousGreenValue() async {
        let delegate = ScriptedVerdictDelegate([
            .init(visible: true, state: "fullyVisible", observed: "こんにちは"),
            .init(visible: false, state: "textMismatch", observed: "こんにちは"),
        ])
        let r = rig([[Self.element()], [Self.element(label: "さようなら")]], shots: [blank, nearBlank],
                    delegate: delegate, ink: 0)
        check("V23 step1", await r.step(), "passed | notes=[] | fm=1 | gate=false | blank=false | pixels=true")
        r.executor.invalidateScreenshotCache()
        check("V23 step2", await r.step(), "passed | notes=[stale-screenshot] | fm=2 | gate=false | blank=false | pixels=false")
    }

    /// V24: FM の赤(covered)。起動直後の門が立っていて一様な絵 → firstFrameBlankObserved true・門を消費 / 可視でも門を消費(blank は false)
    func testV24FMRedAndFirstFrameGate() async {
        let d1 = FakeVisibilityDelegate(visible: false)
        let r1 = rig([[Self.element()]], shots: [blank], delegate: d1, armGate: true)
        check("V24 red blank gate", await r1.step(), "failed text visibility check failed (on screen) | notes=[first-frame-pending,first-frame-timeout] | fm=1 | gate=false | blank=true | pixels=false")

        let d2 = FakeVisibilityDelegate(visible: false)
        let r2 = rig([[Self.element()]], shots: [blank], delegate: d2)
        check("V24 red no gate", await r2.step(), "failed text visibility check failed (on screen) | notes=[] | fm=1 | gate=false | blank=false | pixels=false")

        let d3 = FakeVisibilityDelegate(visible: true)
        let r3 = rig([[Self.element()]], shots: [blank], delegate: d3, armGate: true)
        check("V24 visible gate", await r3.step(), "passed | notes=[] | fm=1 | gate=false | blank=false | pixels=true")

        let d4 = FakeVisibilityDelegate(visible: false)
        let r4 = rig([[Self.element()]], shots: [inked], delegate: d4, ink: 10_000, armGate: true)
        check("V24 red inked gate", await r4.step(), "failed text visibility check failed (on screen) | notes=[fm-empty-transcript-on-ink] | fm=2 | gate=false | blank=false | pixels=false")
    }
}
