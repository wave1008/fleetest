// RunLockWire.swift
// run 全体のロック(RR-8.5)の通り道の定義: 受け渡しの行の「ロックの扱い」・unix ソケットの上の1行1メッセージの JSON・キーの検査。
// サーバー = RunLockServer.swift / クライアント = RunLockClient.swift / 判定 = RunLockTable.swift。
// **親子の `ftWork` の行には載せない**(行が欠けても「届いたか」が正しさを決める用途なので、信頼できるストリームだけを通る)。

import Foundation

/// 子がロックをどう扱うか(`DeviceSessionHandoff.lockAccess`。必須の欄)
public enum RunLockAccess: Codable, Sendable, Equatable {
    /// このパスの unix ソケットへつないで答えをもらう
    case socket(String)
    /// その場で渡す(他と競合しない起動: beforeRun / afterRun・debug 実行。MCP は同時に走りうるのでプロジェクトごとのサーバーを持つ)
    case immediate
    /// 取らずに本体を通す(dry-run)
    case passThrough
    /// 呼んだら英語の理由で失敗する(ソケットを渡されない起動)
    case refuse(String)
}

/// クライアント → サーバー と サーバー → クライアント。`id` は接続の中の要求番号(クライアントが振る)
public enum RunLockMessage: Codable, Equatable, Sendable {
    // クライアント → サーバー
    /// `token`: 受け渡しの行の `lockOwnerToken`(この起動の印。親が適用した外のメモ操作の数え・メモの持ち主をこれで引く)
    case hello(scenario: String, machine: String, device: String, token: String)
    case acquire(id: Int, keys: [String])
    case cancel(id: Int)
    case release(id: Int)
    /// `outsideOps`: このシナリオがロックの外で出した run メモの操作(runMemoWrite + runMemoClear のイベント)の数。
    /// サーバーは親が同じ数を適用し終えてから答える(外の書き込みは stdout のイベントで非同期に届くので、待たないと
    /// 自分の外の書き込みを読み落とす・後から届いて中の書き込みを上書きする)
    case memoRead(id: Int, outsideOps: Int)
    case memoWrite(id: Int, op: RunLockMemoOp, outsideOps: Int)
    /// 子(発行元とつながったローカルの子プロセス。シナリオのプロセスではない)から発行元のサーバーへ:
    /// 起動の印 `token` のシナリオがロックの外で出した run メモの操作1件が、**発行元の正本(hub)に確定した**。
    /// サーバーは `memoRead` / `memoWrite` の前に、クライアントが出した数だけ届くまで待つ(プロセスをまたぐ `outsideOps` の順序)
    case outsideApplied(token: String)
    /// 子(マシンの親)から: `token` のシナリオのプロセスを**親が見届けた**(reap した)。サーバーはその印の持ち分を外し、待ちを消す
    /// (リモートのシナリオが臨界区間の中で死んでも、ssh が生きている間は持ち主不明を作らない)
    case scenarioEnded(token: String)
    /// 中継役(`run --runner <機>` の ssh の親。発行元の手元のプロセス)から、**手元の待ち受けへ**: そのディスパッチの ssh が終わった。
    /// `listener` = そのディスパッチのリモートの待ち受けのパス(ディスパッチの識別子)。サーバーはその待ち受けで受けた残りの持ち分を持ち主不明にして `unknownKeys` を返す(繰り返してよい = 数の照会にも使う)
    case sshEnded(listener: String)
    /// 中継役から: そのディスパッチの向こうの run が終わったと確かめた。サーバーはその待ち受けの持ち主不明だけを外し、印を付ける
    case remoteRunEnded(listener: String)
    // サーバー → クライアント
    /// 中継役から、手元の待ち受けへ: そのディスパッチの待ちの和集合の累計(`RunLockWaitUnion`)を知りたい
    case waitedQuery(listener: String)
    /// `waitedQuery` への返事(ミリ秒)
    case waited(listener: String, ms: Int)
    /// `sshEnded` / `remoteRunEnded` への返事: そのディスパッチの持ち主不明のキーの数(0 = 確かめ直しは要らない)
    /// `capSeconds` = ロックの待ちの絶対上限(中継役が確かめ直しの上限を決める材料)
    /// `othersActive` = 発行元にこのディスパッチ以外の動いている仕事(走っている・まだ起こしていない子)が残っているか。
    /// false なら不明のキーを待てる者は居ないので、中継役は確かめ直しをやめる(発行元の終わりを遅らせない)
    case unknownKeys(listener: String, count: Int, capSeconds: Int, othersActive: Bool)
    /// 渡し。**印のあるキー**(持ち主不明から外した = 前の持ち主の書き込みが欠けているかもしれない)を含むときはこちら
    case grantedAfterLoss(id: Int, keys: [String])
    /// run メモの読み書きが、親が適用し終えていない「ロックの外の操作」を待っている(クライアントは待ちの窓を開く)。
    /// 続けて結果(`memo` / `committed` / `failed`)が来る
    case pending(id: Int)
    /// すぐには渡せず待ち行列に入った(クライアントはこれを受けたときだけ待ちの窓を開く)
    case queued(id: Int)
    case granted(id: Int)
    case failed(id: Int, reason: String)
    case memo(values: [String: [String]])
    /// `seq` = 発行元の正本が振った通し番号(正本が無い構成は nil)
    case committed(id: Int, seq: Int?)

    public func encodedLine() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func decode(line: Data) -> RunLockMessage? {
        try? JSONDecoder().decode(RunLockMessage.self, from: line)
    }
}

public enum RunLockMemoOp: Codable, Equatable, Sendable {
    case write(key: String, value: String)
    case clear

    public init(_ op: RunMemoOp) {
        switch op {
        case .write(let key, let value): self = .write(key: key, value: value)
        case .clear: self = .clear
        }
    }

    public var runMemoOp: RunMemoOp {
        switch self {
        case .write(let key, let value): return .write(key: key, value: value)
        case .clear: return .clear
        }
    }
}

public enum RunLockLimits {
    /// 1メッセージの上限の目安。run メモ1件の上限(`RunMemoWire.maxPieces` × 断片 ≈ 1.4 MB の base64 の元の値)の JSON と、
    /// 読みの返事(全キーの履歴)が収まる大きさ。超えた行は壊れた接続として切る(メモリを際限なく食わない)
    public static let maxLineBytes = 64 << 20
}

/// キーの検査と正規化(呼んだ時点で行う。エラー文言は英語)
public enum RunLockKeys {
    /// 検査して、**UTF-8 のバイト列の順**に並べ、バイト列が同じものの重複を除いて返す。
    /// 並べ方は Swift の `String` の比較(Unicode の正規化に依る = 版の違うマシンの間で順番が割れうる)を使わない。
    /// キーの長さと個数に上限を置かない(根拠が無い。キーは端末を通る行に載らず、ソケットの1行は `maxLineBytes` が止める。DR-210)
    public static func normalize(_ keys: [String]) -> Result<[String], RunLockError> {
        guard !keys.isEmpty else { return .failure(RunLockError("at least one lock key is required")) }
        var seen = Set<[UInt8]>()
        var unique: [String] = []
        for key in keys {
            if TextNormalization.isBlank(key) {
                return .failure(RunLockError("a lock key must not be blank"))
            }
            if key.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                return .failure(RunLockError("a lock key must not contain control characters (got \(displayName(key)))"))
            }
            if seen.insert(Array(key.utf8)).inserted { unique.append(key) }
        }
        return .success(unique.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
    }

    /// キーを文言・ステップの説明に出すときの形。制御文字は `\u{..}` にする(そのまま出すと行が割れる。検査の前のキーも通る)
    public static func displayName(_ key: String) -> String {
        key.unicodeScalars.map { $0.properties.generalCategory == .control ? String(format: "\\u{%02X}", $0.value) : String($0) }.joined()
    }
}

public struct RunLockError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// 1行1メッセージのストリームの読み手。**1回の read で次の行の頭まで読んでしまうので、読み手は接続ごとに1つ持って使い回す**
/// (読み捨てると次のメッセージが欠ける)。読むスレッドは1つだけ
final class RunLockLineChannel: @unchecked Sendable {
    enum Read: Equatable {
        case line(Data)
        case timeout
        /// 閉じた・壊れた(上限超え・読み取りエラー)
        case closed
    }

    private let descriptor: Int32
    // 不変条件: buffer は読むスレッドだけが触る
    private var buffer = Data()

    init(descriptor: Int32) { self.descriptor = descriptor }

    /// `timeoutMs` < 0 = 来るまで待つ・0 = 今あるものだけ
    func readLine(timeoutMs: Int32) -> Read {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return .line(line)
            }
            if buffer.count > RunLockLimits.maxLineBytes { return .closed }
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, timeoutMs)
            if ready < 0 {
                if errno == EINTR { continue }
                return .closed
            }
            if ready == 0 { return .timeout }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .closed
            }
            if count == 0 { return .closed }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    /// 全部書く(途中で止まったら false)。呼び手が書き込みを直列にする
    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
