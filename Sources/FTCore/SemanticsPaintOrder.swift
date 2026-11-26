// Android の Flutter のアプリ(debug / profile)の VM サービスから取った「塗り順」(DR-235)。
// 同期相手: AndroidRunner/src/com/example/ftbridge/FlutterSemanticsOrder.java(POST /semanticsorder)。
// **名指しの出口(`OccluderNaming`)だけが使う**。共有の幾何(`PaintOrder` ほか DR-230 の列挙)・撃ち方・合否には使わない。
// BridgeDTO.swift に置かない: あちらは iOS のブリッジの入力(`BridgeSourceSet`)で、触ると iOS の版まで上がる

import Foundation

/// POST /semanticsorder の答え(Android ブリッジだけ)。答えられないときは `reason` だけが来る(`dump` / `nodes` は省く)
public struct SemanticsOrderResponse: Codable, Sendable, Equatable {
    public struct Node: Codable, Sendable, Equatable {
        public let ref: Int
        /// 仮想ビューの id = Flutter の `SemanticsNode.id`(flutter.jar の AccessibilityBridge が同じ番号を使う)
        public let semanticsId: Int
        /// ブリッジがその木で控えた要素の中心(px)。ホストの木と同じ木かを確かめる材料
        public let cx: Double
        public let cy: Double
        public init(ref: Int, semanticsId: Int, cx: Double, cy: Double) {
            self.ref = ref; self.semanticsId = semanticsId; self.cx = cx; self.cy = cy
        }
    }
    /// `ext.flutter.debugDumpSemanticsTreeInInverseHitTestOrder` の文字列
    public let dump: String?
    public let nodes: [Node]?
    /// 答えられない理由(語彙はブリッジ側に固定: no-snapshot / no-virtual-nodes / multiple-hosts / no-pid / no-vm-service /
    /// dump-failed / timeout / empty-dump)
    public let reason: String?
    public init(dump: String?, nodes: [Node]?, reason: String?) {
        self.dump = dump; self.nodes = nodes; self.reason = reason
    }
}

public enum FlutterSemanticsDump {
    /// semanticsId → 現れた順の番号。ダンプは前順(親 → 子・兄弟は奥 → 手前 = semantics.dart の `_childrenInHitTestOrder` の逆)
    /// なので、**後に現れたほど手前**(兄弟の部分木は丸ごと前後し、子は親より後)。同じ id が2回現れたら最初の番号
    public static func ranks(dump: String) -> [Int: Int] {
        var out: [Int: Int] = [:]
        var order = 0
        for line in dump.split(separator: "\n", omittingEmptySubsequences: true) {
            // 行頭の罫線(空白・│├└─)の後に `SemanticsNode#<id>` が来る行だけがノード。他の行は属性
            let body = line.drop(while: { $0 == " " || $0 == "│" || $0 == "├" || $0 == "└" || $0 == "─" })
            guard body.hasPrefix("SemanticsNode#") else { continue }
            let digits = body.dropFirst("SemanticsNode#".count).prefix(while: { $0.isASCII && $0.isNumber })
            guard let id = Int(digits) else { continue }
            if out[id] == nil { out[id] = order }
            order += 1
        }
        return out
    }
}

/// ref → 塗り順の番号(大きいほど手前)。作るのは `make` だけ
public struct PaintRankAnswer: Sendable, Equatable {
    public let ranks: [Int: Int]

    /// 中心の照合の許し(px)。ブリッジは `Rect.exactCenterX/Y`、ホストの枠は同じ Rect の x/y/width/height なので一致するはず。
    /// 1px は丸めの差だけを吸う幅(超えたら別の木 = 答えを捨てる)
    static let centreTolerance = 1.0

    /// 答えが無い・答えの木がホストの木と違う(どれか1つでも中心が合わない・ref が木に無い)ときは nil。ダンプに無い id の ref は載せない
    public static func make(response: SemanticsOrderResponse?, elements: [ElementInfo]) -> PaintRankAnswer? {
        guard let response, let dump = response.dump, let nodes = response.nodes, !nodes.isEmpty else { return nil }
        let byRef = Dictionary(elements.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        let order = FlutterSemanticsDump.ranks(dump: dump)
        guard !order.isEmpty else { return nil }
        var ranks: [Int: Int] = [:]
        for node in nodes {
            guard let element = byRef[node.ref],
                  abs(element.frame.centerX - node.cx) <= centreTolerance,
                  abs(element.frame.centerY - node.cy) <= centreTolerance else { return nil }
            if let rank = order[node.semanticsId] { ranks[node.ref] = rank }
        }
        return ranks.isEmpty ? nil : PaintRankAnswer(ranks: ranks)
    }

    init(ranks: [Int: Int]) { self.ranks = ranks }

    /// a が b より手前か。どちらかの番号が無ければ nil
    public func inFront(_ a: ElementInfo, of b: ElementInfo) -> Bool? {
        guard let ra = ranks[a.ref], let rb = ranks[b.ref], ra != rb else { return nil }
        return ra > rb
    }
}
