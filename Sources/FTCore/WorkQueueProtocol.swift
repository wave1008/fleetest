// マシンをまたぐ run の親子の間でシナリオを1本ずつ配る口(`--work-queue`。RR-8.1)。
// 子の stdout へ要求を1行、親から子の stdin へ返事を1行。どちらも `{"ftWork":{...}}` の1行 JSON。
// ssh -tt を通る(端末の行規律に載る)ので、1行は短く保つ(シナリオ ID 1つ)・改行を含めない。
// 同じ口に run メモ(DR-208)の行も載る: 子 → 親は `memoHello`(起動の知らせ)と `memo`(書き込みの断片。seq 無し)、
// 親 → 子は `memo`(発行元が通し番号 seq を振って全マシンへ配り返す断片)。符号化は RunMemoStore.swift の RunMemoWire。
// 対象外(DR-214): 子 → 親 `na`(機械の中に回し直す先が無かった対象外のシナリオを、他のマシンの未試行の台へ回せるかの問い合わせ)と、
// 親 → 子の返事 `verdict`(hand / skip / fail。判定は NotApplicableHandoff.decide)。親子は常に同じ版(align)なので互換の読み替えは置かない。
// 子 → 親 `kept`(返事なし): 親が配った単位を機械の中の別の台へ回し直し始めた(`on: true`)・その回し直しが終わった(`on: false`)。
// 親は配った単位を「そのレーンの次の要求」で忘れるので、これが無いと回し直し中の単位を知らず、他のマシンの尽きたレーンを終わらせる
// (後で対象外が親へ届いたとき、未試行の台が「落ちた」と読まれて赤になる)。
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

    /// 子 → 親。対象外で終わった単位(`id` × `variant`)を、機械の外の未試行の台へ回せるかの問い合わせ。
    /// `dep` = 子の中で試していない台が落ちている(親の判定の「落ちた台」に足す)。理由の文は運ばない(行を短く保つ。子が持っている)
    public struct NotApplicable: Codable, Equatable, Sendable {
        public let op: String
        public let req: Int
        public let id: String
        /// 単位のバリアント(バリアントの無い run では行に載らない)
        public let variant: String?
        public let lane: String
        public let platform: String
        public let dep: Bool
        /// 子の中でこの単位を試して対象外と答えた台で観測した種類(DR-214。iOS の Simulator だけ)。**省略 = 観測していない**(覆わない)。
        /// 親はこれだけを「その種類で試した」証拠にする(プロファイルを引き直した種類は、子が実際に使った台と限らない)
        public let kinds: [String]?

        /// 載せる種類の上限。超えたら載せない(= 観測していない扱い。遅くなるだけで誤らない)。根拠: 1種類 約 25 バイト、行は約 1024 バイトまで
        public static let maxKinds = 8

        public init(req: Int, unit: ScenarioUnitKey, lane: String, platform: String, dep: Bool, kinds: Set<String>) {
            self.op = "na"
            self.req = req
            self.id = unit.id
            self.variant = unit.variant
            self.lane = lane
            self.platform = platform
            self.dep = dep
            self.kinds = kinds.isEmpty || kinds.count > Self.maxKinds ? nil : kinds.sorted()
        }

        public var unit: ScenarioUnitKey { ScenarioUnitKey(id: id, variant: variant) }
    }

    /// 子 → 親(返事なし)。配られた単位を機械の中で回し直している最中か(DR-214。ファイル冒頭)
    public struct Kept: Codable, Equatable, Sendable {
        public let op: String
        public let id: String
        /// 単位のバリアント(バリアントの無い run では行に載らない)
        public let variant: String?
        public let on: Bool

        public init(unit: ScenarioUnitKey, on: Bool) {
            self.op = "kept"
            self.id = unit.id
            self.variant = unit.variant
            self.on = on
        }

        public var unit: ScenarioUnitKey { ScenarioUnitKey(id: id, variant: variant) }
    }

    /// 親 → 子(stdin)。`id` が無く `none == true` = もう無い。`again == true` = 手元を見直して聞き直す(`PullAnswer.recheck`)。
    /// `verdict` = `na` への返事(`NotApplicableHandoff.Verdict.wire`)
    public struct Reply: Codable, Equatable, Sendable {
        public let req: Int
        public let id: String?
        /// 配る単位のバリアント(バリアントの無い run では行に載らない)
        public let variant: String?
        public let none: Bool?
        public let again: Bool?
        public let verdict: String?

        public init(req: Int, unit: ScenarioUnitKey) {
            self.req = req
            self.id = unit.id
            self.variant = unit.variant
            self.none = nil
            self.again = nil
            self.verdict = nil
        }

        public init(req: Int, none: Bool) {
            self.req = req
            self.id = nil
            self.variant = nil
            self.none = none ? true : nil
            self.again = nil
            self.verdict = nil
        }

        public init(req: Int, again: Bool) {
            self.req = req
            self.id = nil
            self.variant = nil
            self.none = nil
            self.again = again ? true : nil
            self.verdict = nil
        }

        public init(req: Int, verdict: NotApplicableHandoff.Verdict) {
            self.req = req
            self.id = nil
            self.variant = nil
            self.none = nil
            self.again = nil
            self.verdict = verdict.wire
        }

        /// 配る単位(ID × バリアント)。「もう無い」・壊れた返事は nil
        public var unit: ScenarioUnitKey? { id.map { ScenarioUnitKey(id: $0, variant: variant) } }
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

    /// 取りやめの理由の最大文字数(読みやすさの上限。行の長さの保証は `maxStartLineBytes` が持つ)
    public static let maxCancelReasonCharacters = 200

    /// 開始・取りやめの1行の最大バイト数。根拠: ssh -tt の先の子の stdin は端末の行規律(canonical)で、1行が約 1024 バイトを超えると
    /// 改行まで捨てられ、子が開始の合図を受け取れずに待ち続ける。文字数では足りない(結合した絵文字は1字 25 バイト前後・
    /// 制御文字は JSON で `\u001b` の6バイト)ので、符号化した行のバイト数で切る
    public static let maxStartLineBytes = 900

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
    public static func encode(_ na: NotApplicable) -> String { encodeBody(na) }
    public static func encode(_ kept: Kept) -> String { encodeBody(kept) }
    public static func encode(_ piece: MemoPiece) -> String { encodeBody(piece) }
    public static func encode(_ hello: MemoHello) -> String { encodeBody(hello) }

    /// 開始・取りやめの行。理由は改行・制御文字(Cc だけ。`CharacterSet.controlCharacters` は書式文字 Cf も含み、ZWJ でつないだ絵文字を
    /// 丸ごと消す)を空白に直して `maxCancelReasonCharacters` で切り、さらに行が
    /// `maxStartLineBytes` に収まるまで末尾から削る(空なら "cancelled")
    public static func encode(_ signal: StartSignal) -> String {
        switch signal {
        case .start:
            return encodeBody(StartBody(op: "start", reason: nil))
        case .cancel(let reason):
            var flat = Array(reason.map { character -> Character in
                character.isNewline || character.unicodeScalars.contains { $0.properties.generalCategory == .control } ? " " : character
            }.prefix(maxCancelReasonCharacters))
            while true {
                let trimmed = String(flat).trimmingCharacters(in: .whitespaces)
                let line = encodeBody(StartBody(op: "cancel", reason: trimmed.isEmpty ? "cancelled" : trimmed))
                if line.utf8.count <= maxStartLineBytes || flat.isEmpty { return line }
                flat.removeLast()
            }
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

    public static func decodeNotApplicable(_ line: String) -> NotApplicable? {
        guard isWorkLine(line), let na = decodeBody(NotApplicable.self, line), na.op == "na" else { return nil }
        return na
    }

    public static func decodeKept(_ line: String) -> Kept? {
        guard isWorkLine(line), let kept = decodeBody(Kept.self, line), kept.op == "kept" else { return nil }
        return kept
    }

    /// `want` の行・他の JSON は nil(req が無い返事は返事として読まない)
    public static func decodeReply(_ line: String) -> Reply? {
        guard isWorkLine(line), let reply = decodeBody(Reply.self, line),
              reply.id != nil || reply.none == true || reply.again == true || reply.verdict != nil else { return nil }
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
