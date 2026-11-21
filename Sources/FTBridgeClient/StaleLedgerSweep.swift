// StaleLedgerSweep.swift
// 供給の入口で掃除する台帳の判定(呼び手は BridgeProvisioner.sweepStaleLedgers)

import Foundation
import FTCore

/// 台帳(.pid/.inapp/.endpoint/.device)1ポートぶんの掃除判定(純粋関数。実 FS/lsof は呼び手が渡す)。
/// **実測**: 誰も LISTEN していない .inapp と、対になる .pid が無い .endpoint/.device が
/// 手元に残っていた。前者は assignPort に「使用中」と誤認されてポートが飛ばされ、後者は
/// DriverOptions.makeDriver(Sources/fleetest/Fleetest.swift)が古い宛先へ接続しに行く原因になる。
enum StaleLedgerSweep {
    enum Ledger: Hashable, Sendable { case pid, inapp, endpoint, device }

    /// `.toolchain`(BridgeToolchainLedger)を消すか。**Ledger には入れない** —— あれは
    /// 「対の台帳が揃っているか」の判定で、こちらの基準は**そのポートのブリッジが生きているか**の
    /// 1点だけ。**残すのは生きているときだけ**(reuse 判定がこれを読むので、消し忘れると死んだ
    /// ブリッジの指紋がいつまでも一致し続け、版の違うブリッジを再利用してしまう)
    static func toolchainIsOrphan(hasToolchain: Bool, hasPid: Bool, inappListening: Bool) -> Bool {
        hasToolchain && !(hasPid || inappListening)
    }

    /// `.ready`(BridgeReadyLedger)を消すか。**同じ理由で `Ledger` に入れない** ——
    /// 判定基準は「そのポートのランナーが生きているか」の1点だけ。**消し忘れると**、
    /// 死んだランナーの跡地に立った**別の**ランナーが「前にも ready だった」と誤って読め、
    /// sweepStuckStartingRunners が本物の stuck ランナーを見逃す(逆方向の安全側なので
    /// toolchain ほど有害ではないが、掃除が効かなくなる点は同じ)
    static func readyIsOrphan(hasReady: Bool, hasPid: Bool, inappListening: Bool) -> Bool {
        hasReady && !(hasPid || inappListening)
    }

    struct Inputs {
        let hasPid: Bool
        /// hasPid が true のときだけ意味を持つ
        let pidAlive: Bool
        let hasInApp: Bool
        /// hasInApp が true のときだけ意味を持つ。**`/status` 応答の有無で判定しない** ——
        /// 背面に回った in-app ブリッジは TCP は受けるが HTTP に無応答なので、応答の有無は
        /// 生死の根拠にならない(CLAUDE.md「ブリッジを起動する前に…」の規律)。呼び手は
        /// PortHolder の LISTEN 実体確認(lsof)を渡すこと
        let inappListening: Bool
        let hasEndpoint: Bool
        let hasDevice: Bool
    }

    /// - .pid: 生きていれば .pid/.endpoint/.device すべて残す。死んでいれば
    ///   .pid と .endpoint/.device(実機ランナーの到達先記録)を削除する
    /// - .inapp: .pid の有無と独立に判定する(in-app ブリッジは pid ファイルを持たない)。
    ///   LISTEN していなければ削除、していれば残す
    /// - .endpoint/.device: そのポートのブリッジ(.pid の生きたランナー、または待受している in-app)が無いときは削除する。
    ///   **実機の in-app ブリッジは .pid を持たず .inapp + .endpoint(token)+ .device を持つ** —— .pid だけを見ると、別の供給の
    ///   掃除が稼働中の実機 in-app の token を消し、シナリオの起こし直し(token を台帳から読む)が全部落ちる(実測)
    static func decide(_ inputs: Inputs) -> Set<Ledger> {
        var stale: Set<Ledger> = []
        if inputs.hasPid, !inputs.pidAlive { stale.insert(.pid) }
        let bridgeAlive = (inputs.hasPid && inputs.pidAlive) || (inputs.hasInApp && inputs.inappListening)
        if !bridgeAlive {
            if inputs.hasEndpoint { stale.insert(.endpoint) }
            if inputs.hasDevice { stale.insert(.device) }
        }
        if inputs.hasInApp, !inputs.inappListening {
            stale.insert(.inapp)
        }
        return stale
    }

    /// **起動しきれないまま生き続けているランナーを止める**。
    /// 起動した側のプロセスが消えると(拡張は応答の無い `api live serve` を kill→respawn する)、
    /// `xcodebuild` は**宛先が用意できるのを永久に待つ**("Run Destination Preflight: Waiting for
    /// the destination to become ready")。ロックされた実機のように二度と用意できない宛先だと、
    /// 試行のたびに1本ずつ積み上がり、ポート・DerivedData・CPU を握ったまま誰も片付けない
    /// (実地の負荷テスト: 同じ実機向けのランナーが **10 本**溜まり、
    /// トンネルの残骸と合わせて採番の窓 32 ポートを埋め尽くした)。
    ///
    /// 判定は既存の `StartingRunnerVerdict.decide` をそのまま使う(二つ目の実装を書かない):
    /// **待受していない**(= まだ何も提供していない)かつ **生存が起動予算を超えている**かつ
    /// **起動ログが予算ぶん伸びていない**ときだけ止める —— 起動中のブリッジはログが伸び続けるので
    /// 巻き込まない。**busy なブリッジは待受している**ので最初の条件で外れる。
    ///
    /// **elapsed/quietFor だけでは足りない**(実地: 55 分サービス済みのブリッジが負荷下で
    /// 誤って止められた)—— 長寿ブリッジは elapsed が予算を超え続けるのが普通で、quietFor も
    /// xcodebuild の出力がブロックバッファされるため、リクエストの合間は「ログが伸びていない」
    /// と読める。区別するのは3つ: **①一度でも ready(BridgeReadyLedger)を確認していれば
    /// 対象外**(elapsed/quietFor と違って腐らない一次証拠)。**②`refused`(誰も居ないと
    /// 確定)のときだけ進む** —— `BridgeDiscovery.isBound` の 300ms 待ちは timeout/unknown も
    /// false に畳むため、負荷下で busy な(=生きている)リスナーを「居ない」と誤読しうる。
    /// 破壊的な判定はここだけ `connectProbe` の3値を直接見る(`isBound` の他の呼び手の意味は
    /// 変えない)。**③宛先のデバイスに生きた run/MCP セッションがあれば触らない**
    static func sweepStuckStartingRunners(repoRoot: URL, log: (String) -> Void = { _ in }) {
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("bridge-")
            && entry.pathExtension == "pid" {
            guard let port = UInt16(entry.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "bridge-", with: "")),
                let pidText = try? String(contentsOf: entry, encoding: .utf8),
                let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
                // isOurRunner(pid:port:) と同じ ps 呼び出しだが、宛先(RunnerDestination)の
                // 照合にも同じ出力を使い回すため1回だけ自前で撃つ
                let ps = try? Shell.run(["ps", "-ww", "-p", String(pid), "-o", "command="]),
                ps.status == 0, BridgeLauncher.isOurRunner(command: ps.output, port: port)
                else { continue }
            let readyMarked = BridgeReadyLedger.isMarked(stateDir: stateDir, port: port, pid: pid)
            let connect = BridgeDiscovery.connectProbe(port: port, repoRoot: repoRoot)
            let destinationHeld = RunnerDestination.udid(inCommand: ps.output).map {
                RunLease.holderPID(stateDir: stateDir, key: $0) != nil
                    || MCPDeviceLease.holderPID(stateDir: stateDir, key: $0, excluding: []) != nil
            } ?? false
            // physical は DerivedData の別だけで決まる(stop() は kind で分岐しない)ので false でよい
            let launcher = BridgeLauncher(repoRoot: repoRoot, port: port, physical: false)
            let verdict = StartingRunnerVerdict.decide(
                elapsed: launcher.runnerElapsed(), quietFor: launcher.logQuietFor(),
                budget: BridgeLauncher.startupTimeoutSeconds)
            guard shouldReapStuckRunner(readyMarked: readyMarked, connect: connect,
                                        destinationHeld: destinationHeld, verdict: verdict) else {
                if destinationHeld, !readyMarked, connect == .refused {
                    log("🔧 left the runner on port \(port) alone — its device has an active run or MCP session")
                }
                continue
            }
            guard BridgeLauncher.reapRunnerProcess(pid: pid) else { continue }
            try? FileManager.default.removeItem(at: entry)
            log("🔧 stopped a runner on port \(port) that never became ready"
                + " (it was still waiting for its destination)")
        }
    }

    /// 起動しきれないランナーを止めてよいか(純粋関数)。**4つとも揃ったときだけ** —— 一度でも
    /// ready になった(`.ready` の台帳)・待受が拒否でない(時間切れは busy の可能性 = 不明)・
    /// 宛先のデバイスに run/MCP の印がある、のどれかがあれば止めない
    static func shouldReapStuckRunner(readyMarked: Bool, connect: BridgeDiscovery.ConnectProbe,
                                      destinationHeld: Bool, verdict: StartingRunnerVerdict) -> Bool {
        !readyMarked && connect == .refused && !destinationHeld && verdict == .restart
    }

    /// **ブリッジを失ったトンネルを止める**(`iproxy-<port>.pid` の掃除とは別物)。
    /// 実機の起動が途中で落ちる・起動した側のプロセスが kill される(拡張は応答の無い
    /// `api live serve` を kill→respawn する)と、**トンネルだけがポートを握ったまま残る**。
    /// 台帳も残らない形があり(`stopIproxy` は pid ファイルを消してからでも殺し損ねる)、
    /// そうなると誰も片付けられないまま採番の窓(32 ポート)を1つずつ食い潰す ——
    /// 実地の負荷テストで窓が埋まり `--broadcast` が `no free port` で全滅した。
    ///
    /// 対象は**ブリッジの台帳が1つも無いポートで、占有者がトンネルだけ、かつその宛先のランナーが
    /// この機械に居ない**とき(`PortHolder.stopOrphanedTunnelHolder`)。台帳はクローンごとなので、
    /// 台帳が無いだけでは別のクローンが起動した生きたブリッジと区別できない。起動中のブリッジは `.pid` を**トンネルより先に**
    /// 書く(`executeBridge` / `LiveBridgeAutoStarter.launchBridge` とも startDetached → establish の順)
    /// ので、進行中の起動を巻き込まない
    static func sweepTunnelOnlyPorts(portRange: ClosedRange<UInt16>, stateDir: URL,
                                     log: (String) -> Void = { _ in }) {
        for port in portRange {
            let pidPath = stateDir.appendingPathComponent("bridge-\(port).pid")
            let inappPath = InAppBridgeState.url(stateDir: stateDir, port: port)
            // **待受を先に見る**(非ブロッキング connect。誰も居なければトンネルも居ない)——
            // 占有者の照合は lsof + ps で**1ポートあたり約 0.2 秒**かかり、窓の 32 ポートを
            // 素で撃つと**この掃除だけで約 6 秒**。ここは ProvisionLock の内側(供給の入口)なので、
            // 待たせるのは自分の run ではなく**次にポートを採りたい別プロセス**になる
            guard !FileManager.default.fileExists(atPath: pidPath.path),
                  !FileManager.default.fileExists(atPath: inappPath.path),
                  BridgeDiscovery.isBound(port: port, repoRoot: nil),
                  PortHolder.stopOrphanedTunnelHolder(port: port) else { continue }
            log("🔧 stopped a leftover USB tunnel on port \(port) (its bridge is gone)")
        }
    }

    /// `.fleetest/iproxy-<port>.pid`(実機 USB トンネル。IOSDeviceTransport.startIproxy が書く)の
    /// 掃除。**bridge-<port>.* とは別の台帳**で、上の decide/ここまでのループには乗らない —— 生死を
    /// 確かめる呼び手(IOSDeviceTransport.isIproxyRunning)は実際にそのポート・UDID を使う run
    /// でしか呼ばれないため、物理デバイスを使わない run を挟むと死んだ pid がいつまでも残る
    /// (F27 実測: iproxy-8136/8138/8150.pid が死んだ pid のまま残留)。**UDID は見ない**
    /// (どの UDID 向けだったかに関わらず死んでいれば消す。生きていれば別 UDID 向けでも
    /// 触らない = isIproxyRunning が実際に使う際の張り替えに任せる)。生存判定は pid だけ
    /// (ProcessLiveness.isAlive。素の kill(pid,0) は禁止)
    static func sweepIproxyPidFiles(stateDir: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("iproxy-")
            && entry.pathExtension == "pid" {
            guard let text = try? String(contentsOf: entry, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ProcessLiveness.isAlive(pid) else {
                try? FileManager.default.removeItem(at: entry)
                continue
            }
        }
    }
}
