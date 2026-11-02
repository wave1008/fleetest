// run の実行中にライブ操作(`api live serve`)が受けた人の操作を、`HumanOperationLedger` へ残すための純粋な部分。
// 書き込みは `LiveDeviceLease.recordHumanOperation`、読み手は `ScenarioHost.run` の確定点。

import FTCore
import Foundation

enum LiveHumanOperation {
    /// 台帳へ書くか。**run がそのデバイスを使用中(`RunLease.holderPID` が自分以外の生きた pid)のときだけ**。
    /// 普段のライブ操作では台帳を育てない。自分の pid は serve 自身(lease を持つのは run のみ。取り違えの保険)
    static func shouldRecord(runHolderPID: Int32?, ownPID: Int32) -> Bool {
        guard let runHolderPID else { return false }
        return runHolderPID != ownPID
    }

    /// 英語の短い事実。**入力した文字列は含めない**(`type` は文字数だけ)。台帳に残さない命令(refresh・未知)は nil
    static func label(for command: ApiLiveServeCommand) -> String? {
        func n(_ value: Double) -> String { String(format: "%.0f", value) }
        func seconds(_ value: Double) -> String { FTSeconds.format(value) + "s" }
        func point(_ x: Double, _ y: Double) -> String { "(\(n(x)), \(n(y)))" }
        func target(_ verb: String) -> String {
            if let x = command.x, let y = command.y { return "\(verb) \(point(x, y))" }
            return verb
        }
        switch command.cmd {
        case "tap": return target("tap")
        case "doubleTap": return target("double tap")
        case "press":
            guard let x = command.x, let y = command.y else { return "long press" }
            return "long press \(point(x, y))" + (command.duration.map { " " + seconds($0) } ?? "")
        case "drag":
            guard let fx = command.fromX, let fy = command.fromY, let tx = command.toX, let ty = command.toY else {
                return "drag"
            }
            return "drag \(point(fx, fy)) → \(point(tx, ty))"
        case "pinch": return "pinch ×" + FTSeconds.format(command.scale ?? 2.0)
        case "gesture":
            let count = command.fingers?.count ?? 0
            return "gesture (\(count) finger\(count == 1 ? "" : "s"))"
        case "type":
            let count = command.text?.count ?? 0
            return "type (\(count) character\(count == 1 ? "" : "s"))"
        case "home": return "home"
        case "appSwitcher": return "app switcher"
        case "fold": return command.state == "unfold" ? "unfold" : "fold"
        default: return nil
        }
    }
}
