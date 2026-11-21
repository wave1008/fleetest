// MCPServer+BridgeResolution.swift
// iOS の宛先ポートの解決(udid / port の照合・待ち受けの探索)と、ブリッジが見つからない・答えないときの診断と文言。
// ドライバの組み立て(resolveDriver)とセッションの記憶は MCPServer+Driver.swift

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {
    /// `udid` / `port` から iOS の宛先ポートを決める(H-2)。**両方渡されたら port を優先**し、
    /// **食い違うなら明示的に失敗する** —— 黙ってどちらかを採ると、読み手は指したつもりの
    /// デバイスと別の機を操作したことに最後まで気付けない。
    /// どちらも無ければ nil(resolveIOSPort が既定ポート → 探索の順で決める)。
    /// **udidPorts が空のときだけ追加調査(IO)を払う** —— 応答が1本でもあればそのまま素通り
    /// `rebuildSimulatorBridge`: 診断が「Simulator に何も待ち受けていない」のとき、その udid の xcuitest ランナーを起動し直して
    /// ポートを返す閉包(`MCPServer.rebuildMissingSimulatorBridge`。門と記憶はあちら)。nil = 起動し直さない(読むだけの呼び手)
    static func portForIOS(_ args: [String: Any], rememberedPort: UInt16?,
                           rebuildSimulatorBridge: ((String, UDIDBridgeDiagnosis) async -> UInt16?)? = nil) async throws -> UInt16? {
        let port = try Self.portArgument(args)
        guard let udid = (args["udid"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            return port
        }
        // **走査の前に候補1本だけを狙い撃つ**(実測: 20 本近いブリッジが動くフリートで、udid を添えた
        // 呼び出しは入口と driver() で走査を2回払い 1 回ごとに 3.5〜6 秒かかった。省略・port だけは 0.6 秒)。
        // 一致と確かめられたときだけ走査を省く。不一致・不明は従来の走査と文言へ(同じ probe を二度撃たない)
        var knownExplicitIdentity: ExplicitPortIdentity?
        if let candidate = port ?? rememberedPort {
            let identity = await Self.explicitPortIdentityProbe(port: candidate, udid: udid,
                                                                repoRoot: try? RepoRoot.find())
            switch Self.afterCandidateProbe(candidate: candidate, explicit: port, identity: identity) {
            case .use(let confirmed):
                return confirmed
            case .scan(let known):
                knownExplicitIdentity = known
            }
        }
        let udidPorts = await bridgePorts(forUDID: udid)
        guard udidPorts.isEmpty else {
            return try reconcilePort(port, udid: udid, udidPorts: udidPorts)
        }
        // **明示 port は scan より先に、その1本だけ狙い撃ちで本人確認する**(MN-51.6):
        // `bridgePorts(forUDID:)` は全ポートへ一律2秒の窓で scan するだけなので、高負荷で busy な
        // XCUITest(quiescence 待ちで数十秒ブロックしうる)は生きていても scan の結果に載らない。
        // 呼び手が port を明示しているなら、その1本だけをもっと長い窓で確かめたほうが scan の
        // 取りこぼしより確実。一致すれば即採用・食い違えば拒否・確かめられなければ(無応答/読めない)
        // 下の一般診断へフォールバックする(timedOut を「居ない」に畳まないのは
        // `noResponsiveBridgeMessage` 側の規律と同じ)
        if let port {
            let identity: ExplicitPortIdentity
            if let knownExplicitIdentity {
                identity = knownExplicitIdentity
            } else {
                identity = await Self.explicitPortIdentityProbe(port: port, udid: udid, repoRoot: try? RepoRoot.find())
            }
            switch identity {
            case .confirmedMatch:
                return port
            case .confirmedMismatch(let actualUDID):
                throw MCPError(Self.explicitPortMismatchMessage(port: port, udid: udid, actualUDID: actualUDID))
            case .unknown:
                break
            }
        }
        var diagnosis = await Self.udidBridgeDiagnosis(udid: udid)
        // **予算切れは 1 回だけ診断し直す**(失敗の経路だけで払う。最大で予算 1 回ぶん)。Simulator を起動した直後の最初の呼び出しは
        // 診断(simctl の一覧)が予算を超えて「確かめられない」で断られ、2 回目は通る実測がある(陽性対照で 2/2)。
        // 先の診断は打ち切られず走り続けて一覧の読み込みを温めるので、2 回目は予算内に終わる
        if diagnosis.timedOut { diagnosis = await Self.udidBridgeDiagnosis(udid: udid) }
        // **走査が取りこぼし、診断の probe には答えたブリッジ**(走査の2秒の窓の間だけ busy だった)。
        // 捨てると「居ない・bridge up しろ」になり、run が使っている端末に2本目を起動させる
        var identities: [(UInt16, ExplicitPortIdentity)] = []
        for answered in diagnosis.answeredPorts.sorted() {
            identities.append((answered, await Self.explicitPortIdentityProbe(
                port: answered, udid: udid, repoRoot: try? RepoRoot.find())))
        }
        let answered = Self.classifyAnsweredPorts(identities)
        if !answered.confirmed.isEmpty {
            return try reconcilePort(port, udid: udid, udidPorts: answered.confirmed)
        }
        diagnosis.answeredPorts = answered.unconfirmed
        // **実機のランナーが生きていてトンネル(iproxy)だけが消えた**なら張り直してから本人確認する(供給の引き取り・
        // ライブ操作の自動起動と同じ門 = MN-78.1・MN-82.5)。ランナーは止めない。答えなければ下の文言へ
        if Self.nothingListensFor(diagnosis), diagnosis.lookup == .physical,
           let restored = await Self.restoreMissingPhysicalTunnel(udid: udid),
           case .confirmedMatch = await Self.explicitPortIdentityProbe(port: restored, udid: udid,
                                                                      repoRoot: try? RepoRoot.find()) {
            return try reconcilePort(port, udid: udid, udidPorts: [restored])
        }
        // **Simulator のランナーが消えている(何も待ち受けていない)なら起動し直してから本人確認する**。B1 の自動回復
        // (`dispatchRetryingAfterBridgeRecovery`)は覚えたポートの接続拒否にしか反応せず、**udid を毎回添える呼び手は
        // ここで「no running bridge」になって二度と戻らなかった**(負荷テスト: ランナーを殺した後 5 分で 300 回)。
        // 門(他のセッションの端末・このセッションで一度失敗)と provision は閉包の側(1 箇所)。答えなければ下の文言へ
        if Self.nothingListensFor(diagnosis), diagnosis.lookup == .simulator,
           let rebuilt = await rebuildSimulatorBridge?(udid, diagnosis),
           case .confirmedMatch = await Self.explicitPortIdentityProbe(port: rebuilt, udid: udid,
                                                                      repoRoot: try? RepoRoot.find()) {
            return try reconcilePort(port, udid: udid, udidPorts: [rebuilt])
        }
        return try reconcilePort(port, udid: udid, udidPorts: udidPorts, diagnosis: diagnosis)
    }

    /// 診断が完走し、どのポートも待ち受けていなかったか(純粋)。busy・固まり・答えたが確かめられない・予算切れは
    /// 「居ない」ではないので張り直しの対象にしない
    static func nothingListensFor(_ diagnosis: UDIDBridgeDiagnosis) -> Bool {
        !diagnosis.timedOut && diagnosis.answeredPorts.isEmpty && diagnosis.wedgedPorts.isEmpty
            && diagnosis.listeningButUnresponsive.isEmpty
    }

    /// この実機を宛先に持つランナー(xcodebuild)が生きていれば、そのポートのトンネルだけを張り直す。張り直したポートを返す。
    /// - 張り直しは `ProvisionLock` の内側(同じポートへ iproxy を2本起こさない)。排他が作れなければ張り直さない(任意の回復なので、
    ///   排他なしで進めて供給の採番・停止と重ねるより、従来の文言で止まるほうが害が小さい)
    /// - **宛先(どのポートにこの実機のランナーが居るか・接続方式)は排他を取った後に確かめる** —— 取る前に確かめると、待っている間に
    ///   供給がそのポートを別の実機へ割り当て直したとき、`startIproxy` が別の実機の正常なトンネルを止めて張り替える
    /// - 接続方式は起動した側の記録(`.endpoint` のホストがループバック = USB の iproxy)から決める。記録が無ければ不明 = 張り直さない
    ///   (devicectl の照会の失敗を「USB ではない」に畳まない)
    /// - 排他は**張り直しが実際に終わるまで**握る(予算で先に返すと、張り直しの途中で排他を手放す)
    static func restoreMissingPhysicalTunnel(udid: String) async -> UInt16? {
        guard let repoRoot = try? RepoRoot.find() else { return nil }
        let lock: ProvisionLock
        do {
            lock = try ProvisionLock(stateDir: repoRoot.appendingPathComponent(".fleetest"))
        } catch {
            Self.logStderr("not re-establishing a USB tunnel for \(udid): the provisioning lock cannot be opened (\(error))")
            return nil
        }
        await lock.acquire()
        let restoredPort = await Self.runOffCooperativePool(name: "fleetest-mcp-tunnel-restore") { () -> UInt16? in
            guard let ps = try? Shell.run(["ps", "-axo", "pid=,command="]), ps.status == 0,
                  let port = BridgeLauncher.runnersOnDevice(psOutput: ps.output, device: udid, excludingPort: 0).first?.port,
                  let endpoint = BridgeEndpoint.recorded(port: port, repoRoot: repoRoot), endpoint.isLoopback else { return nil }
            let restored = IOSDeviceTransport.restoreMissingTunnel(port: port, deviceUDID: udid, wired: true,
                                                                   repoRoot: repoRoot, log: { Self.logStderr($0) })
            return restored ? port : nil
        }
        lock.release()
        return restoredPort
    }

    /// 診断で答えたポートの本人確認の仕分け(純粋関数)。一致 = 採用・不明 = 「居ない」と言わない根拠・
    /// 別の udid = 捨てる(台帳が古いだけで、この udid のブリッジではない)
    static func classifyAnsweredPorts(_ identities: [(UInt16, ExplicitPortIdentity)])
        -> (confirmed: [UInt16], unconfirmed: [UInt16]) {
        (identities.filter { $0.1 == .confirmedMatch }.map(\.0),
         identities.filter { $0.1 == .unknown }.map(\.0))
    }

    /// 明示 port だけを狙い撃ちして udid を本人確認した結果(MN-51.6)。**「確かめられない」を
    /// 「一致した/しなかった」に畳まない** —— 3値のまま呼び出し元(`portForIOS`)へ渡す
    enum ExplicitPortIdentity: Equatable, Sendable {
        /// `/status` が答え、udid(実機は `statusForIdentityCheck` が記録で補う)が一致した
        case confirmedMatch
        /// `/status` が答えたが、別の udid を名乗った —— scan の取りこぼしではなく本当の食い違い
        case confirmedMismatch(actualUDID: String)
        /// 応答が無い/読めない/udid を判定できない —— 一致とも不一致とも言えない
        case unknown
    }

    /// `explicitPortIdentityProbe` が payload を確かめる窓。**scan の2秒より長く取る** ——
    /// scan の窓の短さが MN-51.6 の取りこぼしの原因なので、そこに揃えると同じ取りこぼしを再現する。
    /// `udidBridgeDiagnosisBudget`(3秒)に揃え、追加コストの上限を「診断1回ぶん」に留める
    static let explicitPortIdentityProbeTimeoutSeconds: Double = 3

    /// 明示 port の `/status` を1回だけ撃って udid を確かめる。**`statusForIdentityCheck` で
    /// 実機の未申告 udid を記録から補う**(`BridgeDiscovery.scan` と同じ規則) —— 補わないと
    /// 実機は毎回 `.unknown` に落ちる。判定そのものは `FTCore.BridgeIdentityCheck`(udid が
    /// 両側にあるときは udid だけを比べる枝なので `physical` は未使用・ダミー値でよい)を再利用する
    static func explicitPortIdentityProbe(
        port: UInt16, udid: String, repoRoot: URL?
    ) async -> ExplicitPortIdentity {
        let endpoint = repoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0) }
            ?? BridgeEndpoint(port: port)
        guard let reported = try? await BridgeClient(
            endpoint: endpoint, timeoutSeconds: Self.explicitPortIdentityProbeTimeoutSeconds
        ).status(timeout: Self.explicitPortIdentityProbeTimeoutSeconds) else { return .unknown }
        let status = BridgeDiscovery.statusForIdentityCheck(reported, port: port, repoRoot: repoRoot)
        guard let statusUDID = status.udid else { return .unknown }
        let expected = BridgeIdentityCheck.Expected(port: port, udid: udid, physical: false, bridge: nil)
        return BridgeIdentityCheck.matches(expected: expected, status: status)
            ? .confirmedMatch : .confirmedMismatch(actualUDID: statusUDID)
    }

    /// 走査前の狙い撃ちの結果から次を決める(純粋関数)。一致なら採用。それ以外は走査へ進み、
    /// 候補が明示 port だったときだけ結果を持ち越す(記憶の候補の不明を明示 port のものと混ぜない)
    enum CandidateProbeOutcome: Equatable {
        case use(UInt16)
        case scan(knownExplicit: ExplicitPortIdentity?)
    }

    static func afterCandidateProbe(candidate: UInt16, explicit: UInt16?,
                                    identity: ExplicitPortIdentity) -> CandidateProbeOutcome {
        if identity == .confirmedMatch { return .use(candidate) }
        return .scan(knownExplicit: candidate == explicit ? identity : nil)
    }

    /// 明示 port の直接確認で「別の udid」と確定したときの文面(MN-51.6)。scan 経由の同種の食い違い
    /// (`reconcilePort` 第2 guard)とトーンは揃えるが、ここでは udidPorts が空(scan が何も
    /// 見つけていない)ので「その udid の他の応答ポート一覧」は出さず、確かめた1件だけを示す
    static func explicitPortMismatchMessage(port: UInt16, udid: String, actualUDID: String) -> String {
        "port \(port) is not a bridge answering on udid \(udid) — it answered as a different device"
            + " (udid \(actualUDID)). Pass only one of port/udid, or use the port and udid that"
            + " belong to the same device"
    }

    /// `reconcilePort` が「応答したポートが1本も無い」ときに使う追加事実。**IO は呼び出し側
    /// (`udidBridgeDiagnosis`)が集め、ここへは値として渡す** —— reconcilePort 自体は
    /// 走査を伴わない純粋関数のまま保つ(変異テストが踏んだ理由と同じ)
    struct UDIDBridgeDiagnosis: Equatable, Sendable {
        /// LISTEN しているが `/status` がタイムアウト上限まで無応答(= 本当に busy の根拠。
        /// `BridgeDiscovery.StatusProbe.timedOut`)。空なら「本当に居ない」
        let listeningButUnresponsive: [UInt16]
        /// その udid を今使っている run の pid(`RunLease.holderPID`。`markDeviceInUse` と
        /// 同じ台帳・同じ鍵)。分かれば文面に添える
        let heldByRunPID: Int32?
        /// `bridge up` の完成コマンドを組むための実体判定(`SimulatorCatalog.lookupUDID(udid:)`
        /// = ft_list_devices と同じ経路)の4値。**`.notFound`(一覧を読めたが載っていない)と
        /// `.unreadable`(一覧そのものが読めなかった)を混同しない** —— 混同すると、
        /// 負荷下で simctl がタイムアウトしただけの回を「そのデバイスは存在しない」と断定する
        let lookup: SimulatorCatalog.UDIDLookup
        /// LISTEN しているが `/status` への接続がタイムアウトよりはるかに早く応答無しで切れた
        /// (= ブリッジが消えて転送役(実機なら iproxy)だけ残っている根拠。
        /// `BridgeDiscovery.StatusProbe.transportFailed`)。**既定 `[]`**(既存呼び出し元・
        /// 既存テストの3引数の形をそのまま通すため末尾に置く。デフォルト値付きプロパティは
        /// 合成 memberwise init で省略可能なパラメータになるのは **`var` のときだけ** ——
        /// 既定値つきの `let` は memberwise init から丸ごと外れて渡せなくなる)
        var wedgedPorts: [UInt16] = []
        /// **診断そのものが確定したか**(MN-51.6)。`false`(既定)= この値の他の欄
        /// (空の `listeningButUnresponsive`/`wedgedPorts`)は「確かめて本当に空だった」ことを表す。
        /// `true` = 予算超過で診断を最後まで走らせられず、他の欄は「集まらなかった」だけで
        /// 空になっている ——  この区別が無いと、時間切れの結果が①〜④のどの分岐にも当たらず
        /// 「no running bridge」(= 本当に居ない)へ黙って落ち、生きたブリッジに `bridge up` を
        /// 勧めて2本目を起動させかけた。**`var` + 既定値**(`wedgedPorts` と同じ理由: 合成
        /// memberwise init で省略可能にするため `let` にしない)
        var timedOut: Bool = false
        /// 走査には載らなかったが、診断の probe には `/status` が答えたポート(= busy から戻った生きた
        /// ブリッジの可能性)。**本人確認できなかった分だけを残す**(確認できた分は `portForIOS` が採用し、
        /// 別の udid を名乗った分は捨てる)。非空なら「居ない」とは言わない
        var answeredPorts: [UInt16] = []
        /// 無応答で待受しているが、持ち主が背面の in-app ブリッジ(ランナーではない)と台帳から分かるポート。
        /// `listeningButUnresponsive` へは入れない(XCUITest のランナーは居ない = 起動し直してよい側)
        var backgroundedInAppPorts: [UInt16] = []

        /// 診断を呼ばなかった(必要が無かった)ときの既定。**`timedOut` は `false`** ——
        /// `reconcilePort` の default 引数・省略呼び出しのテストがこの値を「診断していない」
        /// 意味で使っており、その経路は今までどおり「no running bridge」の文面に落ちる
        static let unknown = UDIDBridgeDiagnosis(
            listeningButUnresponsive: [], heldByRunPID: nil, lookup: .unreadable("diagnosis timed out"))

        /// 実際に診断(`udidBridgeDiagnosis`)を試みたが、予算(`udidBridgeDiagnosisBudget`)内に
        /// 終わらなかったときの値。`.unknown` と違い `timedOut: true` を立てるので、
        /// `noResponsiveBridgeMessage` はこれを「居ない」とは読まず `bridgeDiagnosisUnconfirmedMessage`
        /// へ回す
        static let diagnosisTimedOut = UDIDBridgeDiagnosis(
            listeningButUnresponsive: [], heldByRunPID: nil,
            lookup: .unreadable("diagnosis timed out"), timedOut: true)
    }

    /// `udidBridgeDiagnosis` が確かめる候補ポートの上限。**実機実測**: 全ポート範囲(最大32本)へ
    /// `PortHolder.describe`(`lsof` を毎回起こす同期ブロッキング)を `withTaskGroup` で同時に
    /// 撃つと、Swift の協調スレッドプールのワーカーを synchronous な `DispatchSemaphore.wait`
    /// (`Shell.run` → `ProcessExitWait.prepareTimed`)で埋め尽くし、`ft_status` を含む
    /// MCP プロセス全体が200秒以上前進できなくなる
    /// (CLAUDE.md「協調スレッドプールにブロッキングを載せない」— `PipeLinePump`/専用スレッドの
    /// 規律と同じ話)。**lsof は一切起こさず**、候補ポートは台帳から絞る
    /// (`candidatePorts`)。台帳が壊れて候補が異常に多くても、確かめるのはここまで
    /// (`BridgeDiscovery.isBound` 1回 300ms 上限 × この件数で worst case を秒単位に収める)
    static let maxUDIDBridgeCandidatePorts = 4

    /// `udidBridgeDiagnosis` の全体(`ps` / `simctl` / 必要なら `devicectl` / probe)に掛ける
    /// 上限。根拠: `candidatePorts` 内の `ps` は数十 ms、`SimulatorCatalog.lookupUDID` は通常
    /// `xcrun simctl list` の数百 ms で終わるが、udid がシミュレータ一覧に無いと
    /// `IOSPhysicalDeviceCatalog.devices()` = `xcrun devicectl list devices`(timeout 30 秒)まで
    /// 引く。probe(`BridgeDiscovery.probeStatus`。isBound 300ms 上限 + `udidProbeTimeoutSeconds`)は
    /// 候補上限本まで**並列**に撃つので、直列合算ではなく1回ぶんだけ足で乗る。
    /// **この 30 秒をそのまま `ft_status`(対話的な口)へ持ち込まない** —— 尽きたら
    /// `UDIDBridgeDiagnosis.diagnosisTimedOut`(= 完走できなかった。`.unknown` とは別の値 —— MN-51.6)
    /// へ落とす。診断自体は打ち切らず走り続ける(`TaskBudget.run` と同じ立場: 諦めるのは
    /// 待つことだけ)
    static let udidBridgeDiagnosisBudget: Duration = .seconds(3)

    /// probe 1回(`BridgeDiscovery.probeStatus`)の窓。**scan の既定(2秒)より短くする** ——
    /// 候補上限本まで並列に撃つとはいえ、`ps`/`simctl`/`devicectl` の残り予算
    /// (`udidBridgeDiagnosisBudget`)を圧迫しないため。判別に使う実測(~2.5ms。
    /// `BridgeDiscovery.transportFailureFraction` のコメント参照)との比では 1 秒でも
    /// busy/wedged の判別に十分な余裕がある
    static let udidProbeTimeoutSeconds: Double = 1

    /// `udidPorts` が空だったときの追加調査(IO)。**lsof は一切起こさない**(上の doc 参照)。
    /// 候補ポートは台帳から絞り(`candidatePorts`。プロセスを起こすのは中の `ps` 1回だけ)、
    /// LISTEN と `/status` の両方の判定は `BridgeDiscovery.probeStatus`(生ソケットの connect+poll +
    /// 非ブロッキングな `/status` の await。`iosConnectionLostHint` の busy/wedged 判定と同じ部品)を
    /// 候補上限本まで**並列**に撃って行う。
    /// run の使用中は `RunLease.holderPID`(`markDeviceInUse` と同じ台帳)、
    /// 実体判定は `SimulatorCatalog.lookupUDID(udid:)`(ft_list_devices と同じ経路。読み取り失敗も
    /// `.unreadable` として運び、「載っていない」と混同しない)をそのまま使う。
    ///
    /// **台帳走査(ps/simctl/devicectl)だけを専用 Thread(`runOffCooperativePool`)へ逃がし
    /// (`udidBridgeDiagnosisBlocking`)、probe は通常の async 文脈で `withTaskGroup` により
    /// 並列に撃つ**(`probedUDIDBridgeDiagnosis`)—— `BridgeDiscovery.probeStatus` 内の `isBound` は
    /// 300ms 止まりの短い同期呼び出しで、候補上限(`maxUDIDBridgeCandidatePorts`)本までなら
    /// 協調スレッドプールを塞いでも許容範囲(`iosConnectionLostHint` も同じ部品を1回だけ直接
    /// 呼んでいる)。**`udidBridgeDiagnosisBlocking` は丸ごと同期**(`await` を1つも持たない) ——
    /// これを async 関数の本体に直に書くと、`Shell.run` の完了待ち(`DispatchSemaphore.wait`。
    /// 真のスレッドブロッキング)が Swift の協調スレッドプールのワーカーをそのまま占有する
    /// (この関数は一度 lsof の並列版でこれを踏んでいる。本数を減らすだけでは同じ性質が残る)。
    /// `TaskBudget.run` が `udidBridgeDiagnosisBudget` で
    /// 両段(台帳走査 + probe)の合計へ上限を掛ける
    /// (CLAUDE.md「協調スレッドプールにブロッキングを載せない」)
    static func udidBridgeDiagnosis(udid: String) async -> UDIDBridgeDiagnosis {
        let outcome = await TaskBudget.run(Self.udidBridgeDiagnosisBudget) {
            await Self.probedUDIDBridgeDiagnosis(udid: udid)
        }
        guard case .value(let value) = outcome else { return .diagnosisTimedOut }
        return value
    }

    /// `udidBridgeDiagnosis` の本体(2段)。①台帳走査(同期・専用 Thread)②候補ポートへの
    /// probe(async・並列)。呼び手(`udidBridgeDiagnosis`)の `TaskBudget.run` が両段の合計を
    /// 上限で打ち切る
    private static func probedUDIDBridgeDiagnosis(udid: String) async -> UDIDBridgeDiagnosis {
        let repoRoot = try? RepoRoot.find()
        // 台帳走査は `budgeted`(= TaskBudget + 専用 Thread)を通す。**呼び手の
        // `TaskBudget.run` と二重に見えるが、こちらを外すと `budgeted` が production から
        // 1度も呼ばれなくなり、その予算のテストが自分自身しか確かめなくなる**
        let candidates = await Self.budgeted(
            Self.udidBridgeDiagnosisBudget,
            fallback: UDIDDiagnosisCandidates(ports: [], heldByRunPID: nil,
                                              lookup: .unreadable("diagnosis timed out"), timedOut: true)) {
            Self.udidBridgeDiagnosisBlocking(udid: udid, repoRoot: repoRoot)
        }
        guard !candidates.ports.isEmpty else {
            return UDIDBridgeDiagnosis(listeningButUnresponsive: [],
                                       heldByRunPID: candidates.heldByRunPID, lookup: candidates.lookup,
                                       timedOut: candidates.timedOut)
        }
        let probes = await withTaskGroup(of: (UInt16, BridgeDiscovery.StatusProbe).self) { group in
            for port in candidates.ports {
                group.addTask {
                    (port, await BridgeDiscovery.probeStatus(
                        port: port, repoRoot: repoRoot, timeoutSeconds: Self.udidProbeTimeoutSeconds))
                }
            }
            var result: [UInt16: BridgeDiscovery.StatusProbe] = [:]
            for await (port, probe) in group { result[port] = probe }
            return result
        }
        // 無応答の待受のうち、in-app ブリッジの台帳だけが残るポートは**背面へ回ったアプリ**(前の run の残り等)で、
        // XCUITest のランナーではない。busy と読むと、ランナーが居ないのに「待て・bridge up は打つな」を言い続け、
        // 自動の起動し直しも門で止まる
        let silent = candidates.ports.filter { probes[$0] == .timedOut }
        let backgrounded = silent.filter { Self.isBackgroundedInAppBridgeOnly(port: $0, repoRoot: repoRoot) }
        return UDIDBridgeDiagnosis(
            listeningButUnresponsive: silent.filter { !backgrounded.contains($0) },
            heldByRunPID: candidates.heldByRunPID, lookup: candidates.lookup,
            wedgedPorts: candidates.ports.filter { probes[$0] == .transportFailed },
            answeredPorts: candidates.ports.filter { probes[$0] == .answered },
            backgroundedInAppPorts: backgrounded)
    }

    /// このポートの持ち主が in-app ブリッジだけか(`.inapp` の台帳があり、xcodebuild の `.pid` が生きていない)。
    /// 生きた `.pid` があればランナーが居る(busy でありうる)ので false
    static func isBackgroundedInAppBridgeOnly(port: UInt16, repoRoot: URL?) -> Bool {
        guard let repoRoot else { return false }
        let inapp = InAppBridgeState.url(stateDir: repoRoot.appendingPathComponent(".fleetest"), port: port)
        guard FileManager.default.fileExists(atPath: inapp.path) else { return false }
        return bridgeOwnerAlive(port: port, repoRoot: repoRoot) != true
    }

    /// `probedUDIDBridgeDiagnosis` が専用 Thread で集める材料(候補ポート・run 保持者・実体判定)
    private struct UDIDDiagnosisCandidates: Sendable {
        let ports: [UInt16]
        let heldByRunPID: Int32?
        let lookup: SimulatorCatalog.UDIDLookup
        /// **台帳走査そのものが予算超過で打ち切られたか**(既定 `false`)。`true` のときは
        /// `ports` が空でも「候補が無かった」ではなく「集められなかった」——
        /// `UDIDBridgeDiagnosis.timedOut` へそのまま運ぶ
        var timedOut: Bool = false
    }

    /// `udidBridgeDiagnosis` の同期本体。**`await` を書かない**(上の doc 参照)。
    /// LISTEN と `/status` の判定は行わない —— それは probe(async)へ一本化し、
    /// ここは候補ポートを集めるだけにする
    private static func udidBridgeDiagnosisBlocking(
        udid: String, repoRoot: URL?
    ) -> UDIDDiagnosisCandidates {
        let candidates = Self.cappedCandidatePorts(
            Array(Self.candidatePorts(forUDID: udid, repoRoot: repoRoot)))
        let heldByRunPID = repoRoot.flatMap {
            RunLease.holderPID(stateDir: $0.appendingPathComponent(".fleetest"), key: udid)
        }
        return UDIDDiagnosisCandidates(ports: candidates, heldByRunPID: heldByRunPID,
                                       lookup: SimulatorCatalog.lookupUDID(udid: udid))
    }

    /// 同期の仕事(`work`)を専用 Thread で実行し、`budget` 以内に返らなければ `fallback` を返す。
    /// **仕事はそのまま走り続ける**(打ち切らない・キャンセルしない) —— `FTCore.TaskBudget` と
    /// 同じ立場で、諦めた後に本当に終わるまでの時間を測り直す機構は持たない。
    /// **`udidBridgeDiagnosis` のテストはここへ時間のかかるダミー work を注入する**:
    /// 実際の `ps`/`simctl`/`devicectl` を1つも起こさずに「上限超過 → 既定へ落ちる」を固定できる
    static func budgeted<T: Sendable>(
        _ budget: Duration, fallback: T, _ work: @escaping @Sendable () -> T
    ) async -> T {
        let outcome = await TaskBudget.run(budget) {
            await Self.runOffCooperativePool(name: "fleetest-mcp-budgeted-diagnosis", work)
        }
        guard case .value(let value) = outcome else { return fallback }
        return value
    }

    /// 協調スレッドプールを塞がない同期実行の器。**専用 Thread**(`FTCore.RegionText
    /// .modelCompileOnce` / `HostMetricsSampler` / `ParentDeathWatch.arm` と同じ作法)を起こし、
    /// `work` の戻り値を継続で1回だけ渡す。`work` は真にブロッキングな同期処理(`Shell.run` 等)を
    /// 置いてよい場所 —— ここより外(呼び出し元の async 文脈)では絶対に直呼びしない
    static func runOffCooperativePool<T: Sendable>(
        name: String, _ work: @escaping @Sendable () -> T
    ) async -> T {
        await BlockingWork.offPool(name: name, work)
    }

    /// `candidatePorts` の結果に上限を掛ける(純粋関数・テスト用)。昇順にしてから切るので
    /// **上限を超えたときに確かめるのは常にポート番号の小さい側**(呼び出しごとに違う集合を
    /// 拾って結果が揺れるのを避ける)
    static func cappedCandidatePorts(_ candidates: [UInt16]) -> [UInt16] {
        Array(candidates.sorted().prefix(maxUDIDBridgeCandidatePorts))
    }

    /// この udid に紐づく可能性のあるポート(台帳由来)。**プロセスを起こすのは
    /// `BridgeLauncher.portsByUDID` の中の `ps` 1回だけ**(ポート数ぶん起こさない。lsof は
    /// 起こさない)。
    /// - xcuitest(実機も含む。実機も xcodebuild が `-destination id=<UDID>` を渡すので同じ経路):
    ///   `.pid` 台帳 + `ps` の照合(provision の「同一デバイスに2本目を立てない」判定と同じ経路)。
    /// - in-app: dylib 注入で別プロセス管理をしないため `.pid` を持たない。`.inapp` 台帳を直接読む
    ///   (`InAppBridgeState.write` の契約 = 「udid bundleID [digest]」を1行・空白区切り、の先頭語)。
    ///   `read` は FTBridgeClient 内部専用で fleetest-mcp からは呼べないため、ここでは udid の
    ///   1語だけを自前で取り出す(読むだけで FTBridgeClient は変更しない)
    static func candidatePorts(forUDID udid: String, repoRoot: URL?) -> Set<UInt16> {
        guard let repoRoot else { return [] }
        var ports = Set(BridgeLauncher.portsByUDID([udid], repoRoot: repoRoot)[udid] ?? [])
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil) else { return ports }
        for entry in entries where entry.lastPathComponent.hasPrefix("bridge-")
            && entry.pathExtension == "inapp" {
            guard let port = UInt16(entry.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "bridge-", with: "")),
                  let content = try? String(contentsOf: entry, encoding: .utf8),
                  content.split(separator: " ").first.map(String.init) == udid else { continue }
            ports.insert(port)
        }
        return ports
    }

    /// `port` と `udid` の突き合わせ。**走査から切り離した純粋関数** —— 実ブリッジが要ると
    /// 「食い違い」の枝がテストで一度も実行されず、判定を壊しても素通しする
    /// (変異テストで実際に素通しした)。
    /// **udid 側は複数ポートを許す**: 同じシミュレータに in-app / XCUITest の
    /// 2本が立つのが常態で、先頭の1本とだけ比べると正しい併記(udid + その in-app port)を
    /// 「別デバイス」と誤って拒否する(Simulator で 3/3 再現)
    static func reconcilePort(_ port: UInt16?, udid: String, udidPorts: [UInt16],
                              diagnosis: UDIDBridgeDiagnosis = .unknown) throws -> UInt16? {
        guard !udidPorts.isEmpty else {
            throw MCPError(Self.noResponsiveBridgeMessage(udid: udid, diagnosis: diagnosis))
        }
        guard let port else { return udidPorts.first }
        guard udidPorts.contains(port) else {
            let list = udidPorts.map(String.init).joined(separator: ", ")
            // **「別デバイス」と断定しない**: この分岐は「その port が udid の走査結果に無い」
            // だけで、別デバイスの port とは限らない —— 背面化した in-app ブリッジは
            // /status に答えず走査から消える(実測: Maps を launch した後の RN の in-app)
            throw MCPError("port \(port) is not a bridge answering on udid \(udid)"
                + " — it is another device's bridge, or a bridge that stopped answering"
                + " (an in-app bridge suspends when its app leaves the foreground)."
                + " Answering bridge(s) on that udid:"
                + " port \(list). Pass only udid — the server picks the bridge itself")
        }
        return port
    }

    /// `reconcilePort` が応答ポート0本のときに組む文面(純粋関数・5形固定):
    /// ①LISTEN もしていない(本当に居ない・実体を名前引きできた) ②同①だが実体を判定できない
    /// ③LISTEN しているが `/status` がタイムアウト上限まで無応答(= busy。「居ない」とは言わない)
    /// ④LISTEN しているが `/status` への接続が早期に切れる(= wedged。ブリッジが消えて転送役
    /// だけ残っている。③と事実が違うので文面も分ける)。**④を③より先に見る** ——
    /// 両方が非空になる実測は無いが、wedged は「待っても戻らない」という強い事実なので
    /// busy 側の「Retry in a moment」より優先する。
    /// ⑤診断そのものが予算内に終わらなかった(`timedOut`。MN-51.6)。①〜④は
    /// すべて「診断が完走した」上での分岐なので、**timedOut を全部より先に見る** —— 完走して
    /// いない回は busy/wedged の判定材料(probe の結果)自体が集まっていないので、空の
    /// `listeningButUnresponsive`/`wedgedPorts` を「本当に空だった」と読むと、確かめていない
    /// のに「居ない・bridge up しろ」を言うことになる(実際にこれで、明示 port が生きている
    /// 実機ブリッジへ2本目の起動を勧めかけた)
    static func noResponsiveBridgeMessage(udid: String, diagnosis: UDIDBridgeDiagnosis) -> String {
        guard !diagnosis.timedOut else {
            return Self.bridgeDiagnosisUnconfirmedMessage(udid: udid)
        }
        guard diagnosis.answeredPorts.isEmpty else {
            return Self.bridgeAnsweredUnconfirmedMessage(udid: udid, ports: diagnosis.answeredPorts)
        }
        guard diagnosis.wedgedPorts.isEmpty else {
            return Self.bridgeWedgedOnUDIDMessage(udid: udid, diagnosis: diagnosis)
        }
        guard diagnosis.listeningButUnresponsive.isEmpty else {
            return Self.bridgeBusyOnUDIDMessage(udid: udid, diagnosis: diagnosis)
        }
        let background = diagnosis.backgroundedInAppPorts.isEmpty ? "" : " (port"
            + (diagnosis.backgroundedInAppPorts.count == 1 ? " " : "s ")
            + diagnosis.backgroundedInAppPorts.map(String.init).joined(separator: ", ")
            + " is held by an app's in-app bridge that is not answering — not an XCUITest runner)"
        return "no running bridge is on udid \(udid).\(background)\(BridgeRecoveryFailureLedger.note(key: udid))"
            + " ft_list_devices shows which devices have one;"
            + " \(Self.bridgeUpSuggestion(udid: udid, lookup: diagnosis.lookup))"
            + " (a device without a bridge cannot be driven from MCP)"
    }

    /// 診断の probe には答えたが本人確認(udid)ができなかったときの文面。**「居ない」と断定せず
    /// `bridge up` も勧めない**(答えた = 何かが生きている。2本目を起動させない)
    static func bridgeAnsweredUnconfirmedMessage(udid: String, ports: [UInt16]) -> String {
        let list = ports.map(String.init).joined(separator: ", ")
        return "a bridge recorded for udid \(udid) answered on port \(list), but which device it serves"
            + " could not be confirmed right now (the Mac or the device may be busy)."
            + " This does not mean the bridge is gone, and `fleetest bridge up` is not suggested;"
            + " retry the call in a moment."
    }

    /// 診断(`udidBridgeDiagnosis`)自体が予算内に終わらなかったときの文面(MN-51.6)。**「居ない」と
    /// 断定せず `bridge up` も勧めない** —— ①〜④のどの事実も集められていないので、確かめられた
    /// のは「確かめられなかった」ことだけ。生きているブリッジへ2本目を起動させる案内を誤って出さない
    static func bridgeDiagnosisUnconfirmedMessage(udid: String) -> String {
        "could not confirm whether a bridge for udid \(udid) is running — the diagnosis did not"
            + " finish within its time budget (the Mac or the device may be busy right now)."
            + " This does not mean the bridge is gone, and `fleetest bridge up` is not suggested;"
            + " retry the call in a moment."
    }

    /// `bridge up` の完成コマンド(純粋関数)。**udid は名前より優先して解決される**
    /// (`SimulatorCatalog.resolve` — シミュレータなら `--device "<udid>"` がそのまま通り、
    /// 名前引き・同名複数台の曖昧さを迂回できる)。**実機は `--physical` を明示しないと
    /// 通らない** —— 実機 UDID は `bridge up` の「36 文字・ダッシュ5分割」形状判定に一致しない
    /// ため、`--physical` を付けなければシミュレータ名の文字列として名前引きされ必ず失敗する。
    /// **判定できないとき(`.notFound`/`.unreadable`)は嘘のコマンドを書かない** ——
    /// virtual/physical のどちらを付けるべきか断定できないので、確認の手順だけを返す。
    /// **`.notFound`(一覧は読めたが載っていない)と `.unreadable`(一覧を読めなかった)は文面を分ける**
    /// —— 後者を前者と同じ文言にすると、simctl がタイムアウトしただけの回を
    /// 「そのデバイスは存在しない」と読者に断定させる(実測: 高負荷下の5.3秒応答時に発生)
    static func bridgeUpSuggestion(udid: String, lookup: SimulatorCatalog.UDIDLookup) -> String {
        switch lookup {
        case .simulator:
            return "start it with `fleetest bridge up --device \"\(udid)\"`"
        case .physical:
            return "start it with `fleetest bridge up --device \"\(udid)\" --physical`"
        case .notFound:
            return "no exact start command can be offered (that udid is not currently listed as"
                + " either a simulator or a physical device) — check ft_list_devices for its current"
                + " udid, then run `fleetest bridge up --device \"<udid>\"` for a simulator, or add"
                + " `--physical` for a physical device"
        case .unreadable(let reason):
            return "could not read the simulator/physical device lists (\(reason)), so no exact"
                + " start command can be offered — check ft_list_devices for its current udid, then"
                + " run `fleetest bridge up --device \"<udid>\"` for a simulator, or add `--physical`"
                + " for a physical device"
        }
    }

    /// LISTEN はしているが `/status` に答えなかったときの文面(純粋関数)。**「居ない」とは
    /// 言わない**(`BridgeDiscovery.busyMessage` と同じ立場。あちらは port 指定済みの再接続
    /// 専用なので、udid 解決の入口にはこちらが要る)。**`bridge up` は勧めない** ——
    /// 本当にどこにも居ないと確かめられたときだけの案内なので、ここで勧めると同じ機に
    /// 2本目を起動させる
    static func bridgeBusyOnUDIDMessage(udid: String, diagnosis: UDIDBridgeDiagnosis) -> String {
        let ports = diagnosis.listeningButUnresponsive.map { "port \($0)" }.joined(separator: ", ")
        var message = "a bridge for udid \(udid) is listening on \(ports) but did not answer"
            + " /status within the scan window — it may be busy with another request (XCUITest can"
            + " block the bridge for tens of seconds while waiting for the screen to settle)."
        if let heldByRunPID = diagnosis.heldByRunPID {
            message += " A fleetest run (pid \(heldByRunPID)) is using this device right now, which"
                + " is the likely cause."
        }
        message += " Retry in a moment; `fleetest bridge up` is for a device with no bridge at all"
            + " and would start a second one on this device."
        if diagnosis.lookup == .physical {
            // 固まったトンネルは接続が通るのに応答が無く、busy と見分けられない(所要時間では決められない)
            message += " If it does not clear after a minute, the USB tunnel itself may be stuck:"
                + " `fleetest bridge down --port \(diagnosis.listeningButUnresponsive[0]) --force` stops it, and"
                + " `fleetest bridge up --device \"\(udid)\" --physical` starts a fresh one."
        }
        return message
    }

    /// LISTEN しているが `/status` への接続が早期に(タイムアウトよりはるかに早く)切れたときの
    /// 文面(純粋関数)。`bridgeBusyOnUDIDMessage` とは事実が違う —— busy はタイムアウト上限まで
    /// 応答を保持するが、こちらは接続が即座に失敗する(実測は
    /// `BridgeDiscovery.transportFailureFraction` のコメント参照)。**「busy」とは言わない**
    /// —— 待っても戻らない。**`bridge up` は勧めてよい** —— `bridgeBusyOnUDIDMessage` が
    /// 勧めない理由(「生きているブリッジに2本目を起動させる」)はここでは成り立たない:
    /// 転送(実機なら iproxy)は生きていてもブリッジ本体は既に消えている
    static func bridgeWedgedOnUDIDMessage(udid: String, diagnosis: UDIDBridgeDiagnosis) -> String {
        let ports = diagnosis.wedgedPorts.map { "port \($0)" }.joined(separator: ", ")
        var message = "a bridge for udid \(udid) is listening on \(ports), but the connection to"
            + " /status fails almost immediately instead of timing out — the bridge process is gone;"
            + " only its transport (on a physical device, iproxy) is still holding the port."
            + " This will not recover on its own. On a physical device, this typically follows the"
            + " screen locking, or the device leaving USB/network range."
        if let heldByRunPID = diagnosis.heldByRunPID {
            message += " A fleetest run (pid \(heldByRunPID)) is using this device right now."
        }
        message += " \(Self.bridgeUpSuggestion(udid: udid, lookup: diagnosis.lookup))"
        return message
    }

    /// udid を申告している稼働中ブリッジのポート(走査順・全部)。**申告が無いブリッジ(旧版)は
    /// 素通し** —— 「見つからない」と「そのブリッジは答えられない」を混ぜないため。
    /// **scan の応答をそのまま濾すだけ**: scan は全ポートへ並列 timeout 2s で
    /// 既に status を撃っており、その StatusResponse は udid を含む(BridgeDTO.swift)
    static func bridgePorts(forUDID udid: String) async -> [UInt16] {
        explorationOrder(await BridgeDiscovery.scan(excluding: 0, repoRoot: try? RepoRoot.find())
            .filter { $0.udid == udid })
    }

    /// udid だけの呼び出しが使うポートの順(先頭が採られる)。**XCUITest を先に置く**(MCP の iOS は常に XCUITest =
    /// ユーザー決定)。in-app のポートを採っても ExploreDriverResolver が同じデバイスの XCUITest へ振り替えるが、
    /// 先に XCUITest を採れば振り替えの走査(XCUIBridgeResolver)を払わずに済む
    static func explorationOrder(_ found: [BridgeDiscovery.Found]) -> [UInt16] {
        found.filter { $0.bridge != "inapp" }.map(\.port) + found.filter { $0.bridge == "inapp" }.map(\.port)
    }
}
