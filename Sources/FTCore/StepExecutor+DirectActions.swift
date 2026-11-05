// StepExecutor+DirectActions.swift
// executeAction(StepExecutor+Actions.swift)の入口分岐にある、ロケータ解決を経由しない早期 return の
// アクション本体(swipe/rotateTo/scroll/scrollToEdge/flick/座標 tap/対象未指定ジェスチャ/scrollTo/
// フォーカス中要素への type・pressEnter・hideKeyboard・clearInput)。呼び出し条件は
// StepExecutor+Actions.swift 側に残る(本体だけをここへ委譲する)

import Foundation

extension StepExecutor {

    func executeDirectSwipe(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        // **未指定でも撮る**: キーボード表示中かどうかは snapshot でしか
        // 分からない。キーボードが無ければ path は nil のまま = ブリッジ既定(1バイトも
        // 変わらない)。**path を付けるのはキーボードがあるときだけ** —— in-app の
        // contentOffset 経路はキーボードに塞がれないが、座標つきは Compose/Flutter で
        // 501 を返すため、swipeWithFallback が XCUITest の実ジェスチャへ回す
        // (キーボード上はそちらでないと動かないので、これが望ましい)
        // 枠は静止した木から取る(flick と同じ理由。executeDirectFlick の doc)
        let settledBefore = try await settledSignature(phase: &phase)
        if settledBefore.changed { noteCodesThisStep.insert(.settledBeforeGesture) }
        let snapshot = settledBefore.snapshot
        let hasKeyboard = KeyboardWait.isShown(snapshot)
        let path = hasKeyboard ? scrollPath(step: step, intent: .gesture, in: snapshot) : nil
        let viaXCUITest = try await swipeWithFallback(direction, path: path, phase: &phase)
        // 慣性が止まるまで待つ。ランナー側は /swipe を整定対象から外している(そこで待っても
        // budget 内に収束しないため)ので、直後に tap する書き方をここで支える
        let settled = skippingSettle(step) ? true : try await settledSignature(phase: &phase).settled
        var notes: [String] = []
        if viaXCUITest { notes.append("fell back to XCUITest") }
        if !settled { note(.settleCapped, into: &notes) }
        // MCP の keyboardSwipeAreaNote と同じ判定(KeyboardSwipeCoverage)。払いは変えず、打鍵になりうることだけ言う
        if hasKeyboard, let keyboard = KeyboardSwipeCoverage.coveringFrame(snapshot) {
            notes.append(KeyboardSwipeCoverage.note(keyboard))
        }
        return StepOutcome(status: .passed,
                           driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
    }

    // Device-level, no locator.
    // **inapp-boost モード(typeDriver あり)は XCUITest の XCUIDevice.orientation で回す**。in-app ブリッジの回転は
    // シーンへの requestGeometryUpdate で、/rotate は scene.interfaceOrientation の一致しか見ないため、
    // React Native(react-native-screens)では 200 を返しても木の screen が縦のまま(6台中3台)・次の画面への
    // push で縦へ戻る(E2EX-RN 6/6)ことがあった。XCUITest 側の回転は端末の向きそのものを変えるので画面遷移でも戻らない
    // (xcuitest モードでは戻らない実測)。iPad の in-app 501 もここで不要になる。
    // **回した後は木の screen で向きを確かめる**(`verifyOrientation`)。ドライバの「一致した」は自己申告なので信用しない。
    // 戻すのはシナリオ終端の FTRuntime.restoreOrientationIfNeeded(typeDriver 側も戻す)
    func executeDirectRotateTo(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        guard let raw = step.direction, let orientation = FTOrientation(rawValue: raw) else {
            return StepOutcome(status: .failed("rotateTo requires an orientation"))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let rotator: AppDriver = typeDriver ?? driver
        _ = try await rotator.rotate(to: orientation)
        var matched = await verifyOrientation(orientation)
        if !matched {
            // 撃ち直してよい: 向きの変更は冪等(同じ向きへの要求を重ねても二重に効かない = 送信・購入のような
            // 取り返しのつかない副作用が無い)。届いたか分からない操作の自動リトライ禁止の対象ではない
            _ = try await rotator.rotate(to: orientation)
            matched = await verifyOrientation(orientation)
        }
        phase.actionMs += Self.ms(clock.now - start)
        guard matched else {
            return StepOutcome(status: failed(
                .assertion,
                "rotateTo \(orientation.rawValue): the driver reported the orientation but the screen did not become"
                + " \(orientation.rawValue) (the tree's screen stayed the other way round) after a second request,"
                + " so the following steps would have run in the wrong orientation"))
        }
        // **向きが変わっただけでは終わりではない**: ドライバは「向きが要求と一致したか」までしか
        // 見ておらず、その時点でレイアウトはまだ動いている。直後のタップは動く前の座標を撃つ
        // (実測: 回転直後の `#tab_home` が (-6,45) 動いた後の位置に当たらず、
        // 別の要素を押していた)。スクロール後の静止をホスト側が担うのと同じ規律で、
        // 木が2回続けて同じ署名になるまで待つ
        if !skippingSettle(step) { _ = try? await settledSignature(phase: &phase) }
        return StepOutcome(status: .passed)
    }

    /// 木の screen が要求の向きになるまで待つ。上限と刻みは `RotationSettle`(ブリッジの待ちと同じ予算を使い、新しい数字を置かない)。
    /// 撮れない・screen が正方形/空のときは判定できないので一致扱い(読めないことを失敗にしない)
    func verifyOrientation(_ orientation: FTOrientation) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(RotationSettle.deadlineSeconds)
        while true {
            if let snapshot = try? await freshSnapshot(.afterOwnMove) {
                if Self.screenMatches(orientation, screen: snapshot.screen) { return true }
            } else {
                return true
            }
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .seconds(RotationSettle.pollIntervalSeconds))
        }
    }

    static func screenMatches(_ orientation: FTOrientation, screen: FTRect) -> Bool {
        guard screen.width > 0, screen.height > 0, screen.width != screen.height else { return true }
        return (screen.width > screen.height) == (orientation == .landscape)
    }

    // スクロールだけ行う(Shirates の scrollDown 等)。maxSwipes を繰り返し回数として使う
    func executeDirectScroll(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        let times = max(1, step.maxSwipes ?? 1)
        var viaXCUITest = false
        var unsettled = false
        var sentSwipes = 0
        // **未指定でも撮る**: scrollPath には viewport(snapshot.screen)が要るので、
        // 木が無いと path ごと nil になり黙って全画面スワイプへ退化する
        // (scrollToEdge/flick は rect を見ている)。
        // **キーボード表示中はこれが唯一の検知手段でもある** —— ソフトキーボードの上で
        // スワイプすると始点がキーボード面に乗って何も動かない(scrollContainer 参照)。
        // 最初の1本の枠は静止した木から取る(flick と同じ理由)。2本目以降は直前の送りの整定で撮った木を使う。
        // 静止の確認(静止した画面で2枚・約 130ms)は scrollDown/scrollUp のたび毎回払う
        let settledBefore = try await settledSignature(phase: &phase)
        if settledBefore.changed { noteCodesThisStep.insert(.settledBeforeGesture) }
        var latest: SnapshotResponse? = settledBefore.snapshot
        for _ in 0..<times {
            // **明示 scrollFrame が解決できないなら、ここで打ち切る(1本も振らない)**。
            // 黙って全画面スワイプへ退化させない(runScrollSearch の fail-fast と同じ理由)
            if let latest, Self.scrollFrameUnresolved(step, in: latest) {
                noteCodesThisStep.insert(.scrollFrameMissing)
                return StepOutcome(status: failed(
                    .notFound,
                    Self.scrollFrameFailFastMessage(step, action: "swipe", swipes: sentSwipes)))
            }
            let path = latest.flatMap { scrollPath(step: step, intent: .search, in: $0) }
            if try await swipeWithFallback(direction, intent: .search, path: path,
                                           phase: &phase) { viaXCUITest = true }
            sentSwipes += 1
            // 続けて投げるとフリングの停止だけに消費されて空振りする(Android 実測)。
            // 「repeat 回ぶん送る」を守るため、次のスワイプ前に静止を待つ。
            // 最後の1回の後も待つ: ランナーは /swipe を整定対象から外しているので、
            // 直後に tap する書き方をここで支える(index 条件を外した理由)
            // settle:false は最後の1本の後だけ飛ばす(本の間の静止待ちは「repeat 回ぶん送る」のための内側の整定)
            if sentSwipes == times, skippingSettle(step) { break }
            let settled = try await settledSignature(phase: &phase)
            if !settled.settled { unsettled = true }
            // **常に引き継ぐ**: settledSignature は毎回木を撮り直しているので
            // 追加コストは無い。scrollFrame 未指定でもキーボードの開閉は周回ごとに変わりうる
            latest = settled.snapshot
        }
        var notes: [String] = []
        if viaXCUITest { notes.append("fell back to XCUITest") }
        if unsettled { note(.settleCapped, into: &notes) }
        if let note = pendingScrollFrameNote { notes.append(note) }
        // 送る前と最後の送りの後の静止した木(読みは足さない)の中身が同じ = 1本も効いていない。黙って ✅ にしない
        // (横向きの Android: 枠なしの上への払いの始点が画面の高さの 30% = 一覧の上の帯に落ち、一覧が動かなかった)。
        // 原因は名指さない(端に着いていても同じに見える)。settle: false の最後は撮っていないので比べない
        // 比べるのは見えている項目の顔ぶれ(型・id・ラベル)。位置は比べない: 払いが一覧の端に掛かって数 px だけずれた形
        // (観測: 行が 3px 動いて ✅)を「動いた」と数えないため。1画面ぶんの送りが効けば顔ぶれは必ず入れ替わる
        if !skippingSettle(step), let latest,
           Self.sameVisibleItems(settledBefore.snapshot.elements, latest.elements) {
            noteCodesThisStep.insert(.scrollMovedNothing)
            // scrollFrame: を書いた送りに「scrollFrame: を渡せ」と言わない
            notes.append(step.scrollFrame == nil && step.scrollFrameRect == nil ? StepNote.scrollMovedNothing.text
                : "nothing on the screen moved after the swipe(s) — the list may already be at its end in this direction")
        }
        return StepOutcome(status: .passed,
                           driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
    }

    /// 見えている項目の顔ぶれ(型・id・ラベル)が同じか(`scroll-moved-nothing` の判定)。位置・値は比べない
    static func sameVisibleItems(_ a: [ElementInfo], _ b: [ElementInfo]) -> Bool {
        func key(_ e: ElementInfo) -> String { "\(e.type)\u{1F}\(e.identifier ?? "")\u{1F}\(e.label ?? "")" }
        return a.map(key).sorted() == b.map(key).sorted()
    }

    // 端まで送る(Shirates の scrollToBottom 等)。**画面が変化しなくなったら端**とみなす。
    // 比較は**静止してから**行う(フリングの減速中に撮ると動いていないように見える)。
    // さらに **2 回続けて変化なし**を条件にする — Android では次のスワイプがフリングの
    // 停止だけに消費されて 1 回空振りすることがあり、1 回で打ち切ると途中で止まる
    // (実測: scrollToTop が row_22 付近で停止した)
    func executeDirectScrollToEdge(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        var viaXCUITest = false
        var previous: String?
        // この送りの中で一度見た署名。**前の状態に戻ったのは進んでいない**(本当に送れていれば同じ状態には
        // 戻らない)。上端で送るたびに引っ張って更新が走る一覧は「上端」と「上端 + 更新中の表示」を行き来し、
        // 2回続けて同じにならないまま上限まで送り続けた(実測: Flutter の RefreshIndicator で 50 回・更新 25 回)
        var seenSignatures = Set<String>()
        var unchanged = 0
        var reachedEdge = false
        var sawUnsettled = false
        // 送りの間に見えている中身が一度でも変わった(または確かに動かしたと申告された)か。
        // false のまま「端」と確定した = 1行も動いていない(端に着いたのと区別して言う)
        var contentEverMoved = false
        let limit = max(0, step.maxSwipes ?? FlowStep.defaultMaxEdgeSwipes)
        var hintJumps = 0
        var sentSwipes = 0
        // 見えている中身が最後に変わった時刻(端を確定してよいかの起点)。nil = 一度も変わっていない
        // = 送る前から端だった → 猶予を待たない
        let clock = ContinuousClock()
        var lastChangeAt: ContinuousClock.Instant?
        var retryAfterGrace = false
        // 端を確定する前に、最後の変化から `edgeClaimGraceAfterMove` 経っているかを見る。
        // 経っていなければ残りを待って true(= もう1本送ってから判断し直す)
        func waitedForGrace() async throws -> Bool {
            guard let lastChangeAt else { return false }
            let remaining = Self.edgeClaimGraceAfterMove - (clock.now - lastChangeAt)
            guard remaining > .zero else { return false }
            let waitStart = clock.now
            try await Task.sleep(for: remaining)
            phase.waitMs += Self.ms(clock.now - waitStart)
            return true
        }
        // ドライバの端申告を確かめた読みは**次の周回の読みとして使い回す**
        // (捨てて撮り直すと、端の確定のために木を1周ぶん余計に読む)
        var carried: (signature: String, snapshot: SnapshotResponse, settled: Bool, changed: Bool)?
        let vertical = direction == .up || direction == .down
        // **端を申告しない構成(iOS の XCUITest)の確かめは短いドラッグで撃つ**(`EdgeProbe`): 全力の送りが基準より
        // 動かなかった = 途中で端に当たった、と読めたら、端を確かめる送りを引っ張りにならない短いドラッグに替える。
        // 基準は指の移動量(経路が分かるとき)か、この送りの中の1本前の全力の送りが動かした量(scrollFrame 未指定 =
        // ブリッジ既定の払いで経路が分からないとき)。端の確定は今までどおり署名の不変だけ(短いドラッグで中身が動けば
        // 署名が変わり、全力の送りへ戻る)
        var lastFullSwipe: (before: SnapshotResponse, travel: Double?)?
        var lastFullMoved: Double?
        var probeNext = false
        var lastWasProbe = false
        var probes = 0
        var probeEvidence: (moved: Double, travel: Double)?
        var probeFlush = false
        // 短いドラッグの始点にする「動いた中身」の #id(ref は撮るたびに振り直されるので id で控える。EdgeProbe.path)
        var probeAnchorIDs: Set<String> = []
        var startScreen: FTRect?
        // 送りを始めた時点で木が名乗っていたアプリと、最後に読んだ木(終わりに「前面は対象のままか」を1回だけ引く)
        var edgeBundleID: String?
        var lastEdgeTree: SnapshotResponse?
        for _ in 0..<limit {
            let settled: (signature: String, snapshot: SnapshotResponse, settled: Bool, changed: Bool)
            if let carried {
                settled = carried
            } else {
                settled = try await settledSignature(phase: &phase)
            }
            carried = nil
            edgeBundleID = edgeBundleID ?? settled.snapshot.sessionBundleID
            lastEdgeTree = settled.snapshot
            if !settled.settled { sawUnsettled = true }
            // **探索の途中で画面の大きさが変わった(端末が回った)なら、端とは言わず止める**(scrollTo と同じ。座標系が替わると
            // 容器・始点の前提が崩れ、潰れた容器へ上限まで払い続けて ok を返していた)
            if let startScreen, startScreen != settled.snapshot.screen {
                return StepOutcome(status: failed(.notFound,
                    "\(step.action ?? "scrollToEdge") stopped after \(sentSwipes) swipe(s): the screen size changed during the swipes"
                    + " (the device was probably rotated), so the layout and the scroll area moved and the end of the list is"
                    + " not known — take a fresh snapshot and scroll again"))
            }
            startScreen = startScreen ?? settled.snapshot.screen
            let region = edgeContentRegion(step: step, in: settled.snapshot)
            let contentSignature = Self.edgeSignature(settled.snapshot, contentRegion: region)
            // **ドライバが「確かに動かした」と申告した直後(previous == nil)は戻りを数えない**: 飛ぶたびに同じ並びになる
            // 一覧(RN の FlatList)では、動いても前に見た署名と同じになる。申告は推測より強い
            let revisited = previous != nil && contentSignature != previous
                && seenSignatures.contains(contentSignature)
            unchanged = (contentSignature == previous || revisited) ? unchanged + 1 : 0
            if let previous, contentSignature != previous, !revisited { lastChangeAt = clock.now }
            if let previous, contentSignature != previous { contentEverMoved = true }
            seenSignatures.insert(contentSignature)
            if let last = lastFullSwipe {
                let moved = EdgeProbe.contentDisplacement(before: last.before.elements, after: settled.snapshot.elements,
                                                          region: region, vertical: vertical)
                if let moved, let reference = last.travel ?? lastFullMoved,
                   EdgeProbe.stoppedShort(displacement: moved, fingerTravel: reference) {
                    probeNext = true
                    probeEvidence = (moved, reference)
                // 「揃った」は中身が動いた回だけ読む。nil(共通の行が残らないほど動いた = 窓の狭い一覧)も動いた側に数える
                } else if moved != 0,
                          EdgeProbe.flushAgainstStaticFrame(before: last.before.elements, after: settled.snapshot.elements,
                                                            region: region, finger: direction) {
                    probeNext = true
                    probeFlush = true
                }
                if probeNext {
                    probeAnchorIDs = EdgeProbe.movedIDs(before: last.before.elements, after: settled.snapshot.elements,
                                                        region: region, vertical: vertical)
                }
                lastFullMoved = moved
                lastFullSwipe = nil
            }
            // 短いドラッグで中身が動いた = 端ではなかった → 全力の送りへ戻る
            if lastWasProbe, unchanged == 0 { probeNext = false }
            lastWasProbe = false
            // ヒント跳躍(WebView): 端までの残り距離が分かるときは長距離ドラッグで寄せる
            let jump = Self.offscreenEdgeJump(snapshot: settled.snapshot, finger: direction)
            // **変わってから `edgeClaimGraceAfterMove` 経つまでは端と確定しない**: 端へ飛ぶと続きを
            // 非同期に描き足す仮想化リスト(RN の FlatList)は、描き足しが**窓の外**に起きるので
            // 見えている署名が変わらない。待った直後の周回は必ず1本送る(描き足されていれば先へ進む)
            if !retryAfterGrace,
               unchanged >= Self.unchangedRoundsForEdge(snapshot: settled.snapshot,
                                                        remainingJump: jump) {
                guard try await waitedForGrace() else { reachedEdge = true; break }
            }
            retryAfterGrace = false
            // **明示 scrollFrame が解決できないなら、ここで打ち切る(1本も振らない)**。
            // 黙って全画面スワイプへ退化させない
            if Self.scrollFrameUnresolved(step, in: settled.snapshot) {
                noteCodesThisStep.insert(.scrollFrameMissing)
                return StepOutcome(status: failed(
                    .notFound,
                    Self.scrollFrameFailFastMessage(step, action: "swipe", swipes: sentSwipes)))
            }
            previous = contentSignature
            // **Android の AX 申告で「もう動かせない」と分かるなら、確かめの1本を送らずに端と確定する**
            // (driver.reachedEdgeOnLastSwipe は撃った後にしか分からない。PullToRefreshBox の先頭で
            // 確認の1本を送ると引っ張り更新に化ける実測があるため、送る前に分かるものは送らない)。
            // 容器を一意に決められない・申告が無い(iOS・旧ブリッジ)ときは nil のままなので
            // 今までどおり撃って確かめる
            let scrollingElement = Self.scrollContainerElement(step: step, in: settled.snapshot, vertical: vertical)
            if let scrollingElement,
               ScrollActionAvailability.atEdge(
                   container: scrollingElement,
                   enclosing: Self.enclosingScrollables(of: scrollingElement, step: step, in: settled.snapshot),
                   forSwipe: direction) {
                reachedEdge = true
                break
            }
            if let jump, let container = Self.webViewContainer(in: settled.snapshot),
               await hintDrag(jump: jump, container: container,
                              viewport: settled.snapshot.screen, phase: &phase) {
                hintJumps += 1
                sentSwipes += 1
                continue
            }
            if probeNext, let region,
               let probePath = EdgeProbe.path(in: region, finger: direction, avoiding: settled.snapshot.elements,
                                              moved: probeAnchorIDs) {
                if try await dragWithFallback(path: probePath,
                                              durationSeconds: EdgeProbe.durationSeconds,
                                              phase: &phase) { viaXCUITest = true }
                sentSwipes += 1
                probes += 1
                lastWasProbe = true
                continue
            }
            let path = scrollPath(step: step, intent: .edge, in: settled.snapshot)
            let swipedViaXCUITest = try await swipeWithFallback(direction, intent: .edge, path: path, phase: &phase)
            if swipedViaXCUITest { viaXCUITest = true }
            sentSwipes += 1
            // 端を申告しない構成のときだけ、次の周回で中身の動いた量を基準と比べる
            // (ドライバの申告・容器の scrollActions がある構成は今までどおり)。**iOS だけ** —— `EdgeProbe.distance` は pt で
            // 詰めた値で、Android の木は px(30px ≈ 11dp は Flutter のタッチの遊び 18 に届かず、端でなくても動かない =
            // 早すぎる端の確定になる)
            // **上端(指を下へ)だけ**: 副作用(引っ張って更新)があるのは上端だけ(EdgeProbe の冒頭)。
            // **本物の指の送りだったときだけ**: inapp-boost モードの in-app の送り(Compose / Flutter はアクセシビリティの
            // scroll)は端で撃っても引っ張りにならず、確かめを本物の短いドラッグに替えると逆に引っ張って更新を走らせた
            // (E2EX-CMP の S0020 が inapp-boost でだけ赤 = 実測)。inapp-boost モードの印は primaryCaptureOmitsSystemUI
            // (そのモードでだけ立つ = 主ドライバが in-app)、XCUITest へ回った送りは本物の指
            let fingerSwipe = !primaryCaptureOmitsSystemUI || swipedViaXCUITest
            if !isAndroid, direction == .down, fingerSwipe, driver.reachedEdgeOnLastSwipe == nil,
               scrollingElement?.scrollActions == nil {
                lastFullSwipe = (settled.snapshot,
                                 path.map { vertical ? abs($0.toY - $0.fromY) : abs($0.toX - $0.fromX) })
            }
            // **ドライバが「もう端」と言えるなら、署名の2回不変を待たない**。
            // 位置を直接動かせる経路(Android の CDP・in-app の contentOffset)は
            // 「余地が無い」を**事実として**知っており、こちらの推測より強い。
            // 申告も上の「不変」と同じく、最後の変化から `edgeClaimGraceAfterMove` 経つまでは確定しない
            // (飛んだ直後の申告は、描き足す前の「今は余地が無い」でしかない)。確認の読みで木が
            // 変わっていたらループへ戻る
            // **false(= 確かに動かした)は署名より強い「動いた」**: 端へ飛ぶたびにセルが同じ座標に並ぶ
            // 画面(RN の FlatList)では、動いても型と座標の署名が変わらず「不変」に見える
            if driver.reachedEdgeOnLastSwipe == false {
                contentEverMoved = true
                lastChangeAt = clock.now
                previous = nil
            }
            if driver.reachedEdgeOnLastSwipe == true {
                let confirm = try await settledSignature(phase: &phase)
                if !confirm.settled { sawUnsettled = true }
                let confirmed = Self.edgeSignature(confirm.snapshot,
                                                   contentRegion: edgeContentRegion(step: step, in: confirm.snapshot))
                if confirmed == previous {
                    guard try await waitedForGrace() else { reachedEdge = true; break }
                    retryAfterGrace = true
                } else {
                    previous = confirmed
                    lastChangeAt = clock.now
                }
                carried = confirm
            }
        }
        // **前面を奪われていたなら、端に着いたとも ok とも言わない**(ランチャーの上を払って「端」と確定し、失敗が次の手まで出なかった)。
        // 木が変わらない = 端、は自アプリが前面に居る間だけ成り立つ。確かめるのは送り終えた後の1回だけ(scrollTo の打ち切りと同じ)
        // **始点の木が起こしたアプリのものでないとき**(送る前から前面を離れていた = Android の木はランチャー)は、起こしたアプリを基準に引く
        let leftBeforeStart = launchedBundleID.flatMap { launched in
            edgeBundleID.map { $0 != launched ? ($0, launched) : nil } ?? nil
        }
        let expectedBundleID = leftBeforeStart?.1 ?? edgeBundleID
        if sentSwipes > 0, let front = await frontAppIfSessionAppLeft(expectedBundleID, tree: lastEdgeTree, asksAppState: false) {
            let before = leftBeforeStart.map { " (the tree was already \($0.0), not \($0.1), when the swipes started)" } ?? ""
            return StepOutcome(status: failed(.notFound,
                "\(step.action ?? "scrollToEdge") stopped after \(sentSwipes) swipe(s): the app was not in the foreground"
                + " (\(front) was in front)\(before), so the swipes did not reach its list and the end of the list is not known"
                + " — \(Self.bringBackAdvice(front: front))"))
        }
        // 上限で抜けたら**端に着いたとは限らない**。黙って成功にすると
        // 「scrollToBottom したのに末尾が無い」の原因が読めなくなる
        var notes: [String] = []
        if !reachedEdge { notes.append("stopped at the limit of \(limit) (may not have reached the edge yet)") }
        if reachedEdge, sentSwipes > 0, !contentEverMoved {
            notes.append("the visible content did not move during \(sentSwipes) swipe(s) — the list was either already at"
                + " that edge, or the swipes did not reach a scrolling list (pass scrollFrame: to aim at the list)")
        }
        if let note = pendingScrollFrameNote { notes.append(note) }
        if viaXCUITest { notes.append("fell back to XCUITest") }
        if hintJumps > 0 { notes.append("\(hintJumps) long drag(s) from scroll hints") }
        if probes > 0 {
            noteCodesThisStep.insert(.edgeProbedGently)
            let why = probeFlush ? "the content came to rest flush with the edge of its frame"
                : probeEvidence.map { "the last swipe moved the content \(Int($0.moved.rounded()))pt,"
                    + " short of \(Int($0.travel.rounded()))pt" } ?? "the last swipe stopped short"
            notes.append("confirmed the edge with \(probes) short drag(s) instead of full swipes (\(why))")
        }
        if sawUnsettled { note(.settleCapped, into: &notes) }
        return StepOutcome(status: .passed,
                           driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
    }

    // フリック(Shirates flickXxx 8種)。scrollableElement は持たず scrollFrame のセレクタ式
    // (nil = 画面全体)で表す。**repeat 回とも同じ座標を撃つ**(Shirates は容器を毎回測り直さない。
    // TestDriveSwipeExtension.kt 参照)。整定待ちは「swipe」アクションと同じ形で末尾に1回だけ
    // (ランナー側は /swipe を整定対象から外しているため)
    func executeDirectFlick(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let clock = ContinuousClock()
        guard let kind = FlickKind(rawValue: step.direction ?? "") else {
            return StepOutcome(status: .failed("unknown flick kind: \(step.direction ?? "")"))
        }
        let times = max(1, step.maxSwipes ?? 1)
        let durationSeconds = step.duration ?? tunables.defaultFlickDuration
        let intervalSeconds = step.intervalSeconds ?? tunables.defaultFlickInterval

        var path: FTSwipePath?
        if Self.coordinateScrollEnabled {
            // **枠は静止した木から取る**(キャッシュを迂回して2枚一致まで。settledSignature が phase へ計上する)。
            // 画面遷移の直後に撃つと、動いている最中か古い木の枠へ指を置いてリストが1pt も動かない
            // (Android の CMP / Flutter / RN で間欠。遷移のタップから約 0.5 秒後に撃って `top=row_01` のまま)
            let settled = try await settledSignature(phase: &phase)
            if settled.changed { noteCodesThisStep.insert(.settledBeforeGesture) }
            let snapshot = settled.snapshot
            let container: FTRect?
            if let rect = step.scrollFrameRect {
                container = rect
            } else if let locator = step.scrollFrame {
                container = LocatorResolver.match(locator, in: snapshot)?.frame
            } else {
                container = snapshot.screen
            }
            // **明示 scrollFrame が解決できないなら、ここで打ち切る(1本も振らない)**。
            // 黙って全画面スワイプへ退化させない(scroll/scrollToEdge と同じ理由)。
            // rect は常に解決済みなのでこの分岐に来ない
            if step.scrollFrame != nil, container == nil {
                noteCodesThisStep.insert(.scrollFrameMissing)
                return StepOutcome(status: failed(
                    .notFound,
                    Self.scrollFrameFailFastMessage(step, action: "flick", swipes: 0)))
            }
            if let container {
                path = ScrollGeometry.flickPath(
                    container: container, viewport: snapshot.screen, kind: kind,
                    startMarginRatio: step.startMarginRatio
                        ?? FTScrollDefaults.startMarginRatio(intent: .gesture, vertical: kind.isVertical))
                // **容器は解決したが動かせる幅が無い**(margin で潰れた等)。黙って全画面へ
                // 落ちると理由が読めなくなる(scrollPath と同じ注記)
                if path == nil, step.scrollFrame != nil || step.scrollFrameRect != nil {
                    pendingScrollFrameNote = "the specified scrollFrame resolved but leaves"
                        + " nothing to move, so the whole screen was swiped"
                }
            }
        }

        var viaXCUITest = false
        if let path {
            for _ in 0..<times {
                if times > 1 {
                    let waitStart = clock.now
                    try await Task.sleep(for: .milliseconds(Int(intervalSeconds * 1000)))
                    phase.waitMs += Self.ms(clock.now - waitStart)
                }
                // in-app の drag は自前描画だけ(それ以外は 501)ため、inapp-boost モードでは
                // typeDriver(XCUITest)へ回す(swipePointToPoint と同じ理由)
                if try await dragWithFallback(path: path, durationSeconds: durationSeconds,
                                              phase: &phase) {
                    viaXCUITest = true
                }
            }
        } else {
            // 殺しスイッチ有効時、または領域を削りすぎて座標を作れないとき: 向き基準の汎用スワイプへ
            // 落ちる(scroll アクションが scrollPath nil のとき辿る経路と同じ考え方)
            if try await swipeWithFallback(kind.fingerDirection, phase: &phase) { viaXCUITest = true }
        }
        let settled = skippingSettle(step) ? true : try await settledSignature(phase: &phase).settled
        var notes: [String] = []
        if let note = pendingScrollFrameNote { notes.append(note) }
        if viaXCUITest { notes.append("fell back to XCUITest") }
        if !settled { note(.settleCapped, into: &notes) }
        return StepOutcome(status: .passed,
                           driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
    }

    // **座標タップ**(`tap(x:y:)`)。要素解決を一切通さない = アプリが要素を1つも公開しない
    // 画面のための経路。**locator があるときはここへ来ない** —— セレクタで指せるなら常に
    // そちらを使う(FlowStep.x の宣言。用途を問わない規律)
    func executeDirectCoordinateTap(step: FlowStep, x: Double, y: Double,
                                    phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let hold = step.duration ?? FlowStep.defaultTapHoldSeconds
        return try await executeCoordinateTouch(operation: "tap", x: x, y: y, phase: &phase) { driver in
            if hold > 0 {
                try await driver.press(x: x, y: y, duration: hold)
            } else {
                try await driver.tap(x: x, y: y)
            }
        }
    }

    /// **座標のダブルタップ**(`doubleTap(x:y:)`)。座標タップと同じ安全策を共有する。
    /// **`gestureActions` の対象未指定経路へ流さない**(x/y を見ず画面中心を撃つ)。
    /// **撃った後に整定を待つ**(セレクタ形・画面中心形の doubleTap = `performGesture` と揃える。
    /// ダブルタップはズーム等のアニメーションを起こすので、待たないと形によって次の解決が古い木を掴む)
    func executeDirectCoordinateDoubleTap(step: FlowStep, x: Double, y: Double,
                                          phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let outcome = try await executeCoordinateTouch(operation: "doubleTap", x: x, y: y, phase: &phase) {
            try await $0.doubleTap(x: x, y: y)
        }
        let settled = skippingSettle(step) ? true : try await settledSignature(phase: &phase).settled
        guard !settled else { return outcome }
        var notes = outcome.driverFallback.map { [$0] } ?? []
        note(.settleCapped, into: &notes)
        return StepOutcome(status: outcome.status, driverFallback: notes.joined(separator: " / "))
    }

    /// 座標で撃つ操作(tap / press / doubleTap)の共通部。`fire` は撃つドライバを受ける。
    /// **画面の外の点は撃たずに断る**。木を読まない経路は負の座標だけ(`swipePointToPoint` と同じ = 正常系に往復を足さない。
    /// executor は直前の木を控えていない)、木を読む経路(iOS の inapp-boost の自前描画)は画面の大きさまで見る。
    /// 正の画面外は木を読まない経路では各ブリッジの判定に任せる(フレームワークで割れる = framework-differences FD-2.1)
    private func executeCoordinateTouch(operation: String, x: Double, y: Double, phase: inout PhaseAccumulator,
                                        fire: (AppDriver) async throws -> Void) async throws -> StepOutcome {
        if let refusal = Self.offscreenTouchPointRefusal(operation: operation, x: x, y: y, screen: nil) {
            return StepOutcome(status: .failed(refusal))
        }
        let clock = ContinuousClock()
        let start = clock.now
        var note: String?
        // **自前描画(か判定不明)のアプリで、木のどの要素も含まない点は最初から XCUITest で撃つ**。
        // in-app の合成タッチは要素の無い点で届いた確証が無く、Compose の Popup の「外側タップで閉じる」に
        // 届かないまま成功を返していた(実測: E2EX-CMP のメニュー。XCUITest では閉じる)
        if let td = typeDriver, uiFramework?.isSelfRendered != false {
            let snapshot = try await driver.snapshot()
            if let refusal = Self.offscreenTouchPointRefusal(operation: operation, x: x, y: y, screen: snapshot.screen) {
                return StepOutcome(status: .failed(refusal))
            }
            if !snapshot.elements.contains(where: { Self.frame($0.frame, containsX: x, y: y) }) {
                try await fire(td)
                phase.actionMs += Self.ms(clock.now - start)
                return StepOutcome(status: .passed,
                                   driverFallback: "sent via XCUITest (no element at this point in the tree)")
            }
        }
        do {
            try await fire(driver)
        } catch {
            // in-app は座標ジェスチャを持たない(501)。inapp-boost モードでは XCUITest へ回す
            guard DriverError.isBridgeIncapable(error), let td = typeDriver else { throw error }
            try await fire(td)
            note = "fell back to XCUITest"
        }
        phase.actionMs += Self.ms(clock.now - start)
        return StepOutcome(status: .passed, driverFallback: note)
    }

    /// 座標の tap / doubleTap の点が画面の外なら断る文。`screen` が nil なら負の座標と非有限だけ(`isDragPointOffScreen`)、
    /// あれば MCP・CLI・ライブ操作と同じ `TapTargetGeometry.isPointOnScreen`(半開区間 = 幅ちょうどは外。ft_batch の座標の手と
    /// 1:1 で書き換えられる行なので、同じ点の判定を MCP と割らない)
    static func offscreenTouchPointRefusal(operation: String, x: Double, y: Double, screen: FTRect?) -> String? {
        let outside = screen.map { !TapTargetGeometry.isPointOnScreen(x: x, y: y, screen: $0) }
            ?? TapTargetGeometry.isDragPointOffScreen(x: x, y: y, screen: nil)
        guard outside else { return nil }
        let size = screen.map { " (\(Int($0.width))x\(Int($0.height)))" } ?? ""
        return "\(operation): the point (\(x), \(y)) is outside the screen\(size), so nothing was sent."
            + " Use coordinates inside the screen"
    }

    /// 端ちょうどは含む(in-app ブリッジの画面内判定と同じ閉区間)
    static func frame(_ frame: FTRect, containsX x: Double, y: Double) -> Bool {
        x >= frame.x && x <= frame.x + frame.width && y >= frame.y && y <= frame.y + frame.height
    }

    /// 座標どうしのドラッグ(DSL の `swipePointToPoint` / ft_batch)。**撃つのは `dragWithFallback` だけ**
    /// (in-app の drag は UIKit/SwiftUI で 501。直に `driver.drag` を呼ぶと inapp-boost モードで XCUITest へ回らない)。
    /// 押してから動かすまでは 0.05 秒固定(長押しから始まる並べ替えは `gesture` の `.hold` で書く)
    func executeDirectPointToPoint(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        guard let x = step.x, let y = step.y, let toX = step.toX, let toY = step.toY else {
            return StepOutcome(status: .failed("swipePointToPoint needs startX, startY, endX and endY"))
        }
        if let refusal = Self.offscreenDragPointRefusal(x: x, y: y, toX: toX, toY: toY, screen: nil) {
            return StepOutcome(status: .failed(refusal))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let latchedBefore = dragFallbackLatched
        var startX = x
        var startY = y
        var bandNote: String?
        if let band = await driver.backGestureEdgeWidths(), band.bottom > 0 || band.left > 0 || band.right > 0 {
            let screen = try await snapshotForScrollFrame(phase: &phase).screen
            if let refusal = Self.offscreenDragPointRefusal(x: x, y: y, toX: toX, toY: toY, screen: screen) {
                return StepOutcome(status: .failed(refusal))
            }
            let cleared = ScrollGeometry.clearingBottomGestureBand(y: y, viewport: screen, bottom: band.bottom)
            startY = cleared.y
            if cleared.moved { bandNote = Self.bottomBandNote }
            let side = ScrollGeometry.clearingSideGestureBand(x: x, viewport: screen, left: band.left, right: band.right)
            startX = side.x
            if side.moved { bandNote = Self.joinNotes(bandNote, Self.sideBandNote) }
        }
        try await dragWithFallback(fromX: startX, fromY: startY, toX: toX, toY: toY, pressSeconds: FlowStep.defaultDragPressSeconds,
                                   durationSeconds: step.duration ?? tunables.defaultSwipeDuration)
        phase.actionMs += Self.ms(clock.now - start)
        // 払いの尾(慣性)が止まるまで待つ(swipeBy と同じ整定。待たないと Android では次の tap が慣性に吸われる)
        var settleNotes: [String] = []
        if !(skippingSettle(step) ? true : try await settledSignature(phase: &phase).settled) {
            note(.settleCapped, into: &settleNotes)
        }
        return StepOutcome(status: .passed,
                           driverFallback: Self.joinNotes(
                               dragFallbackLatched && !latchedBefore ? "fell back to XCUITest" : nil, bandNote,
                               settleNotes.first))
    }

    /// 始点か終点が画面の外なら撃たずに断る文(判定は `TapTargetGeometry.isDragPointOffScreen`。縁ちょうどは内)。
    /// `screen` が nil の段は木を読まずに言える負の座標・非有限だけ、Android の帯の補正で木を読んだ段は画面の大きさまで見る
    static func offscreenDragPointRefusal(x: Double, y: Double, toX: Double, toY: Double, screen: FTRect?) -> String? {
        let size = screen.map { " (\(Int($0.width))x\(Int($0.height)))" } ?? ""
        for (label, px, py) in [("start", x, y), ("end", toX, toY)]
        where TapTargetGeometry.isDragPointOffScreen(x: px, y: py, screen: screen) {
            return "swipePointToPoint: the \(label) point (\(px), \(py)) is outside the screen\(size), so the drag would"
                + " not start or end on the screen and nothing was sent. Use coordinates inside the screen"
        }
        return nil
    }

    static let sideBandNote = "start point moved clear of the Android back-gesture band at the screen edge (a touch there is taken as back)"

    /// 始点を下端のジェスチャ帯の外へ寄せたときの注記(Android のジェスチャナビ。
    /// 帯の中から始めると OS のホーム・アプリ切替に取られてアプリが離脱する)
    static let bottomBandNote = "start point moved above the Android bottom gesture band (home / app switch)"

    /// swipeBy が Android の戻るジェスチャの帯幅を読めず、帯を除かずに払った回の注記
    static let backGestureBandUnreadNote = "could not read the Android back-gesture band (dumpsys of SystemUI), so the drag"
        + " was not kept out of it — a drag that starts or ends at a screen edge can be taken as back"

    /// 要素を押す点を下端のジェスチャ帯の外へ寄せたときの注記(タップ・長押し・ダブルタップ)
    public static let bottomBandTapNote = "touched the part of the element above the Android bottom gesture band"
        + " (its centre is inside the band, where a touch can go to home / app switch)"

    /// 押す点を下端のジェスチャ帯の外へ寄せた y(寄せなければ nil)。判定は `BottomGestureBandTap`(MCP・ライブ操作と共有)
    func bottomBandTapY(for frame: FTRect, screen: FTRect) async -> Double? {
        await BottomGestureBandTap.tapY(for: frame, screen: screen, isAndroid: isAndroid, driver: driver)
    }

    // ピンチ・ダブルタップ・相対ドラッグ(斜め可)の**対象未指定版** = 画面全体を対象にする。
    // ロケータ付きは下の switch(要素解決・ヒール・スクロール探索にそのまま乗せるため)で、
    // 対象の決め方以外は performGesture に集約してある
    func executeDirectUntargetedGesture(_ action: String, step: FlowStep,
                                        phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let snapshot = try await snapshotForScrollFrame(phase: &phase)
        // **ピンチだけは領域を絞る** —— 指の2点が別々のものに載るとパンに化ける
        // (理由と実測は PinchRegion)。doubleTap は中心を叩くだけ・swipeBy は比率の基準が
        // 変わるので絞らない。Android は領域の短辺から指の幅を決めるので渡さない
        // キーボードが出ていればその上だけ(`PinchRegion.area(in:)` = MCP と同じ。キーの上の指は欄の文字を消す)
        let picked = PinchRegion.area(in: snapshot)
        let area = !isAndroid && ["pinchOut", "pinchIn"].contains(action)
            && (picked.narrowed || picked.region != snapshot.screen) ? picked.region : nil
        let outcome = try await performGesture(
            action, step: step, target: area ?? snapshot.screen, identifier: nil,
            viewport: snapshot.screen, phase: &phase)
        guard area != nil else { return outcome }
        return StepOutcome(status: outcome.status, driverFallback: Self.joinNotes(
            outcome.driverFallback,
            "pinched the middle of the screen so both fingers stay on the same thing"))
    }

    // 要素が見つかるまでスクロール(見つかったら成功。操作はしない)
    func executeDirectScrollTo(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let result = try await runScrollSearch(step: step, phase: &phase)
        let note = recordedScrollSearchNote(result, scrollFrameNote: pendingScrollFrameNote)
        guard result.found else {
            return StepOutcome(status: failed(.notFound, scrollSearchFailureMessage(step, result)))
        }
        resolvedElementThisStep = result.element
        if let fallback = result.fallback {
            return StepOutcome(status: .passedViaFallback(fallback), driverFallback: note)
        }
        return StepOutcome(status: .passed, driverFallback: note)
    }

    /// **ロケータなしの type / clearInput / pressEnter は焦点の欄へ撃つ** —— Android で前面が起こしたアプリでなければ
    /// 注記 `ref-less-input-on-other-app` を立てる(撃つ。断らない = 新しい検知は警告から。基準の `launchedBundleID` は
    /// openURL やアプリ内のリンクで別のアプリへ移っても残るので、断ると正しいシナリオを赤にする)。
    /// 判定は MCP(こちらは断る)と共有の `PreFireGuard.refLessInputBlocked`。聞くのは Android の前面のアプリ名だけ
    /// (dumpsys 1回。Emulator で約 30ms)。起こしていない(home / アプリ切替の後)ときは聞かない。
    /// シェード・ロック画面の下は前面のアプリ名が下のアプリのままなので、シェードの焦点とキーガードも聞く(MCP と同じ材料)
    func noteRefLessInputOnOtherApp() async {
        guard isAndroid, let launched = launchedBundleID else { return }
        var facts = ForegroundFacts(launched: launched, sessionBundleID: launched)
        facts.front = await ForegroundState.frontProbe(driver)
        facts.shadeHoldsInputFocus = await driver.systemUIHoldsInputFocus()
        if facts.shadeHoldsInputFocus.value == true { facts.keyguardShowing = await ForegroundState.keyguardProbe(driver) }
        if PreFireGuard.refLessInputBlocked(by: ForegroundState.judge(facts)) {
            noteCodesThisStep.insert(.refLessInputOnOtherApp)
        }
    }

    // ロケータ指定のない type はフォーカス中の要素へ送る(直前の tap でフォーカスした欄など)。
    // ref: nil = ブリッジがフォーカス中要素へ入力(iOS/Android とも)。ロケータ解決を挟まない。
    func executeDirectUnfocusedType(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        await noteRefLessInputOnOtherApp()
        let clock = ContinuousClock()
        // **replace はここでも型の有無に関わらず効かせる**(下の clearInput ロケータなし版と
        // 同じヘルパを通す)。ここで見落とすと `type(text, replace: true)` だけ無言で追記に戻る
        var replaceFallbackNote: String?
        if step.replace == true {
            switch try await performClearInputFocused(phase: &phase) {
            case .cleared(let fallback, _):
                replaceFallbackNote = fallback
            case .failed(let message):
                return StepOutcome(status: .failed(message))
            }
        }
        let text = step.text ?? ""
        // **`tap(入力欄)` → `type("文字列")` を成立させる**(Shirates 伝統の書き方)。
        // Android の入力欄は容器(TextInputLayout)と中身(TextInputEditText)に分かれ、
        // **id は容器側に付くことが多い** —— 容器を叩いても入力フォーカスは中身へ移らないので、
        // 素直に書くと次の type が「フォーカスが無い」で落ちていた。
        // **払うのは tap の直後だけ**(木を1枚読む)。自動フォーカスに任せる書き方や、
        // pressEnter で欄を移った直後の type は読み足さない。
        // 改行入りは typeDriver(XCUITest)へ回す経路があり ref の体系が別なので触らない
        // 直前に叩いた欄は tap だけでなく、hideKeyboard を挟んだ直前の type / clearInput の欄も含む(`tapTargetBeforeThisStep`)
        if let tapped = tapTargetBeforeThisStep, !text.contains("\n"),
           let recovered = try await retypeTargetIfUnfocused(after: tapped, phase: &phase) {
            // retypeTargetIfUnfocused が撮った撮り直し後の snapshot の keyboardFrame
            // (= 打つ前の状態。retypeRescueKeyboardFrame の doc)
            let keyboardBefore = retypeRescueKeyboardFrame
            let start = clock.now
            do {
                try await driver.type(ref: recovered.ref, text: text)
            } catch where typeDriver != nil && DriverError.isTextInputFallback(error) {
                // typeDriver がある = inapp-boost モードで主ドライバは in-app。その 409 は「打たずに断った」(焦点が別の欄・受け口が無い・
                // 挿入の失敗・キーウィンドウが無い)で、どれかは文言に入れない(検知の入力から決まらない)。**xcuitest モードの 409 は
                // セッション消失**(`SessionRecoveryDriver`)なので捕まえない。ブリッジの文言は「ref を渡せ」(MCP の語彙)で DSL では
                // 従えないので載せない。叩きは届いていることがあるので撃ち直さない。Flutter の SearchAnchor は叩くと検索欄を新しい層に開き、
                // 閉じる前の木に残った古いバーの欄を救済が選ぶ(焦点を申告しない木では見分けられない)
                phase.actionMs += Self.ms(clock.now - start)
                return StepOutcome(status: failed(.driverError,
                    "did not type: the preceding tap left no field the tree reported as focused, so the text was aimed at"
                        + " \(TapTargetGeometry.describe(recovered)), but the in-app bridge refused to type into it (HTTP 409) and"
                        + " nothing was typed. If the tap opened a new input (a search field that opens over the screen), point at"
                        + " that field with a selector: type(\"<selector of the opened field>\", …)"
                        + (replaceFallbackNote.map { " (before this, replace: true cleared the focused field: \($0))" }
                            ?? (step.replace == true ? " (before this, replace: true cleared the focused field)" : ""))))
            }
            phase.actionMs += Self.ms(clock.now - start)
            // 文言は動的(入れた先を名指しする)のでコードだけ立てる
            // —— 外側の execute が collectedNotes() で拾う(StepOutcome.notes の doc)
            noteCodesThisStep.insert(.typeFocusRecovered)
            // ロケータ有り type(case "type")と同じ読み返し規律: in-app は「200 が返った = 入った」
            // を保証しない。**ここには actingDriver が無い**(この分岐はロケータ解決前の早期
            // return で、フォールバックドライバの選定を通らない)ので driver で判定する。
            // recovered は retypeTargetIfUnfocused が撮った撮り直し後のスナップショット由来
            // なので、その時点の値をそのまま「撃つ前の値」として使ってよい(clearInput 等の
            // 反映も込み)
            if !driver.verifiesTypedText, TypeReadback.isTextInput(recovered) {
                let existingValue = TypeReadback.normalizedValue(of: recovered)
                if let failure = try await verifyTypedText(driver, element: recovered,
                                                            expected: existingValue + text,
                                                            typedOnly: text, consumptionBaseline: retypeRescueTreeBefore,
                                                            phase: &phase) {
                    return StepOutcome(status: .failed(failure))
                }
            }
            let recoveredPrior = TypedInputCheck.Prior(
                target: recovered, priorValue: TypeReadback.normalizedValue(of: recovered), replace: false,
                treeBefore: [])
            if let failure = await typedInputFailure(driver, prior: recoveredPrior, text: text, phase: &phase) {
                return StepOutcome(status: .failed(failure))
            }
            // ロケータ有り type(case "type")と同じ判定(keyboardFrameBeforeType の doc)。
            // 「打った後」はここでは読まない —— 次のロケータ操作が解決のために撮る最初の
            // 木で比べる(ブリッジに依存しない)
            if !step.skipsSettle {
                keyboardFrameBeforeType = keyboardBefore
                pendingTypeKeyboardCheck = true
                pendingTypeEndedWithNewline = text.hasSuffix("\n")
            }
            return StepOutcome(status: .passed,
                               driverFallback: Self.joinNotes(replaceFallbackNote,
                                   "typed into \(TapTargetGeometry.describe(recovered))"
                                       + " (the tree showed no focused field after the preceding tap)"))
        }
        // ロケータ有り type(下記 case "type")と同じ規則: "\n" を含むときだけ
        // typeDriver(XCUITest)へ回し、iOS の Return キー既定挙動に揃える(理由は同 case のコメント参照)。
        // **tap の直後なら、先に焦点が立つのを待つ**(pressEnter と同じ待ち)。この経路は焦点救済
        // (上の retypeTargetIfUnfocused)も読み返しも通らず、Return で即確定するので打ち直せない ——
        // E2E-RN で tap(#field_single) → type("pqr\n") が "pq" で確定した(tap が速くなった v110 以降に初出)。
        // 焦点が既に立っていれば 1 枚読むだけで抜ける
        var focusNote: String?
        if text.contains("\n"), typeDriver != nil, lastTapTarget != nil {
            focusNote = try await awaitFocusBeforeKeyInput("type", phase: &phase)
        }
        // 事後の照合の「打つ前」: 前の数が要る形(iOS の非 ASCII)だけ打つ直前に木を1枚読む(`TypedInputCheck.Prior(focusedIn:)`)
        let typedPrior = await focusedPriorForTyping(driver, text: text, phase: &phase)
        let start = clock.now
        if text.contains("\n"), let td = typeDriver {
            try await td.type(ref: nil, text: text)
        } else {
            try await driver.type(ref: nil, text: text)
        }
        phase.actionMs += Self.ms(clock.now - start)
        if let failure = await typedInputFailure(driver, prior: typedPrior, text: text, phase: &phase) {
            return StepOutcome(status: .failed(failure))
        }
        // **改行(IME アクション)で焦点は次の欄へ移りうる** —— 叩いた欄を覚えたままだと、続くロケータなしの type が
        // 「焦点が木に無い」(次の欄がキーボードの下)を救済の対象と読んで、叩いた欄(移る前の欄)へ打つ
        if text.contains("\n") { lastTapTarget = nil }
        return StepOutcome(status: .passed, driverFallback: Self.joinNotes(replaceFallbackNote, focusNote))
    }

    // pressEnter もロケータを持たない(フォーカス中の入力欄への Enter 押下)ので、type(ref: nil)
    // と同じ理由でロケータ解決を挟まない。409(inapp が Compose 以外の入力欄/フォーカス無しで
    // 出す。InAppBridge.handlePressEnter 参照)は type のロケータ版と同じ形で
    // typeDriver(xcuitest)へフォールバックする(判定は DriverError.isTextInputFallback)
    func executeDirectPressEnter(phase: inout PhaseAccumulator) async throws -> StepOutcome {
        await noteRefLessInputOnOtherApp()
        let clock = ContinuousClock()
        let focusNote = try await awaitFocusBeforeKeyInput("pressEnter", phase: &phase)
        let start = clock.now
        do {
            try await driver.pressEnter()
        } catch {
            guard DriverError.isTextInputFallback(error) else { throw error }
            guard let td = typeDriver else {
                return StepOutcome(status: .failed("the in-app bridge refused to press Enter in the focused field (HTTP 409), and no XCUITest bridge is available to retry"))
            }
            try await td.pressEnter()
            phase.actionMs += Self.ms(clock.now - start)
            return StepOutcome(status: .passed,
                               driverFallback: Self.joinNotes(focusNote, "fell back to XCUITest"))
        }
        phase.actionMs += Self.ms(clock.now - start)
        return StepOutcome(status: .passed, driverFallback: focusNote)
    }

    // hideKeyboard もロケータを持たない。Android はブリッジ(出ているときだけ戻るキー)、iOS は入力欄の外を叩く
    // (executeIOSHideKeyboard。iOS のブリッジは 501 のまま撃たない)
    func executeDirectHideKeyboard(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        // **直前の type のキーボードが出るのを先に待つ**: type はキーボードの表示を待たずに返るので、すぐ閉じに行くと
        // 「まだ出ていない = 閉じるものが無い」で何もせずに返り、その後に出たキーボードが次の back() を飲む
        // (E2EY-RN の Android の戻るの横取り S0040: back が「画面が変わらない」で赤)
        if pendingTypeKeyboardCheck {
            _ = try await consumePendingTypeKeyboardCheck(try await freshSnapshot(.afterOwnMove), phase: &phase)
        }
        if !isAndroid { return try await executeIOSHideKeyboard(step: step, phase: &phase) }
        let clock = ContinuousClock()
        let start = clock.now
        // Android はドライバが出ているかを確かめてから送る = 送らなかった事実を印で返す(MCP が「送らなかった」と言う)
        hideKeyboardFoundNoKeyboard = !(try await driver.hideKeyboardIfShown())
        phase.actionMs += Self.ms(clock.now - start)
        // 木からキーボードが消えるのを待つのは次のロケータ操作の解決(pendingHideKeyboardWait の doc)。
        // **何も送らなかった回も立てる** —— dumpsys が「出ていない」と答えても木はキーボードを数秒残す(doc の実測の形そのもの)。
        // 木にキーボードが無ければ費用はゼロ
        if isAndroid, !step.skipsSettle {
            pendingHideKeyboardWait = step.timeout ?? tunables.defaultTimeout
        }
        return StepOutcome(status: .passed)
    }

    /// **iOS の hideKeyboard はキーボードの上の空きを叩く**(ブリッジに依らない = 座標のタップだけ。ユーザー決定)。
    /// iOS には閉じる共通の手段が無い(`KeyboardDismissPoint` の doc)。叩く点はキーボードの上を下から上へ走査した空き
    /// (`KeyboardDismissPoint.candidates`。押せる部品が木に無い点)で、**木に載らないもの(キーボード・ステータスバー・
    /// トースト等の別のウィンドウ)の上でないとブリッジの当たり判定で確かめた点**(`AppDriver.tapProbe` = in-app だけが答える。
    /// 答えないブリッジは木だけで決め、木に載る最も上の要素より上は叩かない)。見つからなければ待って撮り直す(トーストが消えれば空きが出る)。
    /// 上限 = 検証の既定の待ち。叩いても閉じない・叩ける点が無いときは **Enter を送る**(ユーザー決定。欄の確定操作が走るので
    /// 注記に出す)。それでも閉じなければ失敗。**黙って成功にしない**: 叩いた点と、キーボード以外で画面が変わったかを注記に出す。
    /// キーボードが出ていなければ何もしない(Android と同じく冪等。`hideKeyboardFoundNoKeyboard` を立てるだけ)
    func executeIOSHideKeyboard(step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let tried: String
        // 印はステップの入口(StepExecutor.executeStep)が戻し済み
        switch try await closeKeyboardByTappingOutside(step: step, phase: &phase) {
        case .notShown:
            hideKeyboardFoundNoKeyboard = true
            return StepOutcome(status: .passed)
        case .closed(let note, _): return StepOutcome(status: .passed, driverFallback: note)
        case .notClosed(let what): tried = what
        }
        guard hideKeyboardFallsBackToEnter else {
            return StepOutcome(status: .failed("the keyboard is still shown: \(tried); Enter was not sent"))
        }
        // **背景で閉じなければ Enter**(ユーザー決定)。Enter はキーボードを閉じる操作ではなく欄の確定操作(検索・送信・
        // 次の欄への移動)なので、撃ったことを必ず注記に出す
        // 焦点の欄の値を Enter の前に控える(複数行の欄では Enter が改行を入れる。閉じなかったとき事実で言うため。値は文言に出さない)
        let focusedBeforeEnter = try? await freshSnapshot(.afterOwnMove).elements.first { $0.focused == true }
        let enter = try await executeDirectPressEnter(phase: &phase)
        guard StepExecutor.isSuccess(enter.status) else {
            return StepOutcome(status: .failed("the keyboard was not closed: \(tried), and"
                + " sending Enter failed too"))
        }
        var afterEnter = try await awaitKeyboardClosed(within: step.timeout ?? tunables.defaultTimeout, phase: &phase)
        // Enter の直後の1回の読みは、キーボードが出たままでも枠を申告しない瞬間がある(複数行の欄で閉じていないのに閉じたと読んだ)。
        // 閉じたと読んだら、閉じるアニメーションの長さより空けてもう一度読み、まだ出ていれば失敗にする
        if !KeyboardWait.isShown(afterEnter) {
            try await Task.sleep(for: .seconds(Self.keyboardClosedConfirmSeconds))
            afterEnter = try await freshSnapshot(.afterOwnMove)
        }
        let enterNote = "sent Enter, which also fires the field's return-key action (search, submit or moving to the next field;"
            + " in a multi-line field it inserts a newline)"
        guard !KeyboardWait.isShown(afterEnter) else {
            let changed = Self.focusedValueChanged(before: focusedBeforeEnter, after: afterEnter)
            return StepOutcome(status: .failed("the keyboard is still shown: \(tried), and \(enterNote)"
                + " did not close it either"
                + (changed ? " — the focused field's value changed after Enter (a newline was probably added to it; every"
                    + " further hideKeyboard() adds another)" : "")))
        }
        return StepOutcome(status: .passed,
                           driverFallback: Self.joinNotes("closed the keyboard: \(tried), so \(enterNote)",
                                                          enter.driverFallback))
    }

    /// Enter の前に焦点を持っていた欄の値が、後の木の同じ欄で変わったか(純粋)。同じ欄 = identifier(あれば)、無ければ枠の左上。
    /// 見つからない・前に焦点の欄が無ければ false(言えないことは言わない)
    static func focusedValueChanged(before: ElementInfo?, after: SnapshotResponse) -> Bool {
        guard let before else { return false }
        let match = after.elements.first {
            if let id = before.identifier { return $0.identifier == id && $0.type == before.type }
            return $0.type == before.type && $0.frame.x == before.frame.x && $0.frame.y == before.frame.y
        }
        guard let match else { return false }
        return match.value != before.value
    }

    /// キーボードを閉じた結果。`after` は閉じたのを確かめた木(主ドライバ)
    enum KeyboardClose {
        case notShown
        case closed(note: String, after: SnapshotResponse)
        /// 閉じなかった。値は試したこと(失敗文・Enter の注記に入れる)
        case notClosed(String)
    }

    /// **副作用の無い手段だけで**キーボードを閉じる: iOS はキーボードの上の空きを叩く(`closeKeyboardByTappingOutside`)、
    /// Android は出ているときだけ戻るキー(ブリッジの hideKeyboard)。Enter は撃たない(欄の確定操作 = 送信・検索が走る)。
    /// 呼び手はキーボードの下の対象へ届かせる tap・type・clearInput(人も閉じてから押す。ユーザー決定)
    func closeKeyboardWithoutSideEffects(step: FlowStep, phase: inout PhaseAccumulator) async throws -> KeyboardClose {
        guard isAndroid else { return try await closeKeyboardByTappingOutside(step: step, phase: &phase) }
        let clock = ContinuousClock()
        var start = clock.now
        let before = try await freshSnapshot(.afterOwnMove)
        phase.snapshotMs += Self.ms(clock.now - start)
        guard KeyboardWait.isShown(before) else { return .notShown }
        start = clock.now
        try await driver.hideKeyboard()
        phase.actionMs += Self.ms(clock.now - start)
        let after = try await awaitKeyboardClosed(within: step.timeout ?? tunables.defaultTimeout, phase: &phase)
        guard !KeyboardWait.isShown(after) else { return .notClosed("hiding the keyboard (back key) did not close it") }
        return .closed(note: "closed the keyboard (back key)", after: after)
    }

    /// iOS: キーボードの上の空きを叩いて閉じる(手順は `executeIOSHideKeyboard` の doc。Enter へは進まない)
    func closeKeyboardByTappingOutside(step: FlowStep, phase: inout PhaseAccumulator) async throws -> KeyboardClose {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(step.timeout ?? tunables.defaultTimeout)
        var lastReason = ""
        var point: KeyboardDismissPoint.Choice?
        // 叩ける空きが無いときの OS の入力補助バーの Done(WebView の欄。KeyboardAccessoryDone)
        var accessoryDone: ElementInfo?
        var unconfirmed = false
        // 木だけで決める経路(XCUITest)で前回の木が選んだ点。次の木も同じ点を選んだときだけ叩く
        var unconfirmedSeen: KeyboardDismissPoint.Choice?
        var before: SnapshotResponse
        var keyboard: FTRect
        searching: while true {
            var nextUnconfirmed: KeyboardDismissPoint.Choice?
            defer { unconfirmedSeen = nextUnconfirmed }
            var start = clock.now
            before = try await freshSnapshot(.afterOwnMove)
            phase.snapshotMs += Self.ms(clock.now - start)
            guard KeyboardWait.isShown(before) else { return .notShown }
            let occlusion = KeyboardOcclusion.resolve(reported: before.keyboardFrame, in: before.elements,
                                                      screen: before.screen)
            guard let frame = occlusion.frame ?? before.keyboardFrame else { return .notShown }
            keyboard = frame
            let candidates = KeyboardDismissPoint.candidates(
                elements: before.elements, screen: before.screen, keyboard: keyboard,
                overlays: before.overlayWindowFrames ?? [])
            if candidates.isEmpty {
                lastReason = "there is no empty spot above the keyboard (every point is on an element that could react"
                    + " or on a text, an image, a card or an overlay)"
                // 空きが無くても、OS の入力補助バーに Done があれば人はそれを押す(待たずに)。Enter は欄の確定操作が走る
                if let done = KeyboardAccessoryDone.target(in: before.elements, keyboard: keyboard) {
                    accessoryDone = done
                    break searching
                }
            }
            var refusals: [String] = []
            for candidate in candidates.prefix(Self.keyboardDismissProbeLimit) {
                start = clock.now
                let answer = await driver.tapProbe(x: candidate.x, y: candidate.y)
                phase.actionMs += Self.ms(clock.now - start)
                guard let answer else {
                    // 答えられないブリッジ(XCUITest)は木だけで決める。別のウィンドウは木の overlayWindowFrames で
                    // 除いてある。木に載らないステータスバーは、木に載る最も上の要素より上を叩かないことで避ける
                    if let contentTop = Self.topmostElementY(before), candidate.y >= contentTop {
                        // 木だけで決める点は、続けて2回の木で同じ点が選ばれてから叩く(キーボードの枠と木のレイアウトが
                        // 食い違っている間 = 下にあるはずのタブが枠の裏にいる木では、空きが実際には押せる部品の上になる)
                        if let seen = unconfirmedSeen, seen.x == candidate.x, seen.y == candidate.y {
                            point = candidate; unconfirmed = true; break searching
                        }
                        nextUnconfirmed = candidate
                        lastReason = "the tree and the keyboard frame had not settled (the spot to tap changed between two"
                            + " reads)"
                        break
                    }
                    lastReason = "this bridge cannot check a spot for a status bar or another window, and every"
                        + " empty spot is above the topmost element in the tree"
                    continue
                }
                if answer.background { point = candidate; break searching }
                refusals.append("(\(Int(candidate.x)), \(Int(candidate.y))) \(answer.reason ?? "could react")"
                    + (answer.receiver.map { " on \($0)" } ?? ""))
            }
            if !refusals.isEmpty { lastReason = "every spot checked could react to a tap — " + refusals.prefix(3).joined(separator: "; ") }
            guard clock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(Int(FocusWait.pollSeconds * 1000)))
        }
        var tried: [String] = []
        if let point {
            var start = clock.now
            try await driver.tap(x: point.x, y: point.y)
            phase.actionMs += Self.ms(clock.now - start)
            let place = "(\(Int(point.x)), \(Int(point.y))) above the keyboard"
            let after = try await awaitKeyboardClosed(within: Self.keyboardCloseAfterTapWaitSeconds, phase: &phase)
            if !KeyboardWait.isShown(after) {
                var notes = ["closed the keyboard by tapping \(place)"
                    + (unconfirmed ? " (this bridge cannot check for a status bar or another window there; chosen from"
                        + " the tree only)" : "")]
                let vanished = Self.contentAbove(keyboard, in: before).subtracting(Self.contents(of: after))
                if !vanished.isEmpty {
                    let named = vanished.sorted().prefix(3).map { $0.replacingOccurrences(of: "|", with: " ") }
                    notes.append("\(vanished.count) element(s) that were above the keyboard are gone after that tap"
                        + " (\(named.joined(separator: ", "))) — check that it did not trigger something")
                }
                return .closed(note: notes.joined(separator: " / "), after: after)
            }
            tried.append("tapping \(place) did not close it")
        } else if accessoryDone == nil {
            tried.append("\(lastReason) (waited \(FTSeconds.format(step.timeout ?? tunables.defaultTimeout))s), so nothing"
                + " was tapped")
        }
        // 空きを叩いても閉じなかった・叩ける空きが無かったときは、OS の入力補助バーの Done を押す(KeyboardAccessoryDone)
        // inapp-boost モードの主ドライバの木に OS のバーは載らない(別の窓)ので、XCUITest の木で探して XCUITest で押す
        var done = accessoryDone ?? KeyboardAccessoryDone.target(in: before.elements, keyboard: keyboard)
        var doneDriver = driver
        if done == nil, let td = typeDriver, let tree = try? await td.snapshot() {
            done = KeyboardAccessoryDone.target(in: tree.elements, keyboard: tree.keyboardFrame ?? keyboard)
            doneDriver = td
        }
        if let done {
            let x = done.frame.centerX, y = done.frame.centerY
            let start = clock.now
            try await doneDriver.tap(x: x, y: y)
            phase.actionMs += Self.ms(clock.now - start)
            let after = try await awaitKeyboardClosed(within: Self.keyboardCloseAfterTapWaitSeconds, phase: &phase)
            if !KeyboardWait.isShown(after) {
                let why = tried.isEmpty ? lastReason : tried.joined(separator: "; ")
                return .closed(note: "closed the keyboard by tapping the Done button of its toolbar at (\(Int(x)), \(Int(y)))"
                    + (why.isEmpty ? "" : " (\(why))"), after: after)
            }
            tried.append("tapping the Done button of the keyboard's toolbar did not close it")
        }
        return .notClosed(tried.joined(separator: "; "))
    }

    /// キーボードが消えるまで撮り直して待つ(上限 `seconds`)。最後に撮った木を返す
    private func awaitKeyboardClosed(within seconds: Double, phase: inout PhaseAccumulator) async throws -> SnapshotResponse {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)
        while true {
            let start = clock.now
            let snapshot = try await freshSnapshot(.afterOwnMove)
            phase.snapshotMs += Self.ms(clock.now - start)
            if !KeyboardWait.isShown(snapshot) || clock.now >= deadline { return snapshot }
            try await Task.sleep(for: .milliseconds(Int(FocusWait.pollSeconds * 1000)))
        }
    }

    /// 背景を叩いた後、キーボードが閉じるのを待つ上限(秒)。**根拠**: iOS のキーボードが閉じるアニメーションは約 0.3 秒で、
    /// 閉じる作りのアプリはその直後の木で消える(閉じた瞬間に抜ける)。**尽きたときの発話**: 「叩いても閉じなかった」として Enter へ進む
    static let keyboardCloseAfterTapWaitSeconds: Double = 1.5

    /// Enter の後に「閉じた」と読んでから読み直すまでの間(秒)。**根拠**: 上の閉じるアニメーション約 0.3 秒より長く空ける。
    /// **尽きたときの発話**: 読み直しでまだ出ていれば「Enter でも閉じなかった」と失敗にする
    static let keyboardClosedConfirmSeconds: Double = 0.5

    /// 木に載る要素の最も上の y(画面の内側だけ)。木に載らないステータスバーより下を叩くための境
    static func topmostElementY(_ snapshot: SnapshotResponse) -> Double? {
        snapshot.elements.map(\.frame.y).filter { $0 > snapshot.screen.y }.min()
    }

    /// iOS の hideKeyboard で当たり判定を聞く候補の数の上限。**根拠**: 1点 = in-app への HTTP 1往復(数〜数十 ms)。
    /// 候補は領域ごとの代表なので、Compose・Flutter のように画面全体が1つの面のアプリでは全部同じ答えになる =
    /// 多く聞いても結果は変わらず待ちが延びるだけ。**尽きたときの発話**: 確かめた点と理由を3つまで失敗文に出す
    static let keyboardDismissProbeLimit = 8

    /// キーボードの上端より上の要素の顔ぶれ(id、無ければ型・ラベル。位置は見ない)。叩いた後に**消えた要素**があるかを見る比較用 ——
    /// キーボードが閉じると画面が伸び直して位置が変わり、隠れていた要素が現れるので、増えた・動いたは数えない
    /// (画面遷移・ダイアログやトーストが消えた形だけを拾う)
    static func contentAbove(_ keyboard: FTRect, in snapshot: SnapshotResponse) -> Set<String> {
        Set(snapshot.elements.filter { $0.frame.y + $0.frame.height <= keyboard.y }.map(signature))
    }

    static func contents(of snapshot: SnapshotResponse) -> Set<String> { Set(snapshot.elements.map(signature)) }

    /// id があれば id だけで見る(キーボードに一部隠れた要素は Compose の iOS でラベルが空で来て、閉じると付く =
    /// 型・id・ラベルで比べると、残っている要素を「消えた」と言った)
    private static func signature(_ element: ElementInfo) -> String {
        if let id = element.identifier, !id.isEmpty { return "#\(id)" }
        return "\(element.type)|\(element.label ?? "")"
    }

    // clearInput もロケータ無しならフォーカス中欄へ作用する(type(ref: nil) と同じくロケータ解決を
    // 挟まない)。対象なし(409)またはこのブリッジでは未対応(isBridgeIncapable)なら
    // typeDriver(xcuitest)へフォールバックする
    func executeDirectUnfocusedClearInput(phase: inout PhaseAccumulator) async throws -> StepOutcome {
        await noteRefLessInputOnOtherApp()
        switch try await performClearInputFocused(phase: &phase) {
        case .cleared(let fallback, _):
            return StepOutcome(status: .passed, driverFallback: fallback)
        case .failed(let message):
            return StepOutcome(status: .failed(message))
        }
    }

    /// pressEnter 直前の焦点待ち(MCP の awaitFocus と同じレース対策: タップ直後、対象欄へ
    /// フォーカスが立つ前の Enter は前の欄へ飛ぶ)。pressEnter はロケータを持たないので特定の
    /// 要素は狙わず、**木のどこかが focused を申告する / キーボードが出ている**のどちらかを
    /// 合図として待つ。値は FTCore.FocusWait(MCP と共有)。
    ///
    /// **keyboardShown はプラットフォーム分岐せず毎回確かめる**: xcuitest/in-app は
    /// snapshot のたびに申告するが、Android は captureKeyboardStateOnNextSnapshot() を
    /// 撮る前に立てないと申告されない(executeAssertKeyboardShown と同じ制約)ので、
    /// 毎周回立て直す(iOS では no-op)。focused だけでは Compose iOS(in-app は
    /// UIResponder でない a11y 要素の focused を申告しない)を待ち続けてしまうので、
    /// keyboardShown を第二の合図として持つ。
    ///
    /// 合図が出ないまま waitSeconds 経過したら拒否せず注記を返す(呼び出し側で driverFallback へ合流)。
    /// **ロケータ無しで改行入りの type も同じ待ちを通す**(tap の直後だけ。下記 case "type" の呼び出し参照)
    private func awaitFocusBeforeKeyInput(_ operation: String,
                                          phase: inout PhaseAccumulator) async throws -> String? {
        let clock = ContinuousClock()
        let deadline = Date().addingTimeInterval(FocusWait.waitSeconds)
        while true {
            driver.captureKeyboardStateOnNextSnapshot()
            let start = clock.now
            let snapshot = try await driver.snapshot(bypassingCache: driver.supportsCacheBypass)
            phase.snapshotMs += Self.ms(clock.now - start)
            if snapshot.elements.contains(where: { $0.focused == true })
                || KeyboardWait.isShown(snapshot) { return nil }
            guard Date() < deadline else {
                return "no field ever took focus within \(FocusWait.waitSeconds)s before \(operation)"
                    + " — the keys may have gone to whichever field still had it"
            }
            let waitStart = clock.now
            try? await Task.sleep(for: .seconds(FocusWait.pollSeconds))
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
    }
}
