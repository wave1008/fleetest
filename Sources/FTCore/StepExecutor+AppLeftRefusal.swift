// StepExecutor+AppLeftRefusal.swift
// 対象アプリが前面を離れた(スイッチャー・背面)・このシナリオが止めたままのときの断りと帰属。入口は appLeftRefusal。
// 本体は StepExecutor.swift(instance 状態はそちらに置く)

import Foundation

extension StepExecutor {
    /// **in-app ブリッジに届かなかったのが、アプリが背面にあるせいだと確かめられたら、その事実を付ける**(`AppFate.inBackground`)。
    /// iOS は背面のアプリを約 2 秒で一時停止し、アプリの中の in-app ブリッジは答えなくなる(11/6 に -01 で実測: home の 0.5 秒後は
    /// background で答え、2 秒後からは無応答)。付けないと「ブリッジに届かない・bridge up しろ」になり、run は不達として再キューした。
    /// 付けるのは2つの事実がそろったときだけ: in-app ドライバが「プロセスは生きているのに答えない」と確かめた(`.aliveButNotAnswering`。
    /// 前面に無い = 落ちた、と区別する。報告より先に落ちたアプリも前面には無い)と、XCUITest ブリッジの前面の照会(画面を動かさない読み)が
    /// 「前面に無い」と答えた。答えない・前面にいる(本当に固まった in-app ブリッジ)・生死が分からない(実機)ときは元のエラーのまま
    public func attributingBackgroundedApp(_ error: Error) async -> Error {
        guard case .bridgeUnreachable(let context, let detail)? = error as? DriverError,
              context.bridge == .iosInApp, context.appFate == .aliveButNotAnswering,
              let fallback = fallbackDriver, let bundleID = lastLaunchedAppBundleID,
              case .value(false) = await ForegroundState.inForegroundProbe(fallback, bundleID: bundleID)
        else { return error }
        var foldedNote = ""
        if case .state(.folded)? = await observeFold() {
            foldedNote = "The device is folded, so tapAppIcon() does not run; use launchApp()."
        }
        return DriverError.bridgeUnreachable(context: context.with(appFate: .inBackground),
                                             detail: [detail, foldedNote].filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// **アプリスイッチャーが前面の間は、アプリを読む・触るステップを撃たずに断る**。スイッチャーを開いてもアプリは inactive のまま
    /// (11/6 に -01 で実測: applicationState = inactive・in-app の tap は 200)なので in-app ブリッジは断れず、カードの中のアプリに
    /// 打鍵・タップ・読みが届いて緑になった(17周目 ilocal F1・4 SUT で 18/18)。inactive は OS のアラートの間も同じなので、
    /// 見分けは XCUITest の覆いの照会(`SBSwitcherWindow` の目印)で取る。照会するのは `appSwitcher()` の後だけ
    /// (`appSwitcherMayCover`)。覆いが無いと答えたら印を落とす・答えない(照会の失敗)ときは断らない(推測で赤にしない)が印は残す。
    /// 撃たないのは端末側の操作(向き・折りたたみ)と待つだけのステップ
    func appSwitcherRefusal(step: FlowStep) async -> String? {
        guard appSwitcherMayCover, let fallback = fallbackDriver else { return nil }
        if let action = step.action, Self.runsWithoutTheApp.contains(action) { return nil }
        switch await ForegroundState.coveringProbe(fallback) {
        case .value(.appSwitcher?):
            return "the app switcher is in front (opened by appSwitcher()), so this step was not run: steps read and"
                + " touch the app under test, which a person cannot use from the switcher. Bring the app back first"
                + " (tapAppIcon() or launchApp())"
        case .value(_):
            appSwitcherMayCover = false
            return nil
        case .notAnswerable, .failed:
            // 断らないが印は残す(次のステップで聞き直す)。1回の照会の失敗で門を外すと、スイッチャーの間の操作が緑に戻る
            return nil
        }
    }

    /// 前面へ戻す手の案内。畳んだ折りたたみ機ではホーム画面のアイコンが押せず `tapAppIcon()` は毎回撃たずに赤になる(Duo の外側の画面)ので、
    /// 開閉を読めて畳んでいるときだけ `launchApp()` を勧める。読めない・開いている・折りたたみ機でないときは従来の文
    static func bringBackAdvice(fold: FoldObservation?) -> String {
        if case .state(.folded)? = fold {
            return "launchApp(); tapAppIcon() does not run while the device is folded, so unfold() first to use it"
        }
        return "tapAppIcon() or launchApp()"
    }

    func bringBackAdvice() async -> String {
        Self.bringBackAdvice(fold: await observeFold())
    }

    /// **前面を離れたかもしれない後だけ、撃つ前に前面かを聞き、前面に無ければ撃たずに断る**。背面のアプリは約 2 秒で一時停止され、
    /// in-app ブリッジへの最初の読みが待ちの上限(45 秒)まで返らない —— `attributingBackgroundedApp` は帰属を正すが、待ちは払った
    /// (17周目の陽性対照: home → wait(4) → tap が 49 秒)。照会は XCUITest の画面を動かさない読み(約 0.1 秒)。
    /// 前面と答えたら印を落とす(以後は聞かない)。答えない・失敗は断らない(推測で赤にしない)が印は残す
    func backgroundedAppRefusal(step: FlowStep) async -> String? {
        guard appMayHaveLeft, let fallback = foregroundProber, let bundleID = lastLaunchedAppBundleID else { return nil }
        if let action = step.action, Self.runsWithoutTheApp.contains(action) { return nil }
        // **Android は否定の検証と条件の判定だけを断る**: Android の木は前面の画面そのもの(iOS の in-app のように背面のアプリの木を
        // 読まない)なので、肯定の読み・操作は前面の画面に対して事実どおりに効く(ランチャーのアイコンを押す・読むのは人にもできる。
        // 全部を断ると「a person could not either」が事実と逆だった = 24周目 amax F1)。誤った成功になるのは「無い」で通る側だけ
        if fallbackDriver == nil, !Self.passesOnAbsence(step), !(await scrollSendWouldHitOtherApp(step)) { return nil }
        // 前面へ戻る途中(openURL の直後等)を断らない: ステップの待ちの上限まで聞き直す(0.5 秒おき)
        let deadline = Date().addingTimeInterval(step.timeout ?? tunables.defaultTimeout)
        let candidates = [bundleID] + [appUnderTestBundleID].compactMap { $0 }.filter { $0 != bundleID }
        while true {
            switch await Self.anyInForeground(fallback, bundleIDs: candidates) {
            case .value(true):
                // openURL の後に inactive = 開いた先が立ち上がる途中(前面の照会はまだ前面と答える)。background = in-app が先に
                // 外れたと答え、前面の照会が追いついていない(撃つと in-app が 423 で断る = 門の失敗の種類にならない)。待ちの上限まで
                // 聞き直し、前面の照会が外れたと答えれば上の .value(false) で断る。上限まで外れきらなければここで断る
                // (人も開く途中の画面には触れない)。active に戻った・答えない(in-app でない)なら従来どおり撃つ
                if openedURLMayStillBeLeaving, let state = await driver.inAppApplicationState(),
                   state == "inactive" || state == "background" {
                    if Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    if state == "background" {
                        return "The app under test is not in the foreground, so this step did not read or touch it"
                            + " — a person could not either. Bring the app back first (\(await bringBackAdvice()))"
                    }
                    return "The app under test is still inactive after openURL — another app is opening over it — so this step"
                        + " did not read or touch it. Bring the app back first (\(await bringBackAdvice()))"
                }
                appMayHaveLeft = false
                openedURLMayStillBeLeaving = false
                return nil
            case .value(false):
                if Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                // 落ちたアプリも前面には居ない。生死を答えられて「居ない」なら背面とは言わず、従来の経路(読みの不達 →
                // クラッシュの記録)へ渡す。答えられない(実機)ときは事実(前面に無い)だけを言って断る
                if let alive = appAliveProbe, await alive(bundleID) == false { return nil }
                return "The app under test is not in the foreground, so this step did not read or touch it"
                    + " — a person could not either. Bring the app back first (\(await bringBackAdvice()))"
            case .notAnswerable, .failed:
                // 断らないが印は残す(次のステップで聞き直す)。外すと次からは読みの上限(45 秒)まで待つ従来の経路になる
                return nil
            }
        }
    }

    /// 撃つ前の門が「前面を離れたかもしれない」印を残したまま(背面と断った後を含む)、今も前面に無いと答えたら true。
    /// **失敗の証跡で停止中のアプリへ木を読みに行かない**ための問い(in-app の /snapshot は約 2 秒で停止した背面のアプリから
    /// 上限 45 秒まで返らず、背面と断った赤のたびにシナリオの終わりが約 45 秒延びた = 19周目 phys F1・手元で 45.05 秒を記録)。
    /// 答えない・前面と答えたら false(証跡は従来どおり撮る)
    public func appStillInBackground() async -> Bool {
        guard appMayHaveLeft, let fallback = fallbackDriver, let bundleID = lastLaunchedAppBundleID else { return false }
        if case .value(false) = await ForegroundState.inForegroundProbe(fallback, bundleID: bundleID) { return true }
        return false
    }

    /// 撃つ前の門で前面を聞く相手。iOS は XCUITest(inapp-boost の副ドライバ。in-app は自分が背面かを答えられない)、
    /// Android は主ドライバ(前面のアプリを読んで答える・読めなければ投げる)。**Android を外すと**、`home()` の後の否定の検証
    /// (notExist・countIs 0・不成立の ifCanSelect)がランチャーの木の上で黙って通り、tap は従えない対処文で落ちた
    /// (23周目 amax F1・phys F1: 各 4/4・2/2)
    var foregroundProber: AppDriver? { fallbackDriver ?? (isAndroid ? driver : nil) }

    /// 候補のどれかが前面なら `.value(true)`。全部が「前面に無い」と答えたら `.value(false)`。答えない候補があれば
    /// (前面と答えた候補が無い限り)その答えを返す = 断らずに印を残す
    static func anyInForeground(_ driver: AppDriver, bundleIDs: [String]) async -> Probe<Bool> {
        var unanswered: Probe<Bool>?
        for bundleID in bundleIDs {
            switch await ForegroundState.inForegroundProbe(driver, bundleID: bundleID) {
            case .value(true): return .value(true)
            case .value(false): continue
            case let other: unanswered = unanswered ?? other
            }
        }
        return unanswered ?? .value(false)
    }

    /// **アプリが前面を離れた後(スイッチャー・背面)の断りの入口**。ステップ(`execute`)と DSL の条件判定(`ifCanSelect` の
    /// `canSelect`)が共有する = 読みが in-app ブリッジを通る経路はどちらも通す
    public func appLeftRefusal(step: FlowStep) async -> (message: String, kind: StepFailureKind)? {
        if let message = await appSwitcherRefusal(step: step) { return (message, .systemUICovered) }
        if let message = await backgroundedAppRefusal(step: step) { return (message, .appInBackground) }
        if let message = await stoppedAppRefusal(step: step) { return (message, .appStoppedBySession) }
        return nil
    }

    /// **Android で、このシナリオが止めたままのアプリの要素を読む・触るステップを、探さずに断る**(OI-181 ④: `terminateApp()` の後の
    /// `tap(scroll: .down)` がランチャーの一覧を 17 秒送り、ランチャーの部品で包めと従えない案内をした = 4/4)。iOS は撃つ前に
    /// 断る門が別にある(`notRunningAppBackRefusal`・`appStoppedBySession`)。
    /// 断るのは全部がそろったときだけ: 止めたまま・プロセスが居ないと答えた・対象が今の木に無い。**今の木にある対象は撃つ**
    /// (ランチャーのアイコンをラベルで押す等は人にもできる)・否定の検証は断らない(止めたアプリの要素が無いのは事実)
    func stoppedAppRefusal(step: FlowStep) async -> String? {
        guard isAndroid, appUnderTestStopped, let bundleID = appUnderTestBundleID,
              step.locator != nil || Self.sendsScrolls(step) || Self.typesIntoFocus(step),
              !Self.passesOnAbsence(step) else { return nil }
        if let action = step.action, Self.runsWithoutTheApp.contains(action) { return nil }
        guard let running = appProcessRunning, await running(bundleID) == false,
              let tree = try? await driver.snapshot(),
              step.locator == nil || LocatorResolver.resolve(step: step, in: tree) == nil else { return nil }
        let what = step.locator == nil
            ? (Self.typesIntoFocus(step)
                ? (step.action == "clearInput"
                    ? "this step cleared nothing (without a selector it would clear whatever field has input focus in front)"
                    : "this step typed nothing (without a selector the text would go into whatever has input focus in front)")
                : "this step sent nothing (a scroll would only move whatever is in front)")
            : "this step did not look for its element (scrolling or waiting would only move whatever is in front)"
        return "The app under test (\(bundleID)) is not running — this scenario stopped it — so \(what). "
            + StoppedAppAdvice.startAgain(afterStopping: appUnderTestStoppedCommand)
    }

    /// セレクタ無しの打鍵・消去(焦点のある欄へ効く = 止めたアプリの後は前面の別の物に効く)
    static func typesIntoFocus(_ step: FlowStep) -> Bool {
        step.locator == nil && ["type", "clearInput"].contains(step.action ?? "")
    }

    /// 送り(`scrollDown()` 等 = scroll・`scrollToBottom()` 等 = scrollToEdge・`scrollTo`)。前面がアプリでないときに撃つと別のアプリの面を動かす
    static func sendsScrolls(_ step: FlowStep) -> Bool {
        ["scroll", "scrollToEdge", "scrollTo"].contains(step.action ?? "")
    }

    /// Android で、この送りが対象アプリでない面を動かすか。対象を持たない送り(scroll・scrollToEdge)は常に。`scrollTo` は
    /// 今の木に対象が無く送りが要るときだけ(あれば送らずに着く)。木が読めないときは false(推測で断らない)
    func scrollSendWouldHitOtherApp(_ step: FlowStep) async -> Bool {
        guard isAndroid, Self.sendsScrolls(step) else { return false }
        if step.action != "scrollTo" || step.locator == nil { return true }
        guard let tree = try? await driver.snapshot() else { return false }
        return LocatorResolver.resolve(step: step, in: tree) == nil
    }

    /// 対象が「無い」ことで通る(または分岐が決まる)ステップ: notExist・countIs 0・条件の判定(`canSelect` の門の
    /// ステップ = 動作も検証も持たない)・`select`(掴めなければ空の要素を返し、`.isEmpty` / `doUntilTrue` の条件に使われる =
    /// 25周目 amax F1: `home()` の後の `select(…).isEmpty.thisIsTrue()` が緑)。前面に別の画面があると黙って通る側
    static func passesOnAbsence(_ step: FlowStep) -> Bool {
        if step.assert == "notExists" || step.action == "select" { return true }
        if step.assert == "count", step.expectedCount == 0 { return true }
        return step.action == nil && step.assert == nil
    }

    /// **Android の「無い」で通った検証が、実行プロファイルのアプリでない前面の木を読んだか**(OI-182 ①)。門は「対象か最後に起こした
    /// アプリのどちらかが前面」で通す(別のアプリを意図して検証するシナリオがある = 25周目 amax F2)ので、合否は変えず事実だけを言う。
    /// 持ち主が読めない・実行プロファイルのアプリが無いときは黙る
    static func absenceReadAnotherApp(isAndroid: Bool, step: FlowStep, owner: String?, appUnderTest: String?) -> Bool {
        guard isAndroid, step.assert != nil, passesOnAbsence(step),
              let owner, !owner.isEmpty, let appUnderTest, !appUnderTest.isEmpty else { return false }
        return owner != appUnderTest
    }

    /// アプリスイッチャーの間も撃つステップ(アプリを読まず触らない)。**rotateTo を入れない**: iOS の回転は XCUITest のセッションを
    /// 対象アプリへ付け直す(`AppAttachDriver.rotate` → `ensureAttached` の activate)ので、home() の後に撃つと背面のアプリを黙って
    /// 前面へ戻して ✅ だった(34周目 ilocal F1 2/2・後続の tap / exist も緑)
    static let runsWithoutTheApp: Set<String> = ["waitForSettle", "holdEnd", "fold", "unfold", "hinge"]
}
