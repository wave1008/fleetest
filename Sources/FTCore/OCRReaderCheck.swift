// doctor / ft_doctor の OCR 確認の判定(文言は呼び手ごと)。
//
// **サンドボックスの中では、正常な Mac でも OCR が何も読めないことがある**(実測: `sandbox-exec` で mach 接続か
// ~/Library への書き込みを塞ぐと、その実行ファイルの認識器のコンパイルが `e5rt_e5_compiler_compile call failed` で
// 落ちて読めない。外で1回読ませてキャッシュができた後は中でも読める = 中の結果は故障の証拠にも健全の証拠にもならない)。エージェントのシェルのサンドボックスで doctor を撃つとこの形になり、❌ と
// 「再起動で戻った」を出すと利用者に不要な再起動をさせた。判定は「このプロセスがサンドボックスの中か」
// (`ProcessSandbox`)だけで決める —— Vision のエラー文言では分けない(書式が変わると黙って壊れる)。

import Darwin
import Foundation

public enum OCRReaderCheck: Equatable, Sendable {
    /// macOS が対応していない(故障ではない)
    case unsupported
    case alive
    /// サンドボックスの外で読めなかった = 読み手の故障
    case dead
    /// サンドボックスの中で読めなかった = この結果からは判定できない(❌ に数えない)
    case undeterminedInSandbox

    /// 純粋関数。`alive` は対応しているときだけ意味を持つ
    public static func verdict(supported: Bool, alive: Bool, sandboxed: Bool) -> OCRReaderCheck {
        guard supported else { return .unsupported }
        if alive { return .alive }
        return sandboxed ? .undeterminedInSandbox : .dead
    }

    /// 実際に埋め込みの絵を読ませて判定する(非対応なら撃たない)
    public static func run() async -> OCRReaderCheck {
        guard OCRSupport.isSupported else { return .unsupported }
        let alive = await RegionText.readerIsAlive()
        return verdict(supported: true, alive: alive, sandboxed: alive ? false : ProcessSandbox.isSandboxed)
    }
}

public enum ProcessSandbox {
    /// このプロセスが Seatbelt(`sandbox-exec`・アプリのサンドボックス)の中か。
    /// `sandbox_check(pid, nil, 0)` は中で 1・外で 0(sandbox.h は SDK に無いので dlsym で引く)。
    /// 引けなければ false = 従来どおりの ❌ に倒す(誤って「判定できない」と黙らせない)
    public static var isSandboxed: Bool {
        typealias SandboxCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return false }
        return unsafeBitCast(symbol, to: SandboxCheck.self)(getpid(), nil, 0) == 1
    }
}
