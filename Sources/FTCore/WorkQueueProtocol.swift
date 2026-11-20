// マシンをまたぐ run の親子の間でシナリオを1本ずつ配る口(`--work-queue`。RR-8.1)。
// 子の stdout へ要求を1行、親から子の stdin へ返事を1行。どちらも `{"ftWork":{...}}` の1行 JSON。
// ssh -tt を通る(端末の行規律に載る)ので、1行は短く保つ(シナリオ ID 1つ)・改行を含めない。
// 同じ口に run メモ(DR-208)の行も載る: 子 → 親は `memoHello`(起動の知らせ)と `memo`(書き込みの断片。seq 無し)、
// 親 → 子は `memo`(発行元が通し番号 seq を振って全マシンへ配り返す断片)。符号化は RunMemoStore.swift の RunMemoWire。
// 親 → 子にはもう1種類: 開始の行 `{"ftWork":{"op":"start"}}` と取りやめの行 `{"ftWork":{"op":"cancel","reason":"…"}}`(RR-8.4)。
// 子は開始の行を受けるまでシナリオを流し始めない(StartGate)。

import Foundation

public enum WorkQueueProtocol {
    /// 子 → 親(stdout)。`lane` = `RunWorker.logicalName`
    public struct Want: Codable, Equatable, Sendable {
        public let op: String
        public let req: Int
        public let lane: String
        public let platform: String

        public init(req: Int, lane: String, platform: String) {
            self.op = "want"
            self.req = req
            self.lane = lane
            self.platform = platform
        }
    }

    /// 親 → 子(stdin)。`id` が無く `none == true` = もう無い
    public struct Reply: Codable, Equatable, Sendable {
        public let req: Int
        public let id: String?
        public let none: Bool?

        public init(req: Int, id: String) {
            self.req = req
            self.id = id
            self.none = nil
        }

        public init(req: Int, none: Bool) {
            self.req = req
            self.id = nil
            self.none = none ? true : nil
        }

        /// 配るシナリオ ID。「もう無い」・壊れた返事は nil
        public var scenarioID: String? { id }
    }

    /// run メモの書き込み1件の断片(RunMemoWire)。`seq` は発行元が配り返す行にだけ付く。`src` + `lid` = 書いたプロセスの印と
    /// そのプロセスでの書き込み番号、`i` / `n` = 断片の番号と総数、`d` = base64 の断片
    public struct MemoPiece: Codable, Equatable, Sendable {
        public let op: String
        public let src: String
        public let lid: Int
        public let seq: Int?
        public let i: Int
        public let n: Int
        public let d: String

        public init(src: String, lid: Int, seq: Int?, i: Int, n: Int, d: String) {
            self.op = "memo"
            self.src = src
            self.lid = lid
            self.seq = seq
            self.i = i
            self.n = n
            self.d = d
        }
    }

    /// 子 → 親。起動の知らせ(親はそれまでの run メモの履歴をこの子へ送る)
    public struct MemoHello: Codable, Equatable, Sendable {
        public let op: String
        public let src: String

        public init(src: String) {
            self.op = "memoHello"
            self.src = src
        }
    }

    /// 親 → 子。子がシナリオを流し始めてよいか(`start`)、1本も流さずに終わるか(`cancel` + 理由)
    public enum StartSignal: Equatable, Sendable {
        case start
        case cancel(reason: String)
    }

    /// 取りやめの理由の最大文字数。根拠: 1行は ssh -tt の行規律の約 1024 バイトに収める(日本語など3バイト文字で 3 倍・印と JSON の括りで約 50 バイト)
    public static let maxCancelReasonCharacters = 200

    struct StartBody: Codable, Equatable {
        let op: String
        let reason: String?
    }

    private struct Envelope<Body: Codable>: Codable { let ftWork: Body }

    /// 行の先頭の印。`isWorkLine` の判定と、中継(表示・NDJSON から抜く / 透過する)が共有する
    public static let linePrefix = "{\"ftWork\""

    public static func isWorkLine(_ line: String) -> Bool { line.hasPrefix(linePrefix) }

    public static func encode(_ want: Want) -> String { encodeBody(want) }
    public static func encode(_ reply: Reply) -> String { encodeBody(reply) }
    public static func encode(_ piece: MemoPiece) -> String { encodeBody(piece) }
    public static func encode(_ hello: MemoHello) -> String { encodeBody(hello) }

    /// 開始・取りやめの行。理由は改行を空白に直して `maxCancelReasonCharacters` で切る(空なら "cancelled")
    public static func encode(_ signal: StartSignal) -> String {
        switch signal {
        case .start:
            return encodeBody(StartBody(op: "start", reason: nil))
        case .cancel(let reason):
            let flat = String(reason.map { $0.isNewline ? " " : $0 }.prefix(maxCancelReasonCharacters))
            let trimmed = flat.trimmingCharacters(in: .whitespaces)
            return encodeBody(StartBody(op: "cancel", reason: trimmed.isEmpty ? "cancelled" : trimmed))
        }
    }

    private static func encodeBody<Body: Codable>(_ body: Body) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Envelope(ftWork: body)),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    public static func decodeWant(_ line: String) -> Want? {
        guard isWorkLine(line),
              let want = decodeBody(Want.self, line), want.op == "want" else { return nil }
        return want
    }

    /// `want` の行・他の JSON は nil(req が無い返事は返事として読まない)
    public static func decodeReply(_ line: String) -> Reply? {
        guard isWorkLine(line), let reply = decodeBody(Reply.self, line),
              reply.id != nil || reply.none == true else { return nil }
        return reply
    }

    /// `memo` 以外の行・壊れた行は nil
    public static func decodeMemoPiece(_ line: String) -> MemoPiece? {
        guard isWorkLine(line), let piece = decodeBody(MemoPiece.self, line), piece.op == "memo" else { return nil }
        return piece
    }

    public static func decodeMemoHello(_ line: String) -> MemoHello? {
        guard isWorkLine(line), let hello = decodeBody(MemoHello.self, line), hello.op == "memoHello" else { return nil }
        return hello
    }

    /// `start` / `cancel` 以外の行・壊れた行は nil
    public static func decodeStartSignal(_ line: String) -> StartSignal? {
        guard isWorkLine(line), let body = decodeBody(StartBody.self, line) else { return nil }
        switch body.op {
        case "start": return .start
        case "cancel": return .cancel(reason: body.reason ?? "cancelled")
        default: return nil
        }
    }

    private static func decodeBody<Body: Codable>(_ type: Body.Type, _ line: String) -> Body? {
        guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Envelope<Body>.self, from: data))?.ftWork
    }
}
