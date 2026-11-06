// シミュレータの SpringBoard を起こし直す。**前面のアプリと XCUITest ランナーも一緒に落ちる**(実測: マップのプロセスが消え、
// ランナーの /status が答えなくなった)ので、呼び手はランナーを作り直し、アプリを起動し直す時点でだけ撃つ。
// 呼び手は2つ: 残ったシステムアラートの3段目(`ProfileWorkerFactory.respringAndRebuild`)と、劣化したランナーの回復
// (`BridgeProvisioner.restartRunner`)。SpringBoard の劣化(`/systemalert` の1問が 3.5s 前後)はランナーの起動し直しでは
// 直らず、SpringBoard の起こし直しで 0.11〜0.18s に戻った(実測・起こし直し約 8s)

import Foundation

public enum SimulatorSpringBoard {

    /// 撃つコマンド(テストが形を固定する)。`system/` は非推奨の警告を出すが動く(exit 0。実測)
    public static func command(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "launchctl", "kickstart", "-k", "system/com.apple.SpringBoard"]
    }

    /// `restart` の時間切れ(秒)。根拠: 起こし直しは約 8s(実測)で、遅い機械でもその数倍に収まる。
    /// 尽きたら simctl を子ごと止めて失敗とし、detail に時間切れと言う
    static let restartTimeoutSeconds: Double = 30

    /// 起こし直す。**終了コードで成否を返す**(Shell.run は非ゼロで投げない)。detail は失敗の末尾
    public static func restart(udid: String) -> (ok: Bool, detail: String) {
        do {
            let result = try Shell.run(command(udid: udid), timeout: restartTimeoutSeconds)
            return (result.status == 0, result.tail)
        } catch {
            return (false, failureDetail(error))
        }
    }

    /// 撃てなかった理由。時間切れ(子を止めた)と、撃てなかった(起動の失敗など)を分けて言う
    public static func failureDetail(_ error: Error) -> String {
        if case ShellError.timedOut(_, let seconds) = error {
            return "simctl did not finish within \(Int(seconds))s (killed)"
        }
        return "simctl did not run: \(error.localizedDescription)"
    }
}
