// MCPServer+Driver.swift
// ドライバ解決(ブリッジ・シリアル・版ズレゲート)と接続系の注記(iOS のポートの解決と診断は +BridgeResolution)。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    // MARK: - ドライバ

    /// **`driver(_:)` の唯一の呼び口はここ**: 解決(`resolveDriver`)の直後に、物理 Android なら
    /// 起こす処理を挟む。全ツールが `driver(args)` を通るので、ここ1箇所で全ツールに効く。
    /// **差し替えドライバ(テスト)では何もしない**(`prepareAndroidDeviceIfNeeded` が
    /// `makeDriver == nil` を見る)ので、既存のテストの呼び出し列は1つも変わらない
    func driver(_ args: [String: Any]) async throws -> AppDriver {
        let previousPhase = SlowCallWatchdog.mark("resolving the device's bridge")
        defer { SlowCallWatchdog.restore(previousPhase) }
        try await gateCachedVersionSkew(args: args)
        let resolved = try await resolveDriver(args)
        await prepareAndroidDeviceIfNeeded(resolved, args: args)
        return resolved
    }

    /// **物理 Android の消灯を、操作の前に起こしてから進む**(実測):
    /// 消灯中は `ft_snapshot` が注記なしで常時表示の木を返し、`ft_tap` は `done` を返し、
    /// `ft_launch` は「アプリが前面に来なかった」としか言わない —— 消灯そのものには一度も触れない。
    /// run 経路(`ProfileWorkerFactory.preparePhysicalAndroidDevices` → `AndroidPhysicalDevice.
    /// prepareForRun`)と**同じ処理を同じ粒度で**呼ぶ(起こす・ロック解除。消灯の抑止は
    /// 端末の設定のまま変えない——ユーザー決定はそのまま尊重する)。
    /// **このセッションでその機へ初めて触れたときは準備を丸ごと**(`preparedPhysicalAndroid`)、
    /// **2回目以降は画面の状態を1往復で見て、消灯・ロック中のときだけ起こす**(`wakeIfAsleep`)。
    /// 初回だけだと、セッションの途中で消えた後の `ft_launch` が 23 秒後に「アプリが前面に来なかった」
    /// とだけ言い、常時表示の snapshot を「システムダイアログ」と誤って言った(Pixel 3a で実測)。
    /// 確認は 0.1 秒前後(run のシナリオごとの確認と同じ関数)
    func prepareAndroidDeviceIfNeeded(_ resolved: AppDriver, args: [String: Any]) async {
        guard resolved is AndroidDriver, makeDriver == nil else { return }
        let key = Self.sessionKey(args)
        guard let serial = connectedAndroidSerials[key] else { return }
        // エミュレータも起こし直し後にロック画面のまま残るので、毎回の確認だけは撃つ。
        // 初回の prepareForRun(点灯・解除を最後まで待つ)は実機だけ
        // 解除できなかった旨(⚠️)は stderr だけにせず応答の警告へ載せる(MCP クライアントには stderr が見えない)。
        // 一度待ち切れた端末は以後待たない(`retriesAfterGivingUp: false`)ので、警告は毎回の応答が言う
        let log: (String) -> Void = { [self] line in
            Self.logStderr(line)
            if line.hasPrefix("⚠️") { pendingWarnings[key, default: []].append(line) }
        }
        guard DevicePicker.isPhysicalAndroidSerial(serial) else {
            await AndroidPhysicalDevice.wakeIfAsleep(serial: serial, log: log, retriesAfterGivingUp: false)
            return
        }
        guard !preparedPhysicalAndroid.contains(key) else {
            await AndroidPhysicalDevice.wakeIfAsleep(serial: serial, log: log, retriesAfterGivingUp: false)
            return
        }
        preparedPhysicalAndroid.insert(key)
        await AndroidPhysicalDevice.prepareForRun(serial: serial, log: log)
    }

    /// **操作の後に Android の画面が消灯・ロックしていたら言う**(実測: 手の途中で消灯すると、直前の tap は `ok` なのに
    /// アプリへ届いておらず、次の手の失敗文は遮蔽の経路の文言のままで消灯に触れない)。操作の前の起こし直し
    /// (`prepareAndroidDeviceIfNeeded`)は呼び出しの開始時だけなので、**呼び出しの最中の消灯**はこの確認だけが拾う。
    /// 端末を動かすツールだけ・Android だけ・差し替えドライバ(テスト)では撃たない。確認は1往復(`screenAwakeAndUnlocked`)
    func screenOffAfterCallNote(tool: String, args: [String: Any]) -> String? {
        guard makeDriver == nil, Self.toolEffects[tool] == .drivesDevice,
              let serial = connectedAndroidSerials[Self.sessionKey(args)],
              AndroidPhysicalDevice.screenAwakeAndUnlocked(serial: serial) == false else { return nil }
        return Self.screenOffAfterCallText(serial: serial)
    }

    /// 文言は事実だけ(いつ消えたかは分からない = 呼び出しの最中とは言わない)。ok の操作が届いたかは断定しない
    static func screenOffAfterCallText(serial: String) -> String {
        "⚠️ \(serial): the screen is off or locked after this call. If it went off while the call was running, an"
            + " operation reported as done may not have reached the app, and a failure may be the screen's, not the"
            + " target's — check with ft_snapshot before acting again (the next call wakes the screen first; the tool"
            + " does not keep it on)"
    }

    // **MCP の iOS は常に XCUITest**(ユーザー決定。in-app は使わない)。profile 指定時は resolveProfileTarget が
    // ft_run_scenario と同じデバイスを XCUITest で供給し、profile 無しは ExploreDriverResolver が in-app のポートでも
    // 同じデバイスの XCUITest へ振り替える
    func resolveDriver(_ args: [String: Any]) async throws -> AppDriver {
        if let makeDriver {
            // 差し替えドライバのブリッジは分からない。**助言が出る側(xcuitest)を既定**にする
            // (テストは bridges を先に埋めて別のブリッジを名乗れる)
            let key = Self.sessionKey(args)
            if bridges[key] == nil {
                bridges[key] = (args["platform"] as? String) == "android" ? "android" : "xcuitest"
            }
            let driver = try await makeDriver(args)
            // **差し替え経路でもゲートを通せるようにする**(G): 素通しにすると拒否そのものが
            // 一度も実行されず、文言だけ検証して安心する形になる。ただし既定は off ——
            // 版照合は status() を1回撃つので、呼び出し列を固定している既存テストが軒並みずれる。
            // 実運用(makeDriver 無し)の経路は下で**常に**通る
            if checksVersionOnInjectedDriver {
                try await enforceVersion(driver: driver, key: key, args: args)
            }
            return driver
        }
        if let profileName = args["profile"] as? String {
            let key = Self.driverCacheKey(profile: profileName, project: args["project"] as? String,
                                          platform: args["platform"] as? String)
            // **直接ポート経路と同じ確認を通す**(掃討で揃えた)。profile 経由でもブリッジは
            // 起動し直され、そのとき同じ profile キーが別の機を指し得る —— 片方だけ守ると
            // 「profile を使う利用者にだけ穴が残る」形になる
            if let cached = drivers[key] {
                if let moved = await deviceIdentityChanged(key, args: args) { throw MCPError(moved) }
                // **MN-51.10**: モード(xcuitest/inapp-boost)が同じ機のまま入れ替わっていないかも
                // 確かめる(udid だけでは捕まらない・ref を使わない呼び出しでも効かせる)。
                // 食い違っていれば `.refuse`(記憶に依る呼び出し)か `.rebuildSilently`
                // (依らない呼び出し。下の生成へそのまま落ちる)のどちらか
                switch await primaryBridgeCheck(key, args: args) {
                case .refuse(let message):
                    throw MCPError(message)
                case .rebuildSilently:
                    break
                case .unchanged:
                    // **inapp-boost モードの fallback(XCUITest)ポートも本人確認する**(MN-51.2): 主(in-app)の udid が
                    // 変わっていなくても、`HybridFallbackDriver` の fallback は別ポートを握ったままで
                    // 起動し直しにより別の機へ移り得る。fallback には ref が乗らないので(primary と違い)
                    // 捨てるべきセッション記憶が無い —— キャッシュだけ落として下の生成へ通す
                    // (`.inappOnly` へ静かに縮退することもある)
                    if await hybridFallbackDrifted(key) {
                        drivers[key] = nil
                        hybridFallbackPorts[key] = nil
                    } else {
                        // **profile のキャッシュ命中でも記憶を更新する**(欠陥②): 下の
                        // direct 経路のキャッシュ命中と同じ理由(rememberResolvedTarget のコメント参照)。
                        // platform 変数はここではまだ無い(resolveProfileTarget を経ていない)ので、
                        // connectionLostHint と同じく **記録(connectedPorts/connectedAndroidSerials)で
                        // 判別する**(表示ラベルの接頭辞では判別しない、と同じ規律)。iosPort は生成側と
                        // 揃えて `connectedPorts[key]` をそのまま渡す(そちらに実機は
                        // `probePort ?? provisioned.port` が既に入っている)
                        if connectedPorts[key] != nil {
                            rememberResolvedTarget(platform: "ios", args: args,
                                                   iosPort: connectedPorts[key], iosUDID: udids[key] ?? nil,
                                                   androidSerial: nil)
                        } else if let serial = connectedAndroidSerials[key] {
                            rememberResolvedTarget(platform: "android", args: args,
                                                   iosPort: nil, iosUDID: nil, androidSerial: serial)
                        }
                        return cached
                    }
                }
            }
            let project = try ScenarioHost.project(named: args["project"] as? String)
            var prologue: [String] = []
            // profile 指定の初回はブリッジ provision を伴い、コールドスタートは分単位かかりうる
            // (既存ブリッジ再利用時は数秒。進捗は stderr に出る)
            let (_, resolvedProfile, target) = try await resolveProfileTarget(
                project: project, profileName: profileName,
                platformArg: args["platform"] as? String, fallback: .firstDevice, prologue: &prologue)
            prologue.forEach(Self.logStderr)
            // **警告を stderr に捨てない**(外部フィードバック)。MCP クライアントは
            // stderr を見ないので、「runs の name が machines のデバイスに解決できない」等の
            // 設定ミスが**実行するまで表に出なかった**。次の応答に1度だけ載せる
            pendingWarnings[key] = prologue.filter { $0.hasPrefix("⚠️") }
            let created: AppDriver
            var probePort: UInt16?
            switch target {
            case .ios(let provisioned, _):
                (created, probePort) = try await Self.iosDriver(provisioned: provisioned)
            case .android(let serial, _):
                created = try await androidDriver(serial: serial, key: key, args: args)
            }
            drivers[key] = created
            profileExecutions[key] = ProfileExecutionDefaults(ScenarioExecutionSettings(resolvedProfile))
            bridges[key] = {
                if case .ios = target { "xcuitest" }   // MCP の iOS は常に XCUITest(iosDriver)
                else { "android" }
            }()
            hybridFallbackPorts[key] = nil   // MCP の iOS は XCUITest だけ(前の機の予備ポートを残さない)
            // **udid と port を両方記録する**。`deviceIdentityChanged`
            // はこの2つが揃っているときだけ動くので、**port を書かないとガードが黙って no-op になる**
            // (直接ポート経路で実際に踏んだ形。DeviceStateInvalidationTests が両方を守る)。
            // **記録するのは `provisioned.port` ではなく実際に繋いだ loopback ポート**
            // (`iosDriver` の probePort。理由はあちらの doc)—— 誤ったポートを記録すると
            // ガードが無関係な機のブリッジを読み、正しい呼び出しを拒否して記憶まで捨てる
            if case .ios(let provisioned, _) = target {
                // **生成経路でも機の入れ替わりを見る**(レビュー指摘)。
                // キャッシュ命中側だけに置くと、`enforceVersion` の拒否(`drivers[key]` だけを
                // nil にする)のあとブリッジが別のフリート機へ起動し直された回に、
                // 前の機の ref 世代と起動アプリが生き残る(直接ポート経路と同じ手当て)
                if let previousUDID = Self.keyChangedDevice(previous: udids[key] ?? nil,
                                                            now: provisioned.udid) {
                    forgetDeviceState(key)
                    pendingWarnings[key, default: []].append(
                        Self.reusedPortWarning(port: probePort ?? provisioned.port,
                                               previousUDID: previousUDID,
                                               nowUDID: provisioned.udid))
                }
                udids[key] = provisioned.udid
                // **実機は probePort が常に nil**(loopback 経由ではないため。iosDriver 参照)。
                // それをそのまま記録すると connectionLostHint の入口(connectedPorts の有無で
                // iOS/Android を振り分ける)が実機の profile 呼び出しを一度も iOS 経路に乗せず、
                // 回復(forgetConnection)が永久に起きない
                connectedPorts[key] = probePort ?? provisioned.port
            }
            if case .android(let serial, _) = target {
                connectedAndroidSerials[key] = serial
            }
            // profile 経由なら対象 bundleID が分かるので、bridge を問わず静的に判定して覚える
            // (DSL と同じ AppUIFrameworkQuery。静的に決まらなければ resolveExecutorHints が
            // in-app の自己申告まで問う)。実機は appPathPhysical(.app / .ipa)か台帳で答える
            if case .ios(let provisioned, let iosApp) = target, let bundleID = iosApp?.bundleID,
               let framework = AppUIFrameworkQuery.staticAnswer(for: .init(
                   platform: "ios", bundleID: bundleID,
                   appPath: iosApp?.packagePath(physical: provisioned.physical),
                   udid: provisioned.udid, physical: provisioned.physical)).framework {
                uiFrameworkHints[key] = UIFrameworkHint(bundleID: bundleID, framework: framework)
            }
            // **profile 経由でも宛先を記録する**。ここが空だと ft_status が
            // 「どこに繋がっているか」を出せず、**同名のデバイスが並ぶフリートでどの1台か
            // 分からない** —— Android の status.device は全エミュレータで
            // `sdk_gphone64_arm64` になるので、serial が出ないと識別子がゼロになる
            connections[key] = switch target {
            case .ios(let provisioned, _):
                "\(provisioned.simulatorName) port \(provisioned.port)"
            case .android(let serial, let deviceName):
                "\(deviceName) serial \(serial)"
            }
            // **profile 経由もセッション記憶へ記録する**(ここを呼ばないと profile 経由の宛先が
            // 一度も記憶されない)。args は
            // port/udid/serial ではなく `profile` を持つので、記録可否は recordsIOSMemory/
            // recordsAndroidMemory 側で `profile:` を明示扱いする(上記参照)。
            // **iOS は probePort でなく `probePort ?? provisioned.port` を使う**: 実機は
            // loopback 経由ではないため probePort が常に nil(iosDriver 参照)——
            // それをそのまま渡すと実機の宛先が rememberResolvedTarget の `guard let iosPort` で
            // 弾かれ、実機がまた記録されなくなる
            // **profile 経由もゲートを通す**(G-2 の「全操作系」): BridgeProvisioner が版で
            // 再利用可否を決めるので普段はここで落ちないが、**落ちないことと検査しないことは別**
            // —— 供給の判断とホストの期待がズレた回に、黙って旧ブリッジを操作させない
            try await enforceVersion(driver: created, key: key, args: args)
            // **記録は版ガードを通った後**(断られた呼び出しを「駆動した」に数えない。数えると宛先を省いた次の呼び出しが
            // 断られた機を指す・2台目と数えて曖昧の拒否に入る)
            switch target {
            case .ios(let provisioned, _):
                rememberResolvedTarget(platform: "ios", args: args,
                                       iosPort: probePort ?? provisioned.port,
                                       iosUDID: provisioned.udid, androidSerial: nil)
            case .android(let serial, _):
                rememberResolvedTarget(platform: "android", args: args,
                                       iosPort: nil, iosUDID: nil, androidSerial: serial)
            }
            // **プロファイルの autoInstall は MCP でも効かせる**: 供給がアプリを先に入れるのは in-app のときだけで、
            // MCP は XCUITest で供給する(resolveProfileTarget)ので、ここで入れないと inapp-boost モード / in-app のプロファイルで
            // 「入っていない」と ft_launch が断る。**入っていないときだけ**入れる(入れ直しは動いているアプリを
            // 終了させる = 探索中の画面を失う。差分の入れ直しは run の installIfNeeded の役目)
            if case .ios(let provisioned, let iosApp) = target, let iosApp, iosApp.autoInstall,
               let packagePath = iosApp.packagePath(physical: provisioned.physical),
               await installedVerdict(bundleID: iosApp.bundleID, driver: created, args: args) == .notInstalled {
                let installNote = try await created.install(packagePath: packagePath)
                Self.logStderr("installed \(iosApp.bundleID) from \(packagePath) (the profile's autoInstall)")
                if let installNote { Self.logStderr(installNote) }
            } else if let (bundleID, appPath, freshness) = await installedAppFreshness(
                target: target, resolved: resolvedProfile, driver: created, args: args) {
                // 入っているものが appPath と違っても入れ直さない(探索中の画面を失う)。注記で知らせる(応答に1度だけ)
                if let note = Self.staleInstalledAppNote(
                    freshness: freshness, bundleID: bundleID, appPath: appPath,
                    alreadyChecked: installedAppFreshnessChecked.contains(key)) {
                    pendingWarnings[key, default: []].append(note)
                }
                installedAppFreshnessChecked.insert(key)
            }
            return created
        }

        // **sessionKey と同じ解決を使う**(Self.platformName): ここに2つ目の既定を書くと、
        // 「どのドライバを作るか」と「どの鍵で覚えるか」が食い違う。実際 serial だけの
        // 呼び出しは、記憶側が Android と読むのにドライバは iOS を作っていた
        let platform = Self.platformName(args)
        // **udid → port の解決はここ1箇所**(H-2)。port は残す(既存の呼び出しを壊さない)
        let explicitPort = try await Self.portForIOS(args, rememberedPort: nil)
        let key = Self.driverCacheKey(platform: platform, port: explicitPort.map(Int.init),
                                      serial: args["serial"] as? String)
        if let cached = drivers[key] {
            // **キャッシュ命中のドライバが、まだ同じ機を指しているかを確かめる**。
            // sessionKey は `direct:ios:<port>:` で、**port は機の同一性ではない** ——
            // ブリッジを起動し直すと同じ port が別のシミュレータのものになる。実機で再現:
            // 8123 で機A の木を採った後、`bridge down --port 8123` → `bridge up --device 機B
            // --port 8123` としてから**同じセッション**で古い ref を撃つと、
            // `tap [4] done`(成功)で**機B の同名要素を叩いた**。
            // 生成時の `keyChangedDevice` では防げない —— この間セッションは1回も呼んでおらず
            // `forgetConnection` が走らないので、**ドライバはキャッシュ命中し生成が起きない**。
            // 「死んだブリッジなら失敗経路が拾う」も誤り: 新しいブリッジは正常に応答する。
            if let moved = await deviceIdentityChanged(key, args: args) {
                throw MCPError(moved)
            }
            // **MN-51.10**(profile 経路の同じ確認と理由は同じ): ブリッジが同じ機のまま入れ替わって
            // いないかも確かめる(Android のキーは connectedPorts が無いので即 .unchanged)
            switch await primaryBridgeCheck(key, args: args) {
            case .refuse(let message):
                throw MCPError(message)
            case .rebuildSilently:
                break
            case .unchanged:
                // **inapp-boost モードの fallback(XCUITest)ポートも本人確認する**(MN-51.2。profile 経路の
                // 同じ確認と理由は同じ)。fallback には ref が乗らないのでキャッシュだけ落とし、
                // 下の生成へ通す(セッション記憶は主の udid が変わっていないので保つ)
                if await hybridFallbackDrifted(key) {
                    drivers[key] = nil
                    hybridFallbackPorts[key] = nil
                } else {
                    // **キャッシュ命中でも記憶を更新する**(実アプリ監査で踏んだ)。
                    // 記録を「ドライバを生成したとき」に紐付けると、2度目に同じ機を明示した呼び出しは
                    // ここで返って記憶を動かさず、**A→B→A のあとの省略呼び出しが B へ行く**。
                    // 実害: iOS を明示 launch した直後の無指定 ft_snapshot が Android のツリーを返し、
                    // 注記は「最も新しいターゲット = <Android>」と名乗った(直前の明示は iOS なので嘘)。
                    // 失敗モードが沈黙(黙って別 OS の機を操作する)なので、生成の有無に依らせない
                    rememberResolvedTarget(platform: platform, args: args,
                                           iosPort: connectedPorts[key] ?? explicitPort, iosUDID: udids[key] ?? nil,
                                           androidSerial: args["serial"] as? String)
                    return cached
                }
            }
        }
        let created: AppDriver
        switch platform {
        case "ios":
            // **記憶の適用はここでは行わない**: dispatch 入口(call() の
            // foldInRememberedDevice)が省略呼び出しへ既に port/udid を差し込んでいるので、
            // ここに来る時点で args は明示指定と区別が付かない。ここでは解決後の値を
            // 「記録」するだけにする(rememberResolvedTarget) —— 適用と記録を二重に持たない
            let port = try await Self.resolveIOSPort(explicit: explicitPort)
            let resolved = try await ExploreDriverResolver.resolve(
                preferred: port, repoRoot: try? RepoRoot.find(),
                logger: { Self.logStderr($0) })
            // **このキーが前と別の機を指し始めていたら、キーの記憶を全部捨てる**。
            // ドライバを作り直す経路は forgetConnection(ここは既に forgetDeviceState 済み)
            // だけではない —— 版ズレ拒否(enforceVersion)も drivers[key] だけを nil にするので、
            // そちらを通った後は木・ref 世代・起動アプリが前の機のまま残る。
            // 判定は port ではなく **udid**(キーに入っている port は再利用され得るが、
            // udid は機そのもの)。**どちらかが不明なときは何もしない** —— 「分からない」を
            // 「変わった」と読むと、udid を採れない構成で毎回記憶が飛ぶ
            if let previousUDID = Self.keyChangedDevice(previous: udids[key] ?? nil,
                                                        now: resolved.udid) {
                forgetDeviceState(key)
                pendingWarnings[key, default: []].append(
                    Self.reusedPortWarning(port: port, previousUDID: previousUDID,
                                           nowUDID: resolved.udid ?? ""))
            }
            created = resolved.driver
            bridges[key] = resolved.bridge
            udids[key] = resolved.udid
            hybridFallbackPorts[key] = nil   // MCP の iOS は XCUITest だけ(inapp-boost モードの予備ポートは無い)
            // **宛先は port だけでなく udid まで書く**(実アプリ監査): ブリッジは
            // 落ちても monitor が別ポートで起動し直すので、**同じセッション中にポートが動く**
            // (実測: -03 が 8128→8126、-07 が 8136→8147)。port だけを覚えて使い回す読み手は、
            // その port が今どの機かを確かめる手段が無かった
            // **繋いだ先も記憶する宛先も実際のポート**(in-app から XCUITest へ振り替えたときはそちら)。
            // 照合(primaryBridgeDrift・deviceIdentityChanged)・表示・接続断の片付け(forgetConnection)が同じ相手を見る。
            // 呼び手のポートを覚えると、同じ端末のポートが名指しの記憶に2つ並び、宛先を書かない呼び出しが
            // 「2台を触った」で断られる(実地で踏んだ: port 8123 の後に udid → 8137)
            connections[key] = Self.connectionLabel(port: resolved.port, udid: resolved.udid)
            connectedPorts[key] = resolved.port
            // **稼働中のブリッジが古いままではないか**を1度だけ確かめる(踏んだ実例)。
            // profile 経由は BridgeProvisioner が版で再利用可否を決めるが、**この経路は
            // 生きているポートへ素で繋ぐだけ**なので、版を上げても旧ランナーが使われ続ける。
            // 実害: ブリッジ側の修正2件を入れて版も上げたのに、ft_snapshot は直る前の木を
            // 返し続け、`bridge down && bridge up` するまで「直っていない」に見えた。
            // Android は AndroidBridge が expectedBridgeVersionCode で入れ替えるのでこの穴が無い
            try await enforceVersion(driver: created, key: key, args: args)
            // 記録は版ガードの後(profile 経路と同じ理由)
            rememberResolvedTarget(platform: "ios", args: args,
                                   iosPort: resolved.port, iosUDID: resolved.udid, androidSerial: nil)
        case "android":
            // iOS と同じ理由で記憶の「適用」は入口(foldInRememberedDevice)側だけに置く
            let explicitSerial = args["serial"] as? String
            let serial = try Self.resolveAndroidSerial(explicit: explicitSerial)
            created = try await androidDriver(serial: serial, key: key, args: args)
            bridges[key] = "android"
            connections[key] = "serial \(serial)"
            connectedAndroidSerials[key] = serial
            // 一瞬の切断の後に同じ(物理)端末が戻った: 切断で捨てた起動の記録を返す(別の serial なら保留を捨てる)
            if launchedBundleIDs[key] == nil,
               let restored = Self.restoredLaunchRecord(saved: launchRecordAcrossAndroidDisconnect, serial: serial) {
                launchedBundleIDs[key] = restored
            }
            launchRecordAcrossAndroidDisconnect = nil
            rememberResolvedTarget(platform: "android", args: args,
                                   iosPort: nil, iosUDID: nil, androidSerial: serial)
        default:
            throw MCPError("platform must be ios or android: \(platform)")
        }
        drivers[key] = created
        return created
    }

    static let androidNewerBridgeAddendum = "In this MCP, pass allowVersionSkew: true to use the newer bridge as-is"
        + " (no install or uninstall; every response then carries a version-skew warning)."

    /// Android のドライバを作る。**デバイスのブリッジが新しくても使うのは `allowVersionSkew: true` のときだけ**
    /// (Android は降格インストールを拒否する)。使うときは iOS の押し通しと同じ版ズレの記録と警告を付ける
    /// (`versionSkew` / `skewOverrideWarning`)。許可の無い呼び出しは AndroidDriver が拒否の文を返す(逃げ道つき)
    func androidDriver(serial: String, key: String, args: [String: Any]) async throws -> AndroidDriver {
        let allowSkew = args["allowVersionSkew"] as? Bool == true
        if allowSkew { AndroidDriver.forgetCachedFailure(serial: serial) }
        let driver = try AndroidDriver(serial: serial, acceptsNewerInstalledBridge: allowSkew,
                                       newerBridgeRefusalAddendum: Self.androidNewerBridgeAddendum)
        // 動いていないブリッジは install の門(installBridgeIfNeeded)が版を見て断るので、照会は許可があるときと
        // 既に動いているとき(install の門を通らない = 黙って使われる)だけ。adb は協調プールの外で(mcp.md)
        guard allowSkew || AndroidDriver.hasActiveBridge(serial: serial) else {
            versionSkew[key] = nil
            return driver
        }
        let probe = UncheckedTransfer(driver)
        guard let skew = await BlockingWork.offPool(name: "ft-android-skew-probe", {
            probe.value.newerInstalledBridgeSkew()
        }) else {
            versionSkew[key] = nil
            return driver
        }
        let text = Self.androidNewerBridgeSkew(skew)
        guard allowSkew else {
            throw MCPVersionGuardRefusal(message: text + " " + Self.androidNewerBridgeAddendum)
        }
        versionSkew[key] = text
        pendingWarnings[key, default: []].append(Self.skewOverrideWarning(text))
        return driver
    }

    /// **版ズレは呼び出しごとに門を掛ける**(控えのドライバで引く前 = 断った呼び出しを「駆動した」と記録しない)。
    /// 許可があれば毎回警告する。許可が無ければ**今のブリッジで測り直し**、まだ食い違うときだけ断って控えを捨てる
    /// (直ったブリッジを古い記録で断らない)。Android は許可つきの呼び出しなら、新しい版を受け入れない設定で作られた
    /// 控えを捨てて作り直させる(期限内の失敗の再生も捨てる = 拒否文の逃げ道がその場で効く)
    func gateCachedVersionSkew(args: [String: Any]) async throws {
        let key = Self.sessionKey(args)
        let allow = args["allowVersionSkew"] as? Bool == true
        if allow, let android = drivers[key] as? AndroidDriver, !android.acceptsNewerInstalledBridge {
            drivers[key] = nil
            versionSkew[key] = nil
            AndroidDriver.forgetCachedFailure(serial: android.serial)
            return
        }
        guard let recorded = versionSkew[key], let cached = drivers[key] else { return }
        if allow {
            let warning = Self.skewOverrideWarning(recorded)
            if !(pendingWarnings[key]?.contains(warning) ?? false) {
                pendingWarnings[key, default: []].append(warning)
            }
            return
        }
        let now: String?
        if let android = cached as? AndroidDriver {
            let probe = UncheckedTransfer(android)
            now = await BlockingWork.offPool(name: "ft-android-skew-probe", { probe.value.newerInstalledBridgeSkew() })
                .map { Self.androidNewerBridgeSkew($0) + " " + Self.androidNewerBridgeAddendum }
        } else {
            now = await Self.bridgeVersionSkew(driver: cached)
        }
        versionSkew[key] = nil
        guard let now else { return }
        drivers[key] = nil
        throw MCPVersionGuardRefusal(message: now)
    }

    /// 入っている Android ブリッジが新しいまま使うときの版ズレの文(拒否の文ではない = 警告の本文)
    static func androidNewerBridgeSkew(_ skew: BridgeVersionSkew) -> String {
        "bridge protocol mismatch: the Android bridge on the device is NEWER than this build"
            + " (v\(skew.running) > v\(skew.expected)). It answers with the behaviour and the notes of its own"
            + " version, so selectors written from them may be wrong; update fleetest-mcp to a release that matches,"
            + " or remove the bridge (`adb uninstall \(AndroidDriver.bridgePackage)`) to have this build's version installed."
    }

    /// 版ズレを既定で拒否する(G)。押し通しは `allowVersionSkew: true` で、その場合は
    /// **毎回の応答に警告が付き続ける**(1度言って黙らない)。
    /// 拒否したときは覚えたドライバを捨てる —— 起動し直した後に古い判定が残らないように
    func enforceVersion(driver: AppDriver, key: String, args: [String: Any]) async throws {
        guard let skew = await Self.bridgeVersionSkew(driver: driver) else {
            versionSkew[key] = nil
            return
        }
        versionSkew[key] = skew
        guard args["allowVersionSkew"] as? Bool == true else {
            drivers[key] = nil
            throw MCPVersionGuardRefusal(message: skew)
        }
        pendingWarnings[key, default: []].append(Self.skewOverrideWarning(skew))
    }

    /// 繋いだブリッジの版が食い違っているときの文。一致・判定不能なら nil。
    ///
    /// **既定は拒否**(警告だけで通さない):
    /// MCP の出力はシナリオへ書く文字列を供給するためにあるので、**古いブリッジの出す古い注記から
    /// 誤ったセレクタが書き込まれる**ほうが「セッションが止まる」より高くつく。
    /// アドホック探索なら警告で足りるが、生成が目的だとそうではない。
    ///
    /// **どちらが新しいかを明示する**(G-4): 対処が変わる ——
    /// ブリッジが古い = 起動し直す / ホストが古い = こちらをビルドし直す(or pull)。
    /// **判定できないときは黙る**(旧ブリッジは版を返さない = nil。それを「古い」と断じると常時警告)。
    ///
    /// **判定(running/expected の比較)は `BridgeTargetResolution.versionSkew` を通す**
    /// (CLI の手動駆動サブコマンドと共有)。ここに残すのは MCP 向けの文言だけ
    /// (`fleetest-mcp` を名指しする対処。CLI 側は別の文を組む)
    static func bridgeVersionSkew(driver: AppDriver) async -> String? {
        guard let skew = await BridgeTargetResolution.versionSkew(driver: driver) else { return nil }
        let side = skew.bridgeIsNewer
            ? "the bridge is NEWER than this build (v\(skew.running) > v\(skew.expected)) —"
                + " your fleetest-mcp binary is stale, so rebuild it"
                + " (swift build --product fleetest-mcp) or pull"
            : "the bridge is OLDER than this build (v\(skew.running) < v\(skew.expected)) —"
                + " restart only this device's bridge with `fleetest bridge up --device <its udid>` (add --physical for a"
                + " physical device): it stops the older-build bridge itself, whereas `bridge down` refuses while this MCP"
                + " session holds the device. Do not use `bridge down --all` (it also stops the bridges other sessions and the"
                + " monitor are using); a bridge started from another clone is not stopped by this repository's CLI"
        return "bridge protocol mismatch: \(side)."
            + " Refusing to operate: a stale bridge answers with the behaviour and the notes of"
            + " its own version, and selectors written from those notes are silently wrong."
            + " Pass allowVersionSkew: true to proceed anyway."
    }

    /// 版ズレのまま押し通されたときに毎回付ける警告(G-3)。**1度言って黙らない** ——
    /// 押し通した事実は、その後の全応答の信頼度に掛かり続ける
    static func skewOverrideWarning(_ skew: String) -> String {
        "⚠️ allowVersionSkew: proceeding despite a bridge/host mismatch. \(skew)"
    }


    /// ft_status の `@ …` に出す宛先の表記(純粋関数・テスト用)。**udid が分からないブリッジ
    /// (申告しない旧版)では port だけ** —— 「不明」と書くより短く、嘘も混ざらない。
    /// **表示専用**: `connectionLostHint` の経路判別は `connectedPorts`/
    /// `connectedAndroidSerials` の記録を見るので、ここの書式を変えても判定には影響しない
    static func connectionLabel(port: UInt16, udid: String?) -> String {
        guard let udid, !udid.isEmpty else { return "port \(port)" }
        return "port \(port) (udid \(udid))"
    }

    /// **iOS の明示ターゲット述語**。args に有効な udid(非空文字列)または port(Int)があるか。
    /// **キーの存在ではなく値を見る**: `args["udid"] != nil` は `udid: ""` を
    /// 「指定あり」と誤読する非対称を生む(Android の serial は元から isEmpty で見ている)。
    /// **driver() のキャッシュキー判定・記憶の適用可否(foldInRememberedDevice)・
    /// 記憶の記録可否(iosMemoryAfterResolve 呼び出し側)はすべてこの1つを通す**
    static func argsGaveIOSTarget(_ args: [String: Any]) -> Bool {
        let udid = (args["udid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return udid != nil || args["port"] is Int
    }

    /// Android 版の同じ述語(serial)
    static func argsGaveAndroidTarget(_ args: [String: Any]) -> Bool {
        (args["serial"] as? String).flatMap { $0.isEmpty ? nil : $0 } != nil
    }

    /// **profile と明示の宛先(udid/port/serial)は併用させない**。profile の枝は宛先を
    /// ft_run_scenario と同じ規則でプロファイルから決め、明示の宛先を1度も見ないので、黙って通すと
    /// **名指ししていないデバイス**(プロファイルが選ぶデバイス)を操作する(実測: udid で -08 を名指ししたのに
    /// プロファイルの -01 でアプリを起動した)。platform は併用してよい(プロファイル内の OS を選ぶ)
    /// —— ここがシナリオ系の `profileConflict` と違う点。呼ぶのは `call()` の入口(udid を畳む前)。
    /// 記憶の注入は profile 指定時に働かない
    /// (`foldInRememberedDevice`)ので、ここに掛かるのは利用者が明示した組み合わせだけ
    static func profileWithExplicitTargetRefusal(_ args: [String: Any]) -> String? {
        guard let profile = args["profile"] as? String,
              argsGaveIOSTarget(args) || argsGaveAndroidTarget(args) else { return nil }
        return "profile \"\(profile)\" picks its own device (the same one ft_run_scenario would use), so it"
            + " cannot be combined with udid/port/serial — the call would drive the profile's device, not"
            + " the one you named. Drop profile to drive the named device (the bridge then follows the"
            + " bridge running on it), or drop udid/port/serial to use the profile's device"
    }

    /// **platform と宛先(udid/port/serial)の食い違いを断る**。判定は
    /// `FTCore.DeviceTargetConsistency`(CLI の `DriverOptions.rejectDeviceTargetMismatch` と共有)。呼ぶのは
    /// `call()` の入口・`profileWithExplicitTargetRefusal` の隣(udid を畳む前 —— 畳み込みは
    /// ブリッジ走査を撃つので、そもそも矛盾した呼び出しでは撃たせない)。**文言だけここで組む**
    static func deviceTargetMismatchRefusal(_ args: [String: Any]) -> String? {
        guard let mismatch = DeviceTargetConsistency.mismatch(
            platform: args["platform"] as? String,
            gaveIOSTarget: argsGaveIOSTarget(args), gaveAndroidTarget: argsGaveAndroidTarget(args))
        else { return nil }
        switch mismatch {
        case .bothPlatformsTargeted:
            return "both an iOS target (udid/port) and an Android target (serial) were given, with no"
                + " platform to say which one to use — refusing to guess which device to operate."
                + " Pass only one platform's target, or add platform to say which."
        case .iosPlatformWithAndroidTarget:
            return "platform is \"ios\" but serial (an Android target) was also given — refusing to guess"
                + " which device to operate. Drop serial, or drop platform (or set it to \"android\")."
        case .androidPlatformWithIOSTarget:
            return "platform is \"android\" but udid/port (an iOS target) was also given — refusing to"
                + " guess which device to operate. Drop udid/port, or drop platform (or set it to \"ios\")."
        }
    }

    /// **fold が注入した呼び出しかどうかの目印**。foldInRememberedDevice が
    /// 省略呼び出しへ port/serial を差し込むとき一緒に立てる —— スキーマ検証後にしか付かず、
    /// sessionKey(platform/port/serial/profile しか見ない)にも影響せず、ブリッジへ渡る辞書にも
    /// 漏れない(ドライバの各メソッドは args から個別の値を取り出すだけで、辞書ごとは渡さない)。
    /// **記憶の記録可否だけに使う** —— recordsIOSMemory/recordsAndroidMemory 参照
    static let deviceFromMemoryKey = "_deviceFromMemory"

    static func injectedFromMemory(_ args: [String: Any]) -> Bool {
        args[deviceFromMemoryKey] as? Bool == true
    }

    /// **記憶した状態に依存する呼び出しか**(純粋関数)。この形だけが「機が変わると黙って
    /// 別物へ届く」——  ref は世代から引き、`bundleId` 省略の `ft_open_url` は記憶した起動アプリへ配る。
    /// 座標タップや素の ft_snapshot は記憶を使わないので、確認の往復を払う価値が無い。
    /// **`ft_batch` は先頭ステップだけ ref を受ける**ので steps も見る
    /// **ref を受ける引数名は `ref` だけではない**(レビュー指摘): `ft_drag` は
    /// `fromRef` で受け、`verifiedElement` 経由で同じ世代から引く。名前を1つ見落とすと
    /// **その1ツールだけ穴が開いたまま**になるので、`refBearingKeys` を唯一の定義元にして
    /// `MCPServerToolDefinitionsTests` がスキーマ側と突き合わせる
    static let refBearingKeys = ["ref", "fromRef", "scrollFrame"]

    /// 整数を受けるが **ref ではない**引数。`refBearingKeys` と合わせて
    /// **整数を受ける引数を全部説明しきる**(`MCPServerToolDefinitionsTests` がスキーマと
    /// 等号照合する)—— 新しい整数引数を足したらどちらかへ入れることになるので、
    /// 「ref を受ける引数が1つ増えたのにガードが知らない」が起きない。
    /// **綴りの類似で判定しない**(3度踏んだ): `ref` → `fromRef` →
    /// `scrollFrame` と、名前からは ref だと分からない引数が毎回出てきた
    static let nonRefIntegerKeys = ["lastN", "limit", "lines", "maxElements", "maxSwipes", "maxWidth",
                                    "minRuns", "pid", "port", "sinceSeconds", "waitLockSeconds"]

    static func usesRememberedDeviceState(_ args: [String: Any]) -> Bool {
        if Self.refBearingKeys.contains(where: { args[$0] != nil }) { return true }
        if let steps = args["steps"] as? String, stepsCarryARef(steps) { return true }
        if args["url"] != nil, args["bundleId"] == nil { return true }
        return false
    }

    /// `ft_batch` の先頭ステップが ref を持つか。**`contains("ref:")` では足りない**
    /// (レビュー指摘): パーサは `tap ref : 12` という綴りも受理する。
    /// **空白を許す形で見る**。引用符の中の `ref:` を拾う誤検知はあり得るが、
    /// **外した場合は黙って別の機を操作する**のに対し、余分に拾っても `/status` 1往復
    /// (実測6〜9ms)なので、**安全側へ倒す**
    static func stepsCarryARef(_ steps: String) -> Bool {
        var sawRef = false
        var index = steps.startIndex
        while let found = steps.range(of: "ref", range: index..<steps.endIndex) {
            var cursor = found.upperBound
            while cursor < steps.endIndex, steps[cursor] == " " { cursor = steps.index(after: cursor) }
            if cursor < steps.endIndex, steps[cursor] == ":" { sawRef = true; break }
            index = found.upperBound
        }
        return sawRef
    }

    /// キャッシュ命中のドライバが**別の機を指し始めていたら**、そのキーの記憶を捨てて理由を返す
    /// (非 nil = 呼び出しを断る文)。
    ///
    /// **確認は `usesRememberedDeviceState` の呼び出しだけ**に絞る: 同一性の確認は
    /// `/status` 1往復(実測 6〜9ms)で、ref 系はどのみち木を撮りにブリッジへ行くので
    /// **限界費用がほぼ無い**。全呼び出しに掛けると、XCUITest の quiescence(実測 33.7 秒)中に
    /// 記憶を使わない呼び出しまで詰まらせる。
    /// **udid を採れないとき(実機・旧ブリッジ)は何もしない** —— 「分からない」を「変わった」と
    /// 読むと毎回記憶が飛ぶ(`keyChangedDevice` と同じ規律)。
    /// Android は sessionKey に serial(= 機そのもの)が入っているので、この穴が構造的に無い
    /// **問い合わせは掴んでいるドライバ越しにやらない**(実装2回目で踏んだ):
    /// 実運用のドライバは `SessionRecoveryDriver` に包まれており、**起動し直した直後のブリッジは
    /// まだセッションを持たない**ので `status()` が 409 で落ちる。`try?` で握ると
    /// **機が変わったときにちょうどガードが黙る** —— 陰性が「常に false を返す検出器」と
    /// 区別できない形そのものだった(実機の陽性対照で発覚)。ポートへ直に `/status` を撃つ
    /// **platform は引数で取らない**(掃討で決めた): 必要な2つ(`udids` と
    /// `connectedPorts`)は **iOS でしか埋まらない**ので、前提のほうが platform 判定より強い。
    /// profile 経路は解決前に platform 文字列を持たないため、引数で取ると呼び手ごとに
    /// 合成することになり、そこで取り違える余地が生まれる
    func deviceIdentityChanged(_ key: String, args: [String: Any]) async -> String? {
        guard Self.usesRememberedDeviceState(args),
              let recorded = udids[key] ?? nil, let port = connectedPorts[key] else { return nil }
        // **宛先ホストは BridgeEndpoint.load で解決する**(欠陥④): 127.0.0.1 決め打ちだと
        // 実機の lan トランスポート(ランナーを 0.0.0.0 に bind してデバイスの LAN IP へ直接 HTTP)
        // ではデバイスに届かず、同じポート番号で loopback に応答した**別の機**の udid を読んでしまう
        // (BridgeDiscovery.isBound/scan・ExploreDriverResolver と同じ解決点に揃える)。
        // **udid を申告するのはシミュレータ上のブリッジだけ**(in-app・XCUITest とも SIMULATOR_UDID)。
        // 実機のランナーは申告しない(nil)ので、実機のポートを実機のランナー自身が答えている間は
        // 何もしない。**実機のポートをシミュレータのブリッジが奪った形は now = シミュレータの udid に
        // なるので捕まる**(負荷テストで DSL 側に起きた F8b の形。DSL は
        // FTCore.BridgeIdentityCheck が同じ udid 比較を持つ)。黙るのは**実機同士の入れ替わり**
        // (両方 nil)だけで、奪う側の採番・kill は PortHolder の ownerUDID / 生きた iproxy の除外で
        // 源から止めてある。`.fleetest/bridge-<port>.device` で補う余地はあるが広げない
        // (広げると誤拒否の側にリスクが移る)
        let endpoint = (try? RepoRoot.find()).map { BridgeEndpoint.load(port: port, repoRoot: $0) }
            ?? BridgeEndpoint(port: port)
        guard let now = try? await BridgeClient(endpoint: endpoint, timeoutSeconds: 5).status().udid,
              let moved = Self.keyChangedDevice(previous: recorded, now: now) else { return nil }
        forgetDeviceState(key)
        return Self.movedDeviceRefusal(port: port, previousUDID: moved, nowUDID: now)
    }

    /// **主ポートのブリッジが変わっていないか(MN-51.10)**: `deviceIdentityChanged` は
    /// udid しか見ず、しかも `usesRememberedDeviceState` で ref を使う呼び出しにしか効かない —— 同じ
    /// udid のまま run のたびのブリッジの起動し直しでモードが xcuitest ⇄ inapp-boost に入れ替わった形を
    /// 見逃す。**実測**: xcuitest でキャッシュ済みのドライバの port が in-app ブリッジへ化け、ref を
    /// 使わない `ft_terminate`(`usesRememberedDeviceState` のゲートを通らない)が
    /// 「in-app では未サポート」の 501 を返した(in-app には /terminate が無い)。逆向き
    /// (キャッシュは in-app 期待だが実は xcuitest)なら tap/snapshot は成功で返るが、**別の ref 体系・
    /// 別の挙動**を渡している —— 気付ける形の失敗がむしろ良性
    /// (`usesRememberedDeviceState` を流用しない理由も同じ: ref を使わない呼び出しでこそ実際に踏んだ)。
    /// **iOS のキャッシュ命中では毎回確かめる**(`hybridFallbackDrifted` と同じコストの考え方 ——
    /// 1回の loopback probe)。判定は同じ `FTBridgeClient.HybridFallbackIdentity` の1箇所
    func primaryBridgeDrift(_ key: String) async -> BridgeIdentityCheck.HybridFallbackDrift {
        guard let port = connectedPorts[key], let expectedUDID = udids[key] ?? nil,
              let bridge = bridges[key] else { return .none }
        let expectedBridge = bridge == "xcuitest" ? "xcuitest" : "inapp"
        return await HybridFallbackIdentity.drifted(
            port: port, expectedUDID: expectedUDID, expectedBridge: expectedBridge,
            repoRoot: try? RepoRoot.find())
    }

    /// `primaryBridgeDrift` の結果を、この call をどう扱うかへ落とす。**旧ブリッジの ref はどの道
    /// 無効**なので、`.none` 以外は必ず `forgetDeviceState`(fallback 専用の `hybridFallbackDrifted`
    /// と違い、こちらは primary = ref の起点そのもの)。
    /// - `.sameDeviceBridgeChanged`: **この呼び出し自身が記憶に依っているときだけ拒否**
    ///   (`usesRememberedDeviceState`)—— 依っていなければ、捨てた上でこの call 自身を新しい
    ///   ドライバで再解決させれば足りるので、利用者に「撮り直せ」と言う理由が無い
    ///   (`ft_terminate` はまさにこの形 = 黙って直った状態で続行してよい)
    /// - `.differentDevice`: **ref の有無を問わず必ず拒否**する。ここで黙って作り直すと、
    ///   ref を使わない呼び出し(`ft_tap x/y`・`ft_type` 等)が警告なしで別のデバイスへ効き続け、
    ///   以後のセッションがそのデバイスに固定される
    enum PrimaryBridgeCheck: Equatable {
        case unchanged, rebuildSilently, refuse(String)
    }

    /// `primaryBridgeDrift`(I/O)が拾った事実から、この call をどう扱うかを決める
    /// **走査から切り離した純粋関数**(`keyChangedDevice`/`hybridFallbackDrift` と同じ理由・
    /// テスト用): 実ブリッジ無しで「記憶に依る呼び出しだけ拒否する」判定そのものを固定できる
    static func primaryBridgeOutcome(
        drift: BridgeIdentityCheck.HybridFallbackDrift, usesRememberedDeviceState: Bool,
        port: UInt16?, expectedBridge: String?, expectedUDID: String?, callerNamedUDID: Bool
    ) -> PrimaryBridgeCheck {
        switch drift {
        case .none:
            return .unchanged
        case .differentDevice:
            // args の udid は呼び手の明示だけ(記憶の補完は port しか書かない)= 今そのポートに居るデバイスを
            // 名指しした同意なので作り直してよい。明示が無ければ断り続ける(primaryBridgeCheck が記憶を残す)
            guard !callerNamedUDID else { return .rebuildSilently }
            return .refuse(differentDeviceRefusal(port: port, expectedUDID: expectedUDID))
        case .sameDeviceBridgeChanged:
            guard usesRememberedDeviceState else { return .rebuildSilently }
            return .refuse(bridgeChangedRefusal(port: port, expectedBridge: expectedBridge))
        }
    }

    /// 呼び手がこの呼び出しで台そのものを名指したか(= ポートが別の台へ移っていても、名指した台へ解き直してよい)。
    /// `udid` の明示に加え、**profile も台を名指す**(プロファイルの台へ解き直すので、黙って別の台に固定しない)。
    /// profile は udid と併用できない(`profileWithExplicitTargetRefusal`)ので、これを外すと profile の呼び出しは
    /// 「udid を明示するまで断る」から抜けられない(Duo の SpringBoard の落ちの後にポートが再利用された実例)
    static func callerNamesDevice(_ args: [String: Any]) -> Bool {
        if let udid = args["udid"] as? String, !udid.isEmpty { return true }
        if let profile = args["profile"] as? String, !profile.isEmpty { return true }
        return false
    }

    /// `primaryBridgeOutcome` の I/O 込みの入口。**`.unchanged` 以外は `forgetDeviceState`**
    /// (旧ブリッジの ref はどの道無効。`.rebuildSilently` でも捨てる — 呼び出し元はこの call を
    /// 下の生成で再解決させるだけで、拒否文を返す理由は無い)。
    /// **例外は別のデバイスを断ったとき**: 記憶(udid・キャッシュ)を捨てると次の同じ呼び出しが生成経路へ落ち、
    /// `keyChangedDevice` の previous が nil になって**黙って別のデバイスに固定される**。残して毎回断る
    func primaryBridgeCheck(_ key: String, args: [String: Any]) async -> PrimaryBridgeCheck {
        let drift = await primaryBridgeDrift(key)
        let callerNamedUDID = Self.callerNamesDevice(args)
        let outcome = Self.primaryBridgeOutcome(
            drift: drift, usesRememberedDeviceState: Self.usesRememberedDeviceState(args),
            port: connectedPorts[key], expectedBridge: bridges[key], expectedUDID: udids[key] ?? nil,
            callerNamedUDID: callerNamedUDID)
        if case .unchanged = outcome { return outcome }
        if drift == .differentDevice, case .refuse = outcome { return outcome }
        forgetDeviceState(key)
        return outcome
    }

    /// 同じ機のまま(udid は同じ)ブリッジのモードだけが変わっていたときに呼び出しを断る文。
    /// **`movedDeviceRefusal` と文面を分ける** —— 「別の機だ」と早合点させない(繋ぎ直す先の
    /// 機は無い。同じ機のブリッジが起動し直しでモードを変えただけ)
    static func bridgeChangedRefusal(port: UInt16?, expectedBridge: String?) -> String {
        let where_ = port.map { "port \($0)" } ?? "this bridge"
        let bridgeLabel = expectedBridge.map { "the \($0) bridge" } ?? "its previous bridge"
        return "\(where_) no longer answers as \(bridgeLabel) this session cached it for"
            + " (the same device appears to have rebuilt its bridge as the other kind)"
            + " — refusing this call because it relies on state remembered for the previous bridge"
            + " (a ref, or the launched app that ft_open_url defaults to; refs do not carry across"
            + " bridges). That state has been dropped. Take a fresh ft_snapshot and use the new refs."
    }

    /// primary ポートが別の udid へ移っていたときに呼び出しを断る文。**`movedDeviceRefusal` と役割は
    /// 同じ**(捨てたものを名指しする)が、ここは `primaryBridgeOutcome` が持つ材料(実測の
    /// 「今の」udid は無く、期待していた udid だけ)に合わせて文面を作る。**ref の有無を問わず
    /// 常にこの文を返す**(`sameDeviceBridgeChanged` の `bridgeChangedRefusal` と違い、
    /// `usesRememberedDeviceState` の分岐は無い)
    static func differentDeviceRefusal(port: UInt16?, expectedUDID: String?) -> String {
        let where_ = port.map { "port \($0)" } ?? "this bridge"
        let expectedLabel = expectedUDID ?? "the device this session cached it for"
        return "\(where_) now belongs to a different device than \(expectedLabel)"
            + " — nothing was sent. This session keeps refusing calls on this port until you pass"
            + " udid explicitly (the device you mean to drive); call ft_list_devices to see which"
            + " device is on which port now."
    }

    /// **inapp-boost モードのキャッシュ命中の fallback(XCUITest)ポートが別の機/別ブリッジへ移っていないか**
    /// (MN-51.2): `deviceIdentityChanged` は主(in-app・`connectedPorts`/`udids`)しか
    /// 見ないので、`HybridFallbackDriver` の fallback が握る `hybridFallbackPorts[key]` は
    /// ノーチェックのまま残っていた。ブリッジは run のたびに起動し直され**同じポート番号が
    /// 別デバイス(あるいは同じデバイスの in-app ブリッジ)に化ける**ため、home/appSwitcher/drag/
    /// 座標 press/gesture/pinch(すべて fallback 経由。primary の in-app は 501 で必ず回る)が
    /// 黙って別の機を操作しうる。
    ///
    /// **`usesRememberedDeviceState` のゲートは流用しない**: あちらは ref が指す要素が
    /// 別物になる形だけを守る規律で、fallback は ref を一切受けない(HybridFallbackDriver の
    /// doc「ref を使う操作は回さない」)ので ref の有無では判定できない。inapp-boost モードのキャッシュ命中
    /// でだけ効くので、コストは Android・xcuitest 単独・inapp 単独の呼び出しには掛からない。
    ///
    /// **I/O・判定とも `FTBridgeClient.HybridFallbackIdentity`(`FTCore.BridgeIdentityCheck`)の
    /// 1箇所**(ライブ操作(api live serve)と共有 —— 二つ目の実装を書かない。「不明(/status を
    /// 読めない・タイムアウト)は変わったに倒さない」もそちらが守る)。ここに残るのは MCP の
    /// キャッシュ(`hybridFallbackPorts`/`udids`)から材料を集めるだけ。
    /// **食い違っていてもここでは断らない** —— 呼び出し元がキャッシュを落として次の解決に委ねる
    /// (fallback には捨てるべき ref/起動アプリの記憶が無いので、断って利用者へ「撮り直せ」と
    /// 言う理由が無い。udid は分かっているので次の解決が静かに `.inappOnly` へ縮退することもある)
    func hybridFallbackDrifted(_ key: String) async -> Bool {
        guard let port = hybridFallbackPorts[key], let expectedUDID = udids[key] ?? nil else {
            return false
        }
        return await HybridFallbackIdentity.drifted(
            port: port, expectedUDID: expectedUDID, repoRoot: try? RepoRoot.find()) != .none
    }

    /// ポートが別の機へ移っていたときに呼び出しを断る文。**捨てたものを名指しする** ——
    /// 「別の機だ」だけだと、読み手は手元の ref をそのまま撃ち直す
    static func movedDeviceRefusal(port: UInt16?, previousUDID: String, nowUDID: String) -> String {
        let where_ = port.map { "port \($0)" } ?? "this bridge"
        return "\(where_) now belongs to a different simulator (was \(previousUDID), now \(nowUDID))"
            + " — refusing this call because it relies on state remembered for the previous device"
            + " (a ref, or the launched app that ft_open_url defaults to). That state has been"
            + " dropped. Take a fresh ft_snapshot and use the new refs."
    }

    /// **同じ sessionKey が別の機を指し始めたか**(非 nil = 前の udid。走査から切り離した純粋関数)。
    /// 判定は port ではなく **udid** —— キーに入っている port は再利用され得るが、udid は機そのもの。
    /// **どちらかが不明なら nil**(何もしない): 「分からない」を「変わった」と読むと、
    /// udid を採れない構成(xcuitest 以外・実機)で毎回記憶が飛ぶ
    static func keyChangedDevice(previous: String?, now: String?) -> String? {
        guard let previous, let now, previous != now else { return nil }
        return previous
    }

    /// ポートが別のシミュレータへ移っていたときの警告。**捨てたものを名指しする** ——
    /// 「何かが消えた」だけだと、読み手は手元の ref をそのまま撃ち続ける
    static func reusedPortWarning(port: UInt16, previousUDID: String, nowUDID: String) -> String {
        "⚠️ port \(port) now belongs to a different simulator (was \(previousUDID), now \(nowUDID))"
            + " — refs, the remembered launched app and this session's notes for it were dropped."
            + " Take a fresh ft_snapshot before using any ref."
    }

    /// **セッション記憶(iOS)を使うかどうかの純粋関数**。走査から切り離してある(reconcilePort と
    /// 同じ理由: 実ブリッジ無しでテストできないと、条件を壊しても素通しする)。
    /// **適用は dispatch 入口(foldInRememberedDevice)だけが呼ぶ** —— driver() 側では
    /// 入口が既に args へ port/udid を埋めているので、ここを二度通す必要は無い
    static func iosExplicitWithMemory(
        argsGaveTarget: Bool, remembered: (port: UInt16, udid: String?)?
    ) -> (port: UInt16, udid: String?)? {
        argsGaveTarget ? nil : remembered
    }

    /// 解決成功後にセッション記憶(iOS)を更新すべき値。**この呼び出しの args に udid/port の
    /// どちらかがあったときだけ**上書きする — 自動解決の結果を記憶に混ぜると、次に無指定で
    /// 呼んだときに「利用者が選んだのではない機」を黙って踏襲することになる
    static func iosMemoryAfterResolve(
        argsHadExplicitTarget: Bool, resolvedPort: UInt16, resolvedUDID: String?
    ) -> (port: UInt16, udid: String?)? {
        argsHadExplicitTarget ? (resolvedPort, resolvedUDID) : nil
    }

    /// driver() が iOS 記憶を更新してよいかの判定。fold が注入した呼び出し
    /// (deviceFromMemoryKey 付き)は port/udid を持っていても**明示扱いしない** —— さもないと
    /// この直後の iosMemoryAfterResolve が「利用者が選んだ」として記憶を上書きし、ポート再利用で
    /// 別デバイスに化けたときに記憶が黙って乗り換わる。
    /// **`profile:` も名指しとして数える**: profile で実機を指すセッションは udid/port を
    /// 一度も渡さないので、ここが profile を見ないと2台目を触っても曖昧さガードに数えられず
    /// 省略呼び出しが黙って別の機(仮想デバイス側)へ流れる(実機監査で実際に踏んだ)
    static func recordsIOSMemory(_ args: [String: Any]) -> Bool {
        (argsGaveIOSTarget(args) || args["profile"] is String) && !injectedFromMemory(args)
    }

    /// iOS と同じ規律の Android 版。serial は空文字列も「無指定」として扱う(resolveAndroidSerial
    /// と揃える)。**適用は foldInRememberedDevice だけが呼ぶ**(iOS 側と同じ理由)。
    /// **iosExplicitWithMemory と同形**: 使わない tuple 要素(explicit)は持たない —
    /// 明示判定は argsGaveAndroidTarget に一本化してある
    static func androidExplicitWithMemory(argsGaveTarget: Bool, remembered: String?) -> String? {
        guard !argsGaveTarget, let remembered, !remembered.isEmpty else { return nil }
        return remembered
    }

    /// iosMemoryAfterResolve の Android 版。**記録するのは解決済みの serial だけ** ——
    /// 「記録してよいか」は Bool で受ける(serial 型の値で可否を表すと、その値自体が
    /// serial として使われる誤用を招く)
    static func androidMemoryAfterResolve(
        argsHadExplicitTarget: Bool, resolvedSerial: String
    ) -> String? {
        argsHadExplicitTarget ? resolvedSerial : nil
    }

    /// recordsIOSMemory の Android 版。fold が注入した serial は記憶の記録に使わない。
    /// **`profile:` も名指しとして数える**(iOS 側と同じ理由・対称に直す)。
    /// serial は空文字列を「無指定」として扱う(resolveAndroidSerial と揃える)
    static func recordsAndroidMemory(_ args: [String: Any], explicitSerial: String?) -> Bool {
        guard !injectedFromMemory(args) else { return false }
        if let explicitSerial, !explicitSerial.isEmpty { return true }
        return args["profile"] is String
    }

    /// 解決済みの宛先をセッション記憶へ記録する。**driver() の4箇所(profile の新規生成・
    /// キャッシュ命中、direct の新規生成・キャッシュ命中)が共に呼ぶ唯一の記録点** —— どれか1つ
    /// でも欠けると、その経路で触った機が記憶にも曖昧さの候補にも載らず、省略呼び出しが黙って
    /// 別の機(別 OS のことすらある)へ行く
    /// (実測: profile の新規生成だけが呼んでいなかったため、実機を profile で触った後に
    /// 仮想デバイスを port で触ると、宛先を省いた呼び出しが拒否されず仮想デバイスへ流れた。
    /// profile のキャッシュ命中も同じ理由で漏れていた —— profile:A → port:B →
    /// profile:A の順に触ると、2回目の profile:A がキャッシュ命中で記憶を更新せず、
    /// セッションの記憶が B のまま止まった)。
    /// 何を記録するかの判定は recordsIOSMemory / recordsAndroidMemory が持つ(明示指定でなければ
    /// 記録しない・fold が注入した宛先も記録しない)ので、ここは配線だけ
    func rememberResolvedTarget(
        platform: String, args: [String: Any],
        iosPort: UInt16?, iosUDID: String?, androidSerial: String?
    ) {
        switch platform {
        case "ios":
            guard let iosPort, let remembered = Self.iosMemoryAfterResolve(
                argsHadExplicitTarget: Self.recordsIOSMemory(args),
                resolvedPort: iosPort, resolvedUDID: iosUDID) else { return }
            lastExplicitIOSTarget = remembered
            lastExplicitPlatform = "ios"
            Self.dropSupersededPorts(seen: &seenExplicitIOSPorts, udids: &seenExplicitIOSUDIDs,
                                     port: remembered.port, udid: remembered.udid)
            everNamedIOSTarget = true
        case "android":
            guard let androidSerial, let remembered = Self.androidMemoryAfterResolve(
                argsHadExplicitTarget: Self.recordsAndroidMemory(
                    args, explicitSerial: args["serial"] as? String),
                resolvedSerial: androidSerial) else { return }
            lastExplicitAndroidSerial = remembered
            lastExplicitPlatform = "android"
            seenExplicitAndroidSerials.insert(remembered)
            everNamedAndroidTarget = true
        default: break
        }
    }

    /// 同じ udid が新しい port で明示されたら、その udid の古い port を延べ集合から外して新しい port を足す(純粋関数)。
    /// udid が分からない(nil/空)port は同一性を言えないので外さない
    static func dropSupersededPorts(seen: inout Set<UInt16>, udids: inout [UInt16: String], port: UInt16, udid: String?) {
        if let udid, !udid.isEmpty {
            for (oldPort, oldUDID) in udids where oldUDID == udid && oldPort != port {
                seen.remove(oldPort)
                udids[oldPort] = nil
            }
            udids[port] = udid
        }
        seen.insert(port)
    }

    /// profile 無しの iOS 宛先。**明示 port は探索しない**(利用者が宛先を決めている)。
    /// 既定ポートが死んでいるのは珍しくない —— `bridge up` は稼働中ブリッジの再利用や
    /// pid ファイルの残りで別ポートを選ぶ(Fleetest.swift の警告)。
    /// **判定は `FTBridgeClient.BridgeTargetResolution.iosPort` を通す**(CLI の手動駆動
    /// サブコマンドと共有)。ここは `BridgeTargetError` を `MCPError` へ包むだけ
    /// (文言は BridgeDiscovery のまま1文字も変えない)
    static func resolveIOSPort(explicit: UInt16?) async throws -> UInt16 {
        do {
            return try await BridgeTargetResolution.iosPort(
                explicit: explicit, names: .mcp, log: Self.logStderr)
        } catch let error as BridgeTargetError {
            throw MCPError(error.message(.mcp))
        }
    }

    /// profile 無しの Android 宛先。**serial 無しで adb を撃たない**(複数台なら
    /// "more than one device/emulator" が生で出る)。
    /// **判定は `FTAndroid.AndroidTargetResolution.serial` を通す**(CLI と共有)。
    /// ここは `AndroidTargetError` を `MCPError` へ包むだけ
    static func resolveAndroidSerial(explicit: String?) throws -> String {
        do {
            return try AndroidTargetResolution.serial(explicit: explicit, names: .mcp, log: Self.logStderr)
        } catch let error as AndroidTargetError {
            throw MCPError(error.message(.mcp))
        }
    }

    /// profile 経由の iOS ドライバ。**実行プロファイルのモードに追従する**(XCUITest 固定に
    /// しない —— in-app が実装できない home/drag/座標 press は HybridFallbackDriver が埋める)。
    /// モードを揃える理由は**探索と実行で見えるものを一致させる**こと: snapshot の内容も
    /// ジェスチャの成否もモードで変わるので、揃えないと「MCP では動いたのにシナリオでは falls」
    /// (およびその逆)が起きる。
    ///
    /// 合成は実行側(ScenarioRunnerMain)と同じ形:
    ///   in-app(注入) → WebView 画面だけ XCUITest へ委譲 → 不可な操作だけ XCUITest へ回す
    /// **inapp-boost モードでないとき(inapp 単独・xcuitest・実機)は素の1本**にする
    /// **`probePort` は「同一性を確かめに行ってよい loopback のポート」**。
    /// `provisioned.port` を外から使ってはいけない —— xcuitest 分岐は `XCUIBridgeResolver` が
    /// **接続先を振り替える**ことがあり、実機は loopback ですらない。誤ったポートを
    /// `connectedPorts` に記録すると、`deviceIdentityChanged` が**無関係な機のブリッジを読んで
    /// 正しい呼び出しを拒否し、記憶まで捨てる**(穴を塞ぐより悪い)。
    /// **確かめられないときは nil**(ガードは何もしない)
    static func iosDriver(provisioned: ProvisionedIOSDevice) async throws
        -> (driver: AppDriver, probePort: UInt16?) {
        // **MCP の iOS は常に XCUITest**(ユーザー決定。in-app は使わない)。供給は resolveProfileTarget が
        // bridge を xcuitest に差し替えてから行う。resolve は接続先が in-app だったときの振り替えも担う
        let resolution = await XCUIBridgeResolver.resolve(
            preferred: provisioned.xcuiPort ?? provisioned.port, repoRoot: try? RepoRoot.find(),
            logger: { Self.logStderr($0) })
        // **実機は UDID を渡す**: install/uninstall は simctl ではなく devicectl が要り、
        // clearAppData は「実機では不可」と即答できる(渡さないとデバイス名で simctl を
        // 撃つことになり、的外れな失敗になる)
        let client = BridgeClient(
            port: resolution.endpoint.port, host: resolution.endpoint.host,
            physicalUDID: provisioned.physical ? provisioned.udid : nil)
        // **launch はシナリオ実行と同じく FastLaunchDriver**(素の XCUIApplication.launch() は実測 6.6s)
        let driver = SessionRecoveryDriver(
            base: FastLaunchDriver.wrapping(client, simulatorUDID: provisioned.physical ? nil : provisioned.udid),
            appIsRunning: SimulatorAppProcess.recoveryProbe(simulatorUDID: provisioned.physical ? nil : provisioned.udid,
                                                            physicalUDID: provisioned.physical ? provisioned.udid : nil))
        return (driver, probePort(physical: provisioned.physical, endpoint: resolution.endpoint))
    }

    /// 同一性を確かめに行ってよい loopback のポート(**実際に繋いだポート**。preferred ではない)。
    /// **実機には出さない**: 実機のブリッジは loopback ではないので、ポート番号だけで 127.0.0.1 を叩くと
    /// 無関係なシミュレータのブリッジを読み、`deviceIdentityChanged` が正しい呼び出しを拒否し記憶まで捨てる
    static func probePort(physical: Bool, endpoint: BridgeEndpoint) -> UInt16? {
        (physical || endpoint.host != BridgeEndpoint.loopbackHost) ? nil : endpoint.port
    }

    /// **iOS(= XCUITest)のときだけ**添える切り分け。XCUITest では成立しないジェスチャがあり
    /// (表と実測は docs/commands.md)、何も起きなかったときに原因が分からないと詰む。
    /// **Android には付けない**(この制限が無い。無関係な助言は誤誘導になる)。
    /// **MCP の iOS は常に XCUITest なので、in-app へ切り替える手は勧めない**(profile を渡しても XCUITest のまま =
    /// 従っても何も変わらない助言になる)。確かめる場はシナリオ(実行の既定 inapp-boost モードはこのジェスチャを届ける)。
    /// **1文に圧縮**: UIKit アプリでも xcuitest モードなら毎回この助言が出ており、長文の苦情があった。
    /// **`frameworkKey` が判明していて一致しなければ黙る**(この助言は `framework` 1つに
    /// 固有の欠陥で、他のフレームワーク(判明した uikit や、もう一方の compose/flutter)には
    /// 効かない誤誘導になる)。**不明なら出すが「もしこのフレームワークなら」に弱める**
    /// (uiFrameworkHints は判定に成功した回しか埋まらないので、まだ問い合わせていない接続は不明側)
    func iosModeHint(_ framework: String, frameworkKey: AppUIFramework, _ gesture: String,
                      args: [String: Any]) -> String {
        guard bridges[Self.sessionKey(args)] == "xcuitest" else { return "" }
        let advice = " MCP drives iOS through XCUITest only, so this is not something to retry here;"
            + " a scenario run in the default inapp-boost mode delivers it — verify the gesture there."
        // 起動したアプリが分かっていて判定と別のアプリなら、判定は不明として扱う
        let key = Self.sessionKey(args)
        let hint = uiFrameworkHints[key].flatMap { hint in
            launchedBundleIDs[key].map { $0 == hint.bundleID } ?? true ? hint.framework : nil
        }
        switch hint {
        case .some(let known) where known != frameworkKey:
            return ""
        case .some:
            return " If nothing changed on iOS: \(framework) apps do not receive \(gesture) on the"
                + " XCUITest bridge —" + advice
        case .none:
            return " If nothing changed on iOS and this is a \(framework) app: it would not receive"
                + " \(gesture) on the XCUITest bridge —" + advice
        }
    }

    /// **launch する前に**確かめる。未インストールのまま `XCUIApplication.launch()` を撃つと、
    /// XCUI が記録する issue が(main queue 上 = テストのスタック外なので)ランナーごと落とし、
    /// ブリッジが消える —— 外部フィードバック #7 の真因はこれで、
    /// 「Safari 操作後に切断」に見えていたのは**別ポートで先に死んでいたランナー**だった。
    /// requireLiveApp と同じ形(XCUI に触れる前に弾いて手前でエラーにする)。
    ///
    /// ブリッジ側は未インストールと未起動を区別できない(XCUIApplication はどちらも notRunning)
    /// のでホストが確かめる。iOS のシステムアプリ(springboard/Safari)も get_app_container が
    /// runtime のパスを返すので誤って弾かない(実測)。
    ///
    /// **判定そのものを返す**(Bool? ではない): 「確かめられない」ときに撃つか断つかは呼び出し側
    /// (`launchGuardDecision`)がブリッジ・OS を見て決める。ここで nil = 素通しへ潰すと、
    /// in-app とそれ以外で扱いを変えられなくなる
    func installedVerdict(
        bundleID: String, driver: AppDriver, args: [String: Any]
    ) async -> InstalledAppCheck.InstallVerdict {
        // 差し替えドライバ(テスト)ではデバイスを照会しない = simctl/adb を撃たない。
        // **`.unknown` を返さない** —— 門は unknown を「撃たない」側に倒すので、差し替え
        // ドライバの launch が全部断られる
        guard makeDriver == nil else { return .installed }
        let verdict: InstalledAppCheck.InstallVerdict
        if let android = driver as? AndroidDriver {
            if let installed = android.isInstalled(bundleID: bundleID) {
                verdict = installed ? .installed : .notInstalled
            } else {
                verdict = .unknown("adb")
            }
        } else {
            // **実機は simctl ではなく devicectl**(ft_list_apps の同型判定と揃える —
            // MCPServer+SessionTools.swift の ftListApps 参照): 実機の udid を simulatorInstallVerdict
            // へ渡すと、udid の形が同じシミュレータ名(既定は機種名なので実機と同名になりやすい)を
            // 誤って照会し、別デバイスの在否を答える。候補は3段(ft_list_apps と同じ優先順)
            let key = Self.sessionKey(args)
            let candidateUDID = (args["udid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? udids[key].flatMap { $0 }
                ?? connectedPorts[key].flatMap { port in
                    (try? RepoRoot.find()).flatMap { BridgeDeviceRecord.load(port: port, repoRoot: $0) }
                }
            // **シミュレータの UDID(UUID 形)では devicectl を撃たない** —— 毎 ft_launch に 1 秒級の
            // `devicectl list devices` を払わせない。実機の UDID は `00008110-…`(8-16)で UUID にならない
            if let candidateUDID, UUID(uuidString: candidateUDID) == nil,
               let physicalDevices = try? IOSPhysicalDeviceCatalog.devices(),
               physicalDevices.contains(where: {
                   $0.udid == candidateUDID || $0.deviceCtlIdentifier == candidateUDID
               }) {
                if let apps = try? IOSPhysicalAppCatalog.apps(udid: candidateUDID) {
                    verdict = apps.contains { $0.id == bundleID } ? .installed : .notInstalled
                } else {
                    verdict = .unknown("devicectl could not list installed apps")
                }
            } else if let candidateUDID, UUID(uuidString: candidateUDID) != nil {
                // udid が分かるならデバイス名版(同名複数台で曖昧になりうる)を経由しない
                verdict = InstalledAppCheck.simulatorInstallVerdict(udid: candidateUDID, bundleID: bundleID)
            } else if let device = try? await driver.status().device {
                verdict = InstalledAppCheck.simulatorInstallVerdict(deviceName: device, bundleID: bundleID)
            } else {
                verdict = .unknown("the bridge did not report a device")
            }
        }
        return verdict
    }

    /// 撃つ側(Android・in-app)で確かめられなかったときの記録。**断る側では出さない** —— あちらは拒否文言そのものが呼び出し元へ届く
    static func uncheckedNote(bundleID: String, reason: String) -> String {
        "could not verify whether \(bundleID) is installed (\(reason)) — launching anyway."
    }

    /// `isAndroid`: MCP が autoInstall で入れるのは iOS だけ(mcp_server.md の差分表)。Android ではそう言う
    static func notInstalledMessage(bundleID: String, isAndroid: Bool = false) -> String {
        "\(bundleID) is not installed on this device. Install it with ft_install packagePath: <.app or .apk>, or check the bundle ID"
            + " (Android: the package name)."
            + (isAndroid ? " The MCP installs from an app profile's autoInstall only for iOS — on Android, ft_install it." : "")
    }

    /// **ft_launch の門**。nil = 撃ってよい・非 nil = その文言で断る。判定そのものは
    /// `InstalledAppCheck.launchGuard`(CLI の `fleetest launch` と共有する唯一の定義元)へ
    /// 委ね、ここは MCP 向けの文言(ft_install を指す等)を組むだけ
    static func launchGuardDecision(
        verdict: InstalledAppCheck.InstallVerdict, isAndroid: Bool, bridge: String?, bundleID: String
    ) -> String? {
        switch InstalledAppCheck.launchGuard(
            verdict: verdict, isAndroid: isAndroid, bridge: bridge, bundleID: bundleID) {
        case .allow: return nil
        case .refuse(.notInstalled): return notInstalledMessage(bundleID: bundleID, isAndroid: isAndroid)
        case .refuse(.unknown(let reason)): return uncheckedLaunchRefusal(bundleID: bundleID, reason: reason)
        }
    }

    /// **確かめられなかったので撃たない**ときの文言。①確かめられなかった理由 ②撃った場合に
    /// 起きること(XCUITest ランナーの main queue ハング → ブリッジ自壊。実測)③次の手、の3点を持つ
    static func uncheckedLaunchRefusal(bundleID: String, reason: String) -> String {
        "could not verify whether \(bundleID) is installed (\(reason))."
            + " Launching an app that turns out to be missing hangs XCUIApplication.launch(),"
            + " and after about 60s the XCUITest bridge self-terminates"
            + " (\"handler timed out after 60s; bridge self-terminating\") — this call refuses"
            + " instead of risking that."
            + " Retry in a moment (the check may succeed once the device is less busy),"
            + " install it first with ft_install packagePath: <.app or .apk>,"
            + " or double-check the bundle ID."
    }

    /// XCUITest のセッションは**そのアプリに閉じている**ので、ホーム画面やシステム UI は
    /// 素では読めない。ただし**読む方法はある**(springboard 参照セッション。BridgeRouter の
    /// handleLaunch が bundleID=com.apple.springboard を非破壊で特別扱いする)。
    /// 詰まる2つの応答 —— セッション不在の 409 と、背面アプリ照会の kAXErrorServerNotFound ——
    /// にだけ足す(フィードバック #6)。
    /// **inapp-boost モードには付けない**: in-app ブリッジは注入先アプリ専用で springboard を掴めない
    static func springboardHint(_ error: Error, bridge: String?) -> String {
        guard bridge == nil || bridge == "xcuitest" else { return "" }
        guard case DriverError.badResponse(let status, let body) = error,
              status == 409 || (status == 500 && body.contains("kAXErrorServerNotFound")) else {
            return ""
        }
        return "\nTo read the home screen or a system dialog instead of the app,"
            + " ft_launch bundleId: com.apple.springboard — it attaches to SpringBoard without"
            + " launching anything, and ft_snapshot then returns the home screen."
            + " ft_launch bundleId: <your app> resume: true to go back to it without losing its"
            + " state (xcuitest bridge only), or ft_launch bundleId: <your app> to relaunch it"
            + " from scratch."
    }

    /// **iOS のシステムダイアログはこの木に出ない**ことを、詰まった場所で言う。
    ///
    /// 位置情報・通知の許可や「"◯◯"で開きますか?」は **SpringBoard が別プロセスで描く**ので、
    /// アプリに閉じた XCUITest のセッションからは**存在しないのと同じ**に見える。しかも
    /// アプリはその間入力を受け取れないので、症状は「操作しても木が1つも変わらない」になる ——
    /// **`ft_snapshot` を何度撮っても手掛かりが出ない**形。評価者は座標でダイアログを叩いて
    /// 切り抜けており(画面サイズが変われば壊れる)、読む口が既にあること自体に気付けなかった。
    ///
    /// Android は木のセッションごと別パッケージへ移るので `switchedAppNote` が捕まえる ——
    /// **この穴は iOS 固有**。
    ///
    /// 出す場所は「操作しても変わらなかった」と告げる3箇所(waitFor の identical 判定・
    /// settle-lite の再読み・ft_batch の still identical)だけ = **読み手が実際に詰まった瞬間**。
    /// ゲートは `springboardHint` と同じ(bridge 不明 or xcuitest。in-app は注入先アプリしか
    /// 見えないので springboard を掴めず、勧めても実行できない)
    /// `probe` は詰まった瞬間に `/systemalert` へ聞いた答え(nil = 聞けなかった)。**答えで出し分ける** ——
    /// 「無い」と答えたのに SpringBoard のダイアログを疑わせると、読み手は存在しないダイアログを探しに行く
    static func systemDialogHint(bridge: String?, probe: SystemAlertProbeResponse?) -> String {
        guard bridge == nil || bridge == "xcuitest" else { return "" }
        if let probe {
            guard probe.present else {
                return " No system alert is in front (checked just now), so this is not a SpringBoard"
                    + " prompt; a notification banner or another overlay this tree does not show can still"
                    + " cover the app — look at ft_screenshot."
            }
            return " A system alert is in front right now"
                + (SystemUIGate.describeCovering(probe).map { " (\($0))" } ?? "")
                + " — it is drawn by SpringBoard, not the app, so it is not in this tree and the app cannot"
                + " receive input while it is there. Handle it: \(pressSystemAlertAdvice)."
        }
        return " If a system dialog is up (a permission prompt, an \"Open in …\" confirmation),"
            + " it is drawn by SpringBoard and not by the app, so it never appears in this tree"
            + " — and the app cannot receive input while it is there, which looks exactly like"
            + " this. Read it with ft_launch bundleId: com.apple.springboard (non-destructive) to see its"
            + " buttons, then \(pressSystemAlertAdvice)."
    }

    /// 詰まった瞬間だけ `/systemalert` に聞いてから `systemDialogHint` を作る(ゲート外の bridge では聞かない)
    static func systemDialogHint(bridge: String?, driver: AppDriver) async -> String {
        guard bridge == nil || bridge == "xcuitest" else { return "" }
        return systemDialogHint(bridge: bridge, probe: await driver.systemAlert().value)
    }

    /// home/appSwitcher 直後の XCUITest は「セッションはアプリのまま・画面は別」になり、次の
    /// ft_snapshot がアプリの古い木か 500 を返す。**撃つ前に言うしかない**(先に言う。
    /// 踏んでから調べさせない)。
    ///
    /// **同名の `backgroundedSessionNote(_:driver:)` とは別物**: あちらは木を撮ったあとに
    /// `/appstate` へ聞いて「今 前面か」を言う(実機の iPhone 13 では**その照会が
    /// 前面と答えて黙った**実測がある)。こちらは照会に頼らず「ツール自身が背面化させた」
    /// という事実だけで言うので、プラットフォームの答えが当てにならない機械でも必ず出る
    /// `switcherSeen` = appSwitcher を送った直後に SpringBoard へ聞いた答え(false = スイッチャーが見えない。nil = 聞けていない)
    static func backgroundingNavigationNote(target: String, bridge: String?, switcherSeen: Bool? = nil) -> String {
        guard target == "home" || target == "appSwitcher",
              bridge == nil || bridge == "xcuitest" else { return "" }
        if target == "appSwitcher", switcherSeen == false {
            return ". The App Switcher was not seen open: SpringBoard reports no switcher over the app. A notification centre"
                + " or Control Center that was down is closed by this gesture instead, so the app is probably still in front"
                + " — check ft_snapshot / ft_screenshot, and send appSwitcher again if you need it"
        }
        if target == "appSwitcher" {
            return ". The App Switcher opened, but the session still points at the app, so"
                + " ft_snapshot may keep returning the app's tree, and a tap by ref there could"
                + " land on whatever the switcher is drawing instead. Check ft_screenshot to see"
                + " what is actually on screen, then ft_launch your app again to bring it back"
        }
        return ". The session still points at the app, so ft_snapshot cannot read the home screen"
            + " — ft_launch bundleId: com.apple.springboard first (non-destructive)"
    }

    /// back が**空振りし得る**ことと、**アプリの外へ出る**ことの2つを言う。
    /// iOS は端の swipe(`XCUIApplication` の navigation gesture)なので、画面側が
    /// システムの戻るを実装していないと 1px も動かない。Android は最初の画面からの back で
    /// アプリが終了し、前面が別アプリになる(`switchedAppNote` が次の snapshot で捕まえる)
    static func backNoOpNote(target: String, bridge: String?) -> String {
        guard target == "back" else { return "" }
        let iosNote = bridge == "android" ? ""
            : " On iOS this is an edge swipe: screens with their own in-app back button"
                + " (and no system navigation) do not move at all."
        return "." + iosNote
            + " If it was the app's first screen, back leaves the app and the tools follow"
            + " whatever is in front now — ft_launch to come back."
    }

    /// **in-app 経路で背面化すると、以降は XCUITest ブリッジ側が受ける**
    /// (in-app ブリッジはアプリのプロセス内に住み、suspend されると応答しない。
    /// 寄せ替えは HybridFallbackDriver が持つ)。XCUITest は外側のプロセスなので関係なく、
    /// back は前面のままなので関係ない。**MCP の iOS は常に XCUITest なので今は到達しない**(判定は残す)
    static func backgroundedAppNote(target: String, bridge: String?) -> String {
        guard target != "back", bridge == "inapp" else { return "" }
        return ". The app is in the background now, so the tools run through the XCUITest bridge"
            + " (slower reads; ft_snapshot shows whatever is on screen now — the home screen /"
            + " app switcher — not the app) until you bring it back with ft_launch"
    }

    /// 待ちの既定(秒)。定義元は FTCore.DefaultWait(DSL の FTRuntime.defaultTimeout と共有)
    static let defaultWaitSeconds: Double = DefaultWait.seconds

    /// ポーリング間隔(秒)。短くしても律速は snapshot 自体(iOS in-app で約 0.12s)。
    /// waitFor と waitForChange(snapshotAfterBody)が共有する
    static let waitPollSeconds: Double = 0.3

    /// waitForChange が「変わった」後に安定(直前の読みと一致)を確かめる再読の上限。
    /// 1回で一致するのが普通で、上限まで揺れ続けたら採り直しをやめて still-changing を注記する
    /// —— waitSeconds を食い潰さない固定小コストに抑えるための蓋(settleWaitSeconds × この回数)
    static let changeSettleRereads = 3

    /// 外れた待ちを切り上げる「木が変わらない時間」(秒)。**根拠**: 正しく当たった待ちで、当たる前に木が変わらなかった
    /// 最長は 0.9 秒(地図の経路検索の実測 16 回)、わざと遅らせた画面は 2.0 秒(E2EY の読み込み中の骨組み = 動かない
    /// 灰色の帯。契約は E2EYAppCMP/docs/ui-contract.md の A3)。その上に余裕を足した値。**尽きたとき**: 応答で
    /// 「N 秒動かなかったので切り上げた」と言い、まだ読み込み中なら waitForChange で待つよう案内する
    /// (`waitMissHeadline`)。これより長く何も変えずに読み込む画面は、届く前に切り上げる
    static let waitForQuietCutoffSeconds: Double = 3.0

    /// 切り上げてよい待ちか。上限が切り上げの時間以下なら意味が無い(呼び手が短い上限を選んでいる)・部分一致が
    /// 見えた・読み込み中の印(中身の無い大きなスクロール領域 = `emptyLoadingScroller`)があるときは上限まで待つ
    static func quietCutoffApplies(cap: Double, partialSeen: Bool, latest: SnapshotResponse) -> Bool {
        cap > waitForQuietCutoffSeconds && !partialSeen && emptyLoadingScroller(in: latest) == nil
    }

    /// selector が出るまで snapshot を撃ち直す。**照合は DSL と同じ**(FTSelector →
    /// StepExecutor)なので、ここで書ける式はそのままシナリオへ持ち込める。
    ///
    /// **部分一致が見えた待ちは満額待つ**(案B): 周回ごとに部分一致の有無だけ
    /// (`notationHint` はメモリ上の計算で往復を払わない)見て、最初に見えた経過秒とヒントを
    /// 覚える —— ローディング中のプレースホルダが部分一致で先に出て、本命が後から来る画面があるため。
    /// **部分一致も読み込み中の印も無く、木が `waitForQuietCutoffSeconds` 変わらなければ切り上げる**
    /// (`quietStopAfter` = 切り上げた経過秒。根拠は定数の doc)。外れたセレクタ(AI が表記を推測で外した)を
    /// 上限まで待っていた(実測: 地図の計測で空振り15回・各7〜12秒)
    /// `refetched`: 撃ち直しが1回でも起きたか(ref 世代管理で追加)。false のとき
    /// `snapshot` は引数 `first` そのもの(値も ref 番号も変わっていない)。呼び手はこれを見て
    /// `adoptSnapshot` を通すかどうかを決める —— **通さないと世代が進まないだけで無害だが、
    /// 通すと事故る**: `first` は既にセッション ref(base 込み)なので、
    /// native 前提の adoptSnapshot にそのまま渡すと素の native と誤認して余計な世代を作る
    /// `elementLimit`: ポーリングの読みへ毎回かける要素上限(nil = ブリッジの既定)。
    /// **ここを通さないと web ページの天井ラッチが待ちの経路だけ効かない**(実害):
    /// 最初の1枚は `freshSnapshot` がラッチして天井で撮り直すのに、その直後の waitFor が
    /// 素の 120 で撮り直すため、**返る木は切り詰められたまま**になり
    /// 「maxElements を上げろ」の旧注記が出続けていた(`raiseElementLimitOnNextSnapshot` は
    /// 1回ぶんの指定なので、freshSnapshot の読みで消費されている)
    static func waitFor(_ selector: String, driver: AppDriver, first: SnapshotResponse,
                        seconds: Double, elementLimit: Int? = nil) async throws
        -> (found: Bool, snapshot: SnapshotResponse, partialSeenAfter: Double?, partialHint: String,
            refetched: Bool, quietStopAfter: Double?) {
        var partialSeenAfter: Double?
        var partialHint = ""
        // 構文は呼び手が待つ前に門(parseSelectorArgument)で確かめ済み。ここで弾かれたら通貨の除外を掛けない側に倒す
        let selectorLabel = (try? parseSelectorArgument(selector, argument: "waitFor"))?.primary.label ?? ""
        func notePartial(_ snapshot: SnapshotResponse, elapsed: Double) {
            guard partialSeenAfter == nil else { return }
            let hint = notationHint(selector, in: snapshot)
            // **通貨の表記の違いだけなら満額待ちの理由にしない**: 「待てば本物が来る」合図ではない(`*円*` を待っても画面は
            // `¥715` のまま)。数えると止まった画面を上限まで待っていた(計測: 8s の上限で 8.7s)。注記は外れた応答に今までどおり出る
            guard !hint.isEmpty, hint != currencyNotationHint(selectorLabel, in: snapshot) else { return }
            partialSeenAfter = elapsed
            partialHint = hint
        }
        if matches(selector, in: first) { return (true, first, nil, "", false, nil) }
        SlowCallWatchdog.mark("waiting for \(selector) (cap \(secondsText(seconds)))")
        notePartial(first, elapsed: 0)
        let start = Date()
        let deadline = start.addingTimeInterval(seconds)
        var latest = first
        var refetched = false
        var lastChange = start
        while Date() < deadline {
            try await Task.sleep(for: .seconds(waitPollSeconds))
            // **キャッシュを捨てて撮る**: 同じ木を読み続けると、出ていても永遠に出ない
            if let elementLimit { driver.raiseElementLimitOnNextSnapshot(elementLimit) }
            let previous = latest
            latest = driver.supportsCacheBypass
                ? try await driver.snapshot(bypassingCache: true) : try await driver.snapshot()
            refetched = true
            if matches(selector, in: latest) { return (true, latest, nil, "", true, nil) }
            notePartial(latest, elapsed: Date().timeIntervalSince(start))
            if !looksUnchanged(previous, latest) { lastChange = Date() }
            // **上限の後の読みでは切り上げと言わない**(最後の読みが上限を跨ぐと「上限より前に止めた」と言いながら
            // 上限を超えた秒数を出していた = 計測で指摘: "stopped after 5.1s instead of running to the 5s cap")
            if Date() < deadline,
               quietCutoffApplies(cap: seconds, partialSeen: partialSeenAfter != nil, latest: latest),
               Date().timeIntervalSince(lastChange) >= waitForQuietCutoffSeconds {
                return (false, latest, nil, "", true, Date().timeIntervalSince(start))
            }
        }
        // ループが1周も回らなかった(seconds <= 0 等)ときは latest === first のまま = 未撃ち直し
        return (false, latest, partialSeenAfter, partialHint, refetched, nil)
    }

    /// セレクタ式(`#id` / ラベル / `.type` / `||` 等)がこの画面に1つでも当たるか。
    /// **解決ロジックは `matchedElements`(MCPServer+Snapshot.swift)そのもの** —— 2つ目の
    /// セレクタ解決を作らない
    static func matches(_ selector: String, in snapshot: SnapshotResponse) -> Bool {
        !matchedElements(selector, in: snapshot).isEmpty
    }

    /// 要素木の軽量指紋(ft_navigate の back 判定・ft_screenshot の鮮度判定で使う)。
    /// **定義元は FTCore.StaleFrameDetector.treeFingerprint**(DSL の occlusion-guard と共有)。
    /// ref を含めない理由・単独では拾えない限界はそちらのコメント参照
    static func treeFingerprint(_ snapshot: SnapshotResponse) -> Int {
        StaleFrameDetector.treeFingerprint(of: snapshot.elements)
    }

    /// セッションのアプリが前面に居ないときの注記(居るとき・判定できないときは空)。
    /// 判定は 1 往復(/appstate)なので snapshot の1割程度。**黙って嘘を返すよりは安い**
    ///
    /// **システム UI の面には言わない**(実機 Pixel 4a で実害確認)。Android の
    /// `foregroundAppID()` は **topmost *app* package**(`mCurrentFocus` のアクティビティ名)を
    /// 返すので、通知シェード / クイック設定のように**アクティビティを持たない窓**が前面に居ると
    /// `com.android.systemui` は決して一致しない —— 木がまさにその面のものでも
    /// **必ず**「前面に居ない・木は古い・ft_launch で戻せ」と言っていた。事実と逆なうえ、
    /// 助言どおり `ft_launch com.android.systemui` を撃つ道理も無い。
    /// **`switchedAppNote` は同じ集合を見て既にこれを避けている**(欠陥⑧)—— こちらが
    /// その掃討漏れだった。判定材料が無いのだから**黙る**(この関数の既存の縮退と同じ)。
    /// iOS の springboard では再現しない(実測: 誤警告なし)ので触っていない
    static func backgroundedSessionNote(_ snapshot: SnapshotResponse,
                                        driver: AppDriver) async -> String {
        guard let bundleID = snapshot.sessionBundleID else { return "" }
        // 判定は ForegroundState.judge。システム UI・SpringBoard のセッションは judge が inFront 以外を返すので黙る
        let verdict = ForegroundState.judge(ForegroundFacts(
            sessionBundleID: bundleID,
            tree: SystemUITreeKind.classify(sessionBundleID: bundleID, identifiers: snapshot.elements.map(\.identifier)),
            sessionInForeground: bundleID == ForegroundState.springboard || systemDialogPackages.contains(bundleID)
                ? .notAnswerable : await ForegroundState.inForegroundProbe(driver, bundleID: bundleID)))
        guard case .otherApp(name: .none) = verdict else { return "" }
        return "\(bundleID) is NOT in the foreground: this tree is its last state, not what is on"
            + " screen now (\(notInFrontCauses))."
            + " Bring it back with ft_launch before trusting these refs\n"
    }

    /// 木がシステム UI のものなのでキーガードを聞く(ロック画面とシェードは木から分けられない)。それ以外・iOS は聞かない
    static func keyguardFact(for snapshot: SnapshotResponse, driver: AppDriver) async -> Probe<Bool> {
        guard snapshot.sessionBundleID == SystemUITreeKind.systemUIPackage else { return .notAnswerable }
        return await ForegroundState.keyguardProbe(driver)
    }

    /// 「前面ではない」と分かるが理由を言えないときの原因の並べ方(ft_status と共有)。iOS の `/appstate` は
    /// 別アプリ・ホーム・プロセスの終了を区別しない(分けるにはブリッジの版上げが要る)ので、断定せず並べる
    static let notInFrontCauses = "another app, the home screen or a system screen is in front, or the app's process has ended"

    /// **このセッションが home / appSwitcher を送ったあと、まだ ft_launch で戻していない**
    /// ときの注記。`/appstate` の照会と違い**プラットフォームに聞かない**ので、答えが
    /// 当てにならない機械(実機 iPhone 13 で前面と答えた実測)でも必ず出る。
    /// **文言は `HybridFallbackDriver.backgroundSnapshot` と合わせてある**: 背面化中は
    /// 再前面化せず今の画面(SpringBoard 等)をそのまま読むので、対象アプリの「最後の状態」ではなく
    /// 「今そこに実際にあるもの」だと案内する
    /// **名指しは対象アプリ**: 背面化中の読みは SpringBoard を参照するので snapshot の
    /// sessionBundleID は com.apple.springboard になっている。呼び手は launch したアプリの ID を渡し、
    /// それが無いときも springboard を「戻すべきアプリ」と言わない
    /// **`treeIsAppsOwn`**: 木の sessionBundleID がそのアプリのまま(XCUITest のセッションは背面化
    /// してもアプリに付いたままで、**アプリ自身の木**を返し続ける)なら「今の画面」とは言わない ——
    /// 実機 iPhone 13 では appSwitcher の直後に「the tree below is whatever is actually on screen」と
    /// 言いながらアプリの木を返していた。inapp-boost モードの背面化読み(SpringBoard を
    /// 参照 = sessionBundleID が springboard)のときだけ「今そこにあるもの」
    static func sentToBackgroundNote(_ sessionBundleID: String?, treeIsAppsOwn: Bool) -> String {
        let app = sessionBundleID.flatMap { $0 == "com.apple.springboard" ? nil : $0 } ?? "the app"
        if treeIsAppsOwn {
            return "⚠️ This session sent home/appSwitcher and has not brought \(app) back:"
                + " the tree below is still \(app)'s own tree (the session stays attached to it),"
                + " NOT what is on screen now (home screen / app switcher / a system screen) —"
                + " a tap by ref here lands on whatever is drawn there instead."
                + " Check with ft_screenshot, and ft_launch \(app) to return.\n"
        }
        return "⚠️ This session sent home/appSwitcher and has not brought \(app) back:"
            + " the tree below is whatever is actually on screen now (home screen / app switcher /"
            + " another app / a system screen), not \(app)'s. Check with ft_screenshot, and ft_launch to return.\n"
    }

    /// 背面化の記録が残っているときの注記と、記録を消してよいか(`appIsBack`)。
    /// **Android の木は常に前面の窓**(`treeSession` = 前面のパッケージ)なので、launch したアプリが前面に
    /// 戻っていれば言うことは無い(ランチャーから開き直した等。ft_launch を経ない戻り方)。戻っていなければ
    /// 木は「今の画面」で、前面のパッケージを「戻すべきアプリ」と名指ししない(launch の記録が無ければ "the app")。
    /// iOS は木がアプリ自身のままでも前面とは限らないので、記録は ft_launch でだけ消す
    /// `switcherOpened`: このセッションが appSwitcher を送ったまま。Android の前面の窓はスイッチャーの間もアプリのままなので、
    /// 木がアプリのものでも「戻った」とは読まない(既定値を置かない = 呼び手に決めさせる)
    static func navigatedAwayNote(launched: String?, treeSession: String?, switcherOpened: Bool,
                                  isAndroid: Bool) -> (note: String, appIsBack: Bool) {
        if isAndroid {
            if let launched, treeSession == launched {
                return switcherOpened ? (sentToBackgroundNote(launched, treeIsAppsOwn: true), false) : ("", true)
            }
            return (sentToBackgroundNote(launched, treeIsAppsOwn: false), false)
        }
        return (sentToBackgroundNote(
            launched ?? treeSession,
            treeIsAppsOwn: treeSession != nil && treeSession != "com.apple.springboard"
                && (launched == nil || treeSession == launched)), false)
    }

    /// システムダイアログのパッケージ/バンドル ID。これらへの切り替わりは「別アプリに迷い込んだ」
    /// ではなく「対象アプリの上にシステム UI が出ている」なので、案内を変える(欠陥⑧)。
    /// 実測: 位置情報の許可ダイアログ(permissioncontroller)で通常の案内(ft_launch し直す)に
    /// 従うと、ダイアログを放置したままアプリを再起動してループした
    static let systemDialogPackages: Set<String> = ForegroundState.systemDialogPackages

    /// **この木は ft_launch したアプリのものか**。違えば名指しで止める。
    ///
    /// `backgroundedSessionNote` と役割が違う: あちらは「session のアプリが背面」を見るが、
    /// **session 自体が別アプリへ移ってしまう経路**(Android)ではあちらは永遠に沈黙する。
    /// ここは「起動したもの」対「木が名乗るもの」を比べるので、session が追従しても捕まる。
    ///
    /// **判定材料が無いときは黙る**(嘘を足さない): ft_launch していない・木が名乗らない。
    ///
    /// `processEvidence`(Android のみ・呼び出し側が adb で引く)が `running == false` を
    /// 言っているときは、原因を「操作でアプリを離れた」から「プロセスが無い(クラッシュの疑い)」
    /// へ差し替える —— 実機 Pixel 4a で実測: #btn_crash_confirm でプロセスを落とすと、
    /// 通常文言は launcher へ迷い込んだとしか言わず、実際に落ちたことを伝えられない。
    /// **`stoppedByTool` はさらに確度が高い事実**(推測ではなく、ツール自身が撃った操作)なので
    /// processEvidence より先に見る —— 明示 ft_clear_app_data / ft_install の直後は
    /// 「クラッシュしたかも」ではなく「この操作で止めた」と言う
    static func switchedAppNote(launched: String?, snapshot: SnapshotResponse,
                                processEvidence: AndroidAppProcessEvidence? = nil,
                                stoppedByTool: String? = nil,
                                keyguardShowing: Probe<Bool> = .notAnswerable) -> String {
        guard let launched, let session = snapshot.sessionBundleID, session != launched else {
            return ""
        }
        // 判定は FTCore.ForegroundState.judge の1箇所(順序もそこ)。ここは文言だけ
        let verdict = ForegroundState.judge(ForegroundFacts(
            launched: launched, sessionBundleID: session,
            tree: SystemUITreeKind.classify(sessionBundleID: session, identifiers: snapshot.elements.map(\.identifier)),
            keyguardShowing: keyguardShowing,
            processRunning: processEvidence.map { .value($0.running) } ?? .notAnswerable,
            stoppedByTool: stoppedByTool))
        switch verdict {
        case .home:
            // springboard は ft_launch bundleId: com.apple.springboard がホーム画面へ attach する
            // 正規の使い方(ツール説明に明記)なので、その用途を否定しない文言にする
            return "⚠️ This tree is the home screen (springboard), not \(launched)."
                + " Reading it is fine — ft_launch bundleId: com.apple.springboard is the supported"
                + " way to attach there — but ft_launch \(launched) first if you meant to keep"
                + " testing the app.\n"
        case .locked:
            return "⚠️ This tree is the lock screen / always-on display (\(session)), not \(launched):"
                + " the device screen went dark or is locked, so it is not a dialog to operate. The"
                + " next tool call wakes a dark screen — read the screen again; if the screen is already on and this"
                + " tree comes back, the device is locked (the tool cannot enter a PIN, pattern or password): unlock it"
                + " by hand, then ft_launch \(launched) with resume: true.\n"
        case .covered:
            // 通知シェード・クイック設定の要素がある systemui の木。権限ダイアログではなく、アプリは下で生きている
            return "⚠️ \(session) (the notification shade or quick settings) is drawn over \(launched), not a dialog of the app."
                + " \(launched) is still running underneath: ft_navigate back closes the shade and keeps the app's state"
                + " (ft_launch also closes it but restarts the app, so typed values are lost)."
                // ロック画面の木も同じ要素 ID を持ち、解除画面の本体が無い回は木から分けられない
                + " If back changes nothing, this is the lock screen: unlock the device first.\n"
        case .dialog:
            return "⚠️ \(session) is a system dialog drawn over \(launched)"
                + " (e.g. a permission prompt), not the app itself. Operate the dialog"
                + " (tap its buttons, or back) to get back to \(launched) — ft_launch restarts"
                + " the app and leaves the dialog on screen, so you would loop without progress.\n"
        case .toolStopped(let by):
            return "⚠️ This tree belongs to \(session), NOT the app you launched (\(launched))"
                + " — \(launched) is not running because \(by) stopped it just now"
                + " (not a crash). ft_launch \(launched) to start it again.\n"
        case .processGone:
            var note = "⚠️ This tree belongs to \(session), NOT the app you launched (\(launched))"
                + " — and \(launched) has no process any more: it may have crashed."
            if let processEvidence, !processEvidence.crashSummary.isEmpty {
                note += " Last crash in logcat -b crash: "
                    + processEvidence.crashSummary.joined(separator: " / ") + "."
                    // **`crashOnly` は ft_logs の引数名ではない**: 実際のスキーマは
                    // `all`(既定 false = crash バッファのみ)なので、無指定の ft_logs がそのまま全文を出す
                    + " ft_logs shows the full trace."
            }
            return note + " ft_launch \(launched) to start it again.\n"
        case .inFront, .otherApp, .unknown:
            break
        }
        return "⚠️ This tree belongs to \(session), NOT the app you launched (\(launched))."
            + " Leaving the app (back from its first screen, home, an app switch) hands the"
            + " tools to whatever is in front now — and sibling test apps can look identical."
            + " ft_launch \(launched) before trusting these refs\n"
    }

    static func isLockScreenOrAlwaysOnTree(_ snapshot: SnapshotResponse) -> Bool {
        SystemUITreeKind.isLockScreenOrAlwaysOn(sessionBundleID: snapshot.sessionBundleID,
                                                identifiers: snapshot.elements.map(\.identifier))
    }

    /// Android の ft_type / ft_clear_input の直前に、起こしたアプリの UI フレームワークを `AndroidDriver` へ渡す
    /// (DSL の ScenarioRunnerMain と同じ AppUIFrameworkQuery の静的な答え。ブリッジは ref なしの打鍵で焦点の欄を押すのを
    /// Flutter のときだけにする)。起こした記憶が無い・静的に決まらなければ nil = 今まで通り押す。iOS は何もしない
    func wireAndroidUIFramework(_ driver: AppDriver, args: [String: Any]) {
        guard let android = driver as? AndroidDriver else { return }
        let key = Self.sessionKey(args)
        guard let bundleID = launchedBundleIDs[key] else { android.appUIFramework = nil; return }
        android.appUIFramework = androidUIFrameworkLookup(bundleID, installedPackagePaths[key])
    }

    /// MCP の executor に「起こしたアプリのプロセスが居ないのに別アプリの木で解決しない」門を付ける(Android のみ。判定は
    /// FTCore の `AppProcessGone` で DSL と共有 = StepExecutor が撃つ前に断る)。起こした記憶が無ければ何もしない。
    /// 持ち主が違うときだけ adb を払う
    func wireAppGoneGuard(_ executor: StepExecutor, driver: AppDriver, isAndroid: Bool, args: [String: Any]) {
        guard isAndroid, let launched = launchedBundleIDs[Self.sessionKey(args)] else { return }
        let serial = (driver as? AndroidDriver)?.serial ?? (args["serial"] as? String)
            ?? connectedAndroidSerials[Self.sessionKey(args)]
        let probe = androidPackageRunning
        executor.launchedBundleID = launched
        executor.appProcessRunning = { package in
            await Self.runOffCooperativePool(name: "fleetest-mcp-app-gone") { probe(package, serial) }
        }
    }

    /// `switchedAppNote` の `processEvidence` 引数を埋める(Android のみ・adb 2〜3往復)。
    /// **すり替わっていない通常の呼び出しでは adb を払わない**(session == launched ならここで
    /// 抜ける)。serial は明示引数か、このセッションが覚えている宛先(connectedAndroidSerials。
    /// resolveAndroidSerial と違い**曖昧でも例外にしない** —— これは付加情報で、
    /// 取れなければ nil のまま adb の既定(単一接続時のみ解決)に委ねる。
    ///
    /// **crashSummary は直近の launch 以降に絞り直す**(`AndroidAppProcessEvidenceQuery.scoped`。
    /// DSL はシナリオの開始を起点に同じ関数を通る)。
    /// launch を覚えていない(このセッションが ft_launch していない・profile 経由で既存の
    /// セッションに繋いだ)ときは `AndroidAppProcessEvidenceQuery.defaultAttributionWindowSeconds` へ落ちる
    /// (無制限に戻すと元の欠陥に戻るので、「分からない」を「無限に遡ってよい」とは読まない)
    func androidProcessEvidenceForSwitch(launched: String?, snapshot: SnapshotResponse,
                                         driver: AppDriver, args: [String: Any])
        -> AndroidAppProcessEvidence? {
        guard driver is AndroidDriver, let launched, let session = snapshot.sessionBundleID,
              session != launched else { return nil }
        let serial = (args["serial"] as? String) ?? connectedAndroidSerials[Self.sessionKey(args)]
        guard let evidence = AndroidAppProcessEvidenceQuery.query(package: launched, serial: serial)
        else { return nil }
        return AndroidAppProcessEvidenceQuery.scoped(evidence, package: launched, serial: serial,
                                                     since: launchTimestamps[Self.sessionKey(args)])
    }
}
