// ブリッジ実装が変わったことを検出し、版数の引き上げを促す。検出は2段:
//   ルート表  … エンドポイントの増減(どのルートが変わったかまで言える)
//   ソース指紋 … 実装ファイルの内容変化(ルートが同じでハンドラだけ変えた場合を捕まえる)
//
// 事故の形(実害2回): 実装を変えたのに版数を上げず、稼働中の旧ブリッジが「版一致」として
// 再利用され、変更が反映されないまま緑になる。
// 版数は片側だけ上げても検出できるが(iOS = BridgeAPI.bridgeProtocolVersion は
// ホスト・in-app・XCUITest ランナーの共有定数 / Android = AndroidBridgeVersionSyncTests)、
// 「そもそも上げ忘れた」は人間の規律だけが頼りだった。
//
// **このテストの限界**: 版数を上げること自体は強制できない(ここの期待値だけ更新して版数を
// 据え置くことは手続き上できてしまう)。リポジトリ内の期待値は書き換え可能なので原理的に
// これ以上は詰められない。目的は「無音で緑になる」状態を「版数の判断を意識的に迫られる」
// 状態へ変えることまで。
//
// 指紋は生バイトで取るため、**コメント編集でも落ちる**(意図的な設計)。文字列リテラル中の
// `//` を素朴に削るコメント除去は変更を見逃す側に倒れるので、誤検出の側を選んでいる。
// 落ちたら「版を上げるべき変更か」を判断し、上げないなら期待値だけ貼り替える。
// 入力ファイルの一覧は Sources/FTCore/BridgeSourceSet.swift(定義はそこ1箇所)。

import XCTest
import FTCore

final class BridgeContractTests: XCTestCase {

    // 期待するルート表。**変更したら対応する版数を必ず上げること**:
    // (この3つは internal = docs/design/ のエンドポイント表と突き合わせる
    //  BridgeDocRouteSyncTests から参照する。**唯一の正はここ**で、あちらは写し)
    //   in-app / XCUITest ランナー → Sources/FTCore/BridgeDTO.swift の bridgeProtocolVersion
    //   Android                    → AndroidRunner/build.sh の VERSION_CODE と
    //                                Sources/FTAndroid/AndroidBridge.swift の expectedBridgeVersionCode
    // 3実装でルートが異なるのは仕様。共通コアは13本で、差分は:
    //   in-app     … 同一プロセスしか見えないので /appswitcher・/home を持たない(/drag はアプリ内の座標ドラッグとして持つ)
    //   /locale    … Android だけ
    //   /settle    … Android だけ(ホストが adb で撃った操作〈launch・戻るキー〉の整定を
    //                 ブリッジに待たせる口。ブリッジ経由の操作は応答内で待つので不要)
    //   /hidekeyboard … iOS の2実装だけ(中身は 501。Android はホスト側の戻るキーで実現するため
    //                   ルートを持たない)
    //   /appstate  … iOS の2実装だけ
    //   /pinch・/doubletap … 3実装とも持つ(in-app は 2026-08-04 に追加。合成タッチの間隔と
    //                 指の距離を自分で決められるぶん XCTest より正確な場面がある)
    //   /rotate    … iOS の2実装だけ(62)。Android は host-side adb(AndroidDriver)で行うため持たない
    //   /gesture   … XCUITest ランナーと Android だけ(iOS 126 / Android 72)。in-app は持たず、inapp-boost モードは
    //                 既定の 501 で XCUITest へ回す(指ごとの時刻つき経路を1回で再生する)
    //   /pickerValue … XCUITest ランナーだけ(pickerWheel を adjust で合わせる。frame で引く)・/pickerStep … Android だけ(NumberPicker を1段送る)。
    //                 in-app は持たず、inapp-boost モードは XCUITest へ回す
    //   /hold      … XCUITest ランナーと Android だけ。in-app は持たず、inapp-boost モードは XCUITest へ回す
    //                 (指を置いたら応答を返す = 置いている間に木を読める)
    //   /touchlands … in-app だけ(本物のタッチの当たり判定。XCUITest の isHittable の false を確かめる材料。
    //                 ランナーは 404 = 呼び手は「答えられない」と読んで断るまま)
    static let inAppRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /appstate", "POST /clear", "POST /doubletap", "POST /drag", "POST /hidekeyboard", "POST /tapprobe", "POST /touchlands", "POST /pinch",
        "POST /press", "POST /pressEnter", "POST /rotate", "POST /session", "POST /sliderStep", "POST /swipe",
        "POST /tap", "POST /terminate", "POST /type",
    ]

    static let xcuiTestRoutes: Set<String> = [
        // GET /hittable は「その ref を撃つと本当に当たるか」を XCUITest 自身に聞く照会
        // (2026-08-14 追加。BridgeRouter.handleHittable の doc に費用の実測がある)
        "GET /hittable",
        // GET /systemalert は「SpringBoard のアラートが載っているか」だけを聞く軽い口
        // (2026-08-21 追加。木を全部撮る /snapshot は約 185ms・こちらはアラート無しで約 73ms)
        "GET /systemalert",
        "GET /systemui/covering",
        // /systemui/* は SpringBoard を**セッションを触らずに**読む/叩く口
        // (2026-08-25 追加・版 79)。ref は専用の名前空間 = ランナーの systemRefFrames。
        // xcuitest モードは主ドライバと同じブリッジを共有するので、
        // 旧経路(POST /session springboard)だとアプリのセッションが巻き添えになる。
        // drag / swipe は座標を **SpringBoard 基準**で撃つ(版 80)—— tapAppIcon は
        // home() の直後に呼ぶので、セッションのアプリを原点にする /drag では
        // 背面アプリの座標解決でランナーごと落ちる(BridgeRouter.systemUIAnchor)
        "GET /systemui/snapshot", "POST /systemui/tap",
        "POST /systemui/drag", "POST /systemui/swipe",
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /appstate", "POST /appswitcher", "POST /clear", "POST /doubletap", "POST /drag",
        "POST /gesture", "POST /hidekeyboard", "POST /hold", "POST /hinge", "POST /home", "POST /pickerValue", "POST /pinch", "POST /press", "POST /sliderPosition",
        "POST /pressEnter", "POST /rotate", "POST /session", "POST /swipe", "POST /tap", "POST /terminate",
        "POST /type",
        // 要素の描画の出どころ(v306)。UI フレームワークが不明のときの空打ちの判断が引く。in-app / Android は持たない(既定の nil)
        "POST /renderer",
        // waitForSettle(v174)。画面全体を撮るのでセッションを要さない。in-app は持たない(アプリ自身の描画しか撮れない)
        "POST /waitForSettle",
        // 応答時間計測(v192)。契約は FTCore/ResponseMeasurementWire.swift(Android と共有)
        "POST /responsePrepare", "POST /responseCollect", "POST /responseObservation", "POST /responseObservationStop",
    ]

    static let androidRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /clear", "POST /doubletap", "POST /gesture", "POST /hold", "POST /locale", "POST /pickerStep", "POST /pinch", "POST /press", "POST /sliderSet", "POST /sliderStep",
        "POST /pressEnter", "POST /scrollAction", "POST /session", "POST /settle", "POST /swipe",
        "POST /tap", "POST /terminate", "POST /type",
        "POST /waitForSettle",
        // Flutter の VM サービスの塗り順(Android v154〜。DR-235)
        "POST /semanticsorder",
        // 応答時間計測(Android v102〜)。in-app は持たない
        "POST /responsePrepare", "POST /responseCollect", "POST /responseObservation", "POST /responseObservationStop",
    ]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    func testInAppBridgeRoutesUnchanged() throws {
        try assertRoutes(
            file: "InAppBridge/Sources/InAppBridge.swift",
            pattern: swiftRoutePattern,
            expected: Self.inAppRoutes,
            versionHint: "Sources/FTCore/BridgeDTO.swift の bridgeProtocolVersion"
                + "(現在 \(BridgeAPI.bridgeProtocolVersion))")
    }

    func testXCUITestRunnerRoutesUnchanged() throws {
        try assertRoutes(
            file: "Runner/FleetestRunnerUITests/BridgeRouter.swift",
            pattern: swiftRoutePattern,
            expected: Self.xcuiTestRoutes,
            versionHint: "Sources/FTCore/BridgeDTO.swift の bridgeProtocolVersion"
                + "(現在 \(BridgeAPI.bridgeProtocolVersion))")
    }

    func testAndroidBridgeRoutesUnchanged() throws {
        try assertRoutes(
            file: "AndroidRunner/src/com/example/ftbridge/BridgeRouter.java",
            pattern: javaRoutePattern,
            expected: Self.androidRoutes,
            versionHint: "AndroidRunner/build.sh の VERSION_CODE と "
                + "Sources/FTAndroid/AndroidBridge.swift の expectedBridgeVersionCode")
    }

    // MARK: - ソース指紋

    /// 相対パス → 内容の SHA256。**実装を変えたら対応する版数を上げてから**貼り替えること。
    /// 貼り付け用のリテラルは失敗メッセージがそのまま出力する(手でハッシュを写さない)。
    private static let expectedFingerprints: [BridgeSourceSet: [String: String]] = [
        .inApp: [
"InAppBridge/Sources/Bridging.h": "08799e6d190f958eed7c6bb4406f1cbbfea1bed1d252ce4572636273c65a5aad",
            "InAppBridge/Sources/DisplayHeartbeat.swift": "845b796af6d9a176780a96c852f9a2ccace5923d672ca947404adf2ba156b0de",
            "InAppBridge/Sources/InAppBridge.swift": "c831233acaf51359a48655dd2f5b318a4d6a27d34cb8a7973a12a6d546374cb7",
            "InAppBridge/Sources/InAppHTTPServer.swift": "d48cbe3699bc3fcf1de6558e033ea8812816207efc3aaf3f9210d4aee58e174c",
            "InAppBridge/Sources/InAppInput.h": "7cc1d91f345ce6e66ad6c58d1f5a8242c558d48759a769c6d24532bc06cd2a6f",
            "InAppBridge/Sources/InAppInput.m": "957ab1127102f1eeaacdabd38284943d3e11fb63304d9e7c8a93f8b804b7b852",
            "InAppBridge/Sources/InAppSettle.swift": "85d64ffd99da7d3eeb465aaaeddd1b481bdaa21de166001641184895b310d4a4",
            "InAppBridge/Sources/InAppSnapshot.swift": "06a5c8296a78308310ac26d4f1c1083cc6337aac0deffdcc0b78b0586477897b",
            "InAppBridge/Sources/InAppTapProbe.swift": "f612eb38316c5440aeca26df02b56b077f15bcc54702268bd0a8b54a0658e06b",
            "InAppBridge/Sources/InAppTouchLands.swift": "e6af2d8d1e7316658c123f8ede820899e9264280656027e997fe534c30631dec",
            "InAppBridge/Sources/InAppWebViewDOM.swift": "f7cddfb392708d0bbb6bae2a423e0281b653f1a4991e95d90faf62f7ae0ebfad",
            "InAppBridge/Sources/boot.m": "b23fc93fbc99ce2579c9fd8ae75a6f9bbfd0ec6122bec60eb6cd00775dd635ef",
            "InAppBridge/build.sh": "8840d78ef646796b4ed1e8da9d288c1f8ad0545ed5b47a01f40d5a05dcc7cca1",
            "Sources/FTCore/AXFrameRescale.swift": "eef63f86079f246da9f30f7543f4efb7e912eb70f6a01c721dde6789a1ebe7e7",
            "Sources/FTCore/BridgeDTO.swift": "b3e95cac876969da1d621f814dcf3fd06403686c6300b6cf8a56d6e6960ce506",
            "Sources/FTCore/BridgeSnapshotThinning.swift": "1b467ca47963d6ced8f8f50ced2d3cf0f14a7a560dc7ca2fecbbad07fd642514",
            "Sources/FTCore/TypeReadback.swift": "42a09f40d3f6280bc31b44a0859103308a75255893011fa6e2afedaa95783af1",
            "Sources/FTCore/UIFrameworkMarkers.swift": "6e40a5724138a0cc5b0b6f915e0cce19e5bb3468854cefe97893c7a152a742b6",
            "Sources/FTCore/WebViewDOMSnapshot.swift": "4b615ddb73538abcc1f3cdf70517d8b6f9cf4a12bba0e8c60bd6d5ceb05ae0b7",
        ],
        .xcuitest: [
            "Runner/FleetestRunnerUITests/BridgeHTTPServer.swift": "ef8c6573ab25f9cbdfed21e483ce74f1eb5d1a4345bc57a2d5b9ed2eb86b860e",
            "Runner/FleetestRunnerUITests/BridgeRouter+Renderer.swift": "4c75fb95f95ed6a69c5d8a97d13329e3622ea58aac974f83b960763e768aa44c",
            "Runner/FleetestRunnerUITests/BridgeRouter+Snapshot.swift": "d181a95425a851188d9e190d4e696896f3e80f045f8de6a1b0c9ae6836bd0fa9",
            "Runner/FleetestRunnerUITests/BridgeRouter+TextInput.swift": "148ca2d43e5db2b963c99d14e54a904c4cf587dda5ff1895292437b075587c9b",
            "Runner/FleetestRunnerUITests/BridgeRouter.swift": "42ecd949ff58c50a134b447bd11a0a8ef6ad82c4d94700399dfc634035968c24",
            "Runner/FleetestRunnerUITests/BridgingHeader.h": "61af8b60b5173c25c8203d6f44b2c44b191a374902ba96956c904f518e4b7413",
            "Runner/FleetestRunnerUITests/CoordinatePinch.swift": "ebb8c8348f4dc8826e0555370a5386d627ce5210dfe49f4ecacae9addc8b9ad9",
            "Runner/FleetestRunnerUITests/DisplayHeartbeat.swift": "c62c30a45e842d5ec7aff60210284d679b76f6e44358a3f4c97429fe918e5ffa",
            "Runner/FleetestRunnerUITests/DisplayRouting.swift": "4c2a45c043a5915ffacfb174dc7af5c6561c0fa3223d08779a4956a825e1891c",
            "Runner/FleetestRunnerUITests/ElementClassQuery.h": "bde3ca75ec4fd8cf63d38177b038588876fa6e58cba1846019e8d10e01bd0490",
            "Runner/FleetestRunnerUITests/ElementClassQuery.m": "91c5b00e74da1dc28fb3aeb74f9338dc46a3886de04a3b4fa49bf79bdbb45ed6",
            "Runner/FleetestRunnerUITests/FleetestBridgeTests.swift": "1a799c33e09a7ea451b36c58d9906d28b03fca7e84b6a02b598fca92e81c3b3c",
            "Runner/FleetestRunnerUITests/InterruptionGuard.swift": "e7f59d446f4e6d438ad235c6ca5ee6d2b6db4a1f22b7648a1da74d7d3fca34b5",
            "Runner/FleetestRunnerUITests/ObjCExceptionCatcher.h": "5a98cdbeefb031137a985b2f4430a5e12fec447a492599f8f4da1bd2c7101edc",
            "Runner/FleetestRunnerUITests/ObjCExceptionCatcher.m": "8b41a8a81bc8199bca13a364717614684f8003999c7675d9a63242c8e74c26be",
            "Runner/FleetestRunnerUITests/QuiescenceWait.swift": "751baf56335b98bf50d61c4d2727ebcae7351fe3da37a0af1b06620cacff14bd",
            "Runner/FleetestRunnerUITests/ResponseMeasurement.swift": "6254e04c6f0a85d4504e45657f847f6d1a761fe2f635819b482457c34dd095b1",
            "Runner/FleetestRunnerUITests/VirtualHID.swift": "8ee358d73f27c9aabefbd6f98e41091dfde837ee8f15e5066997df1d97df802e",
            "Sources/FTCore/AXFrameRescale.swift": "eef63f86079f246da9f30f7543f4efb7e912eb70f6a01c721dde6789a1ebe7e7",
            "Sources/FTCore/BridgeDTO.swift": "b3e95cac876969da1d621f814dcf3fd06403686c6300b6cf8a56d6e6960ce506",
            "Sources/FTCore/BridgeSnapshotThinning.swift": "1b467ca47963d6ced8f8f50ced2d3cf0f14a7a560dc7ca2fecbbad07fd642514",
            "Sources/FTCore/IOSRendererMarkers.swift": "5eea4c1b28ba36e723cc5faa377636c1b3198ee8141f2f24230ee90d59fdefdc",
            "Sources/FTCore/ResponseMeasurementWire.swift": "19f9ba212d1ce05ad3431dd350895329f0fc62a8bdbf6210c362583d22175dcd",
            "Sources/FTCore/SnapshotDedupe.swift": "f987a913f2010e8cd81e381c595c15242f58225c71a11a9be206590baccf8c9b",
            "Sources/FTCore/TypeReadback.swift": "42a09f40d3f6280bc31b44a0859103308a75255893011fa6e2afedaa95783af1",
        ],
        .android: [
            "AndroidRunner/AndroidManifest.xml": "cf43535a8f8e3361bafd6761b99cbf9e4347afd9ac76d42ed82da0e032908b17",
            "AndroidRunner/build.sh": "b136074f6bd0753af9c4186ec066407492125748aef24dd13e6556cfd3c3524a",
            "AndroidRunner/src/com/example/ftbridge/BridgeHttpServer.java": "042e90f918e2b15e03293e881bd082bce59077921731929631101b6ded1b0eb4",
            "AndroidRunner/src/com/example/ftbridge/BridgeInstrumentation.java": "78fe5cc272782a091bbbc512d1693bed0a192cf363548699a586cb0f3d614824",
            "AndroidRunner/src/com/example/ftbridge/BridgeRouter.java": "6fa0497aef7343f232b02185da9842b8c47be772cf209919ad51b3977d5e17f2",
            "AndroidRunner/src/com/example/ftbridge/DisplayHeartbeat.java": "77528d6e36f12d477cc3dfe4d9920f5ce69ad7912bc2461b698ace89a0ba6808",
            "AndroidRunner/src/com/example/ftbridge/FirstFrameState.java": "378cd2f84f8fa12de57da78bc19354933bf10ef32691d0225c6950b52109770a",
            "AndroidRunner/src/com/example/ftbridge/FlutterSemanticsOrder.java": "62bc8109fb910c1599621d85481fb58e3ea28160d23fedc8f263c950cd7ae20b",
            "AndroidRunner/src/com/example/ftbridge/ImeOnboarding.java": "fe2d90d892046f64e4893c008148d47886e36bceb244dd9e68e560b368f0193b",
            "AndroidRunner/src/com/example/ftbridge/InputInjector.java": "e6551ba915adff55978f064ab9de36683b1920c3a5e2cdaec736208682c83181",
            "AndroidRunner/src/com/example/ftbridge/KeyboardPrimerActivity.java": "f5a4751486cd8349a8f10b65332d6a3e1d77c3d82e0528e8518ec646aad152d9",
            "AndroidRunner/src/com/example/ftbridge/QuietWaiter.java": "b939eb89d48c6a3591a78b8457b31f851cd95c0f188fffdaa1668f557153347d",
            "AndroidRunner/src/com/example/ftbridge/ResponseObserver.java": "f2f52a49eb907786fc7a60b89a1c89b87d417fd0e07de0c9b01054a820574f09",
            "AndroidRunner/src/com/example/ftbridge/ResponseProbe.java": "1c49c669fdc21ca27da02833f82e2f65f56dfd209b3264a8dbb2ab9f756801c1",
            "AndroidRunner/src/com/example/ftbridge/SnapshotBuilder.java": "e99834facb87b53a53f59f1b8bd9abb5cf0c0b4baf0a753b88818159e12308a4",
        ],
    ]

    func testInAppBridgeSourcesUnchanged() throws {
        try assertFingerprints(.inApp)
    }

    func testXCUITestRunnerSourcesUnchanged() throws {
        try assertFingerprints(.xcuitest)
    }

    func testAndroidBridgeSourcesUnchanged() throws {
        try assertFingerprints(.android)
    }

    /// 期待値の宣言漏れ(集合を足したのに指紋を書いていない)を検出する
    func testEveryBridgeHasExpectedFingerprints() {
        for set in BridgeSourceSet.allCases {
            XCTAssertNotNil(Self.expectedFingerprints[set],
                            "\(set.rawValue) の期待指紋が未宣言です")
        }
    }

    /// **ファイルが読めない場合は skip せず失敗させる**: 消したから緑、を作らないため
    private func assertFingerprints(_ set: BridgeSourceSet) throws {
        let actual = try set.fingerprints(repoRoot: repoRoot)
        let expected = try XCTUnwrap(Self.expectedFingerprints[set])
        guard actual != expected else { return }

        let added = actual.keys.filter { expected[$0] == nil }.sorted()
        let removed = expected.keys.filter { actual[$0] == nil }.sorted()
        let modified = actual.keys
            .filter { expected[$0] != nil && expected[$0] != actual[$0] }.sorted()

        var message = "\(set.rawValue) ブリッジの実装が変わりました"
        if !modified.isEmpty { message += "(変更: \(modified.joined(separator: ", ")))" }
        if !added.isEmpty { message += "(追加: \(added.joined(separator: ", ")))" }
        if !removed.isEmpty { message += "(削除: \(removed.joined(separator: ", ")))" }
        message += "。**\(set.versionConstantHint) を上げてから**、下記を期待値へ貼り替えること"
        message += "(版を上げないと稼働中の旧ブリッジが再利用され、変更が反映されないまま緑になる。"
        message += "コメントだけの変更など版を上げるに値しないなら、貼り替えだけでよい)"
        if set != .android {
            message += "。現在の bridgeProtocolVersion: \(BridgeAPI.bridgeProtocolVersion)"
        }
        message += "\n" + pasteableLiteral(actual)
        XCTFail(message)
    }

    private func pasteableLiteral(_ fingerprints: [String: String]) -> String {
        fingerprints.keys.sorted()
            .map { "            \"\($0)\": \"\(fingerprints[$0]!)\"," }
            .joined(separator: "\n")
    }

    // MARK: - 抽出

    /// Swift 側: `case ("GET", "/status")` → `GET /status`
    private let swiftRoutePattern = #"case \("(GET|POST)", "(/[A-Za-z][A-Za-z0-9/_-]*)"\)"#
    /// Java 側: `case "GET /status":` → `GET /status`
    private let javaRoutePattern = #"case "(GET|POST) (/[A-Za-z][A-Za-z0-9/_-]*)":"#

    private func assertRoutes(file: String, pattern: String,
                              expected: Set<String>, versionHint: String) throws {
        let url = repoRoot.appendingPathComponent(file)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("\(file) を読めません")
        }
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var found: Set<String> = []
        for match in regex.matches(in: source, range: range) {
            guard let method = Range(match.range(at: 1), in: source),
                  let path = Range(match.range(at: 2), in: source) else { continue }
            found.insert("\(source[method]) \(source[path])")
        }

        XCTAssertFalse(found.isEmpty,
                       "\(file) からルートを1件も抽出できません"
                       + "(ルーティングの書き方を変えたなら、このテストの抽出パターンも直すこと)")
        XCTAssertEqual(found, expected,
                       "\(file) のルート表が変わりました"
                       + "(追加: \(found.subtracting(expected).sorted()) / "
                       + "削除: \(expected.subtracting(found).sorted()))。"
                       + "**\(versionHint) を上げてから**、このテストの期待値を更新すること。"
                       + "上げないと稼働中の旧ブリッジが再利用され、変更が反映されないまま緑になる")
    }
}
