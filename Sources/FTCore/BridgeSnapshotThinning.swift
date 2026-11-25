// BridgeDTO.swift から分割した純粋ロジック(焦点の着地判定・座標タップの対象選び・snapshot の間引き・keptDepth の材料)。
// BridgeDTO.swift と同じく in-app dylib と XCUITest ランナーへ直接コンパイルされるため、Foundation 以外に依存しない
// (一覧は BridgeSourceSet.swift・InAppBridge/build.sh・Runner の project.xcproj の3か所)。

import Foundation

/// ref 指定の type / clear で、タップ後の受け口(first responder)が**叩いた要素のもの**か。
/// **ブリッジと共有する純粋関数**(in-app ブリッジの `requireFocusMoved` が使う)。
/// - **面積のある受け口**(UIKit・Compose): 叩いた点を含むか。枠で見ないのは、大きい容器を叩いたときに
///   中の前の欄を「叩いた先」と取り違えるため
/// - **面積の無い受け口**(Flutter の 1×1pt。欄の編集領域の左上に置かれ、叩いた点を含むことが原理的に無い。
///   実測: 受け口 (16,310 1x1)・欄 (16,298 370x48)・叩いた中心 (201,322)): 叩いた要素の枠の中にあるか。
///   **叩いたのが入力欄でない(容器)なら、タップの前後で受け口が動いたか、容器の中の入力欄がちょうど1つで
///   受け口がその欄の中にあることが要る** —— 前の欄を内側に含む容器(欄が2つ以上)を叩いて焦点が動かなかった形を
///   通すと、前の欄へ打って 200 を返す。欄が1つだけの包み(id を持つのが包み側)は、焦点のある欄を叩き直した形でも
///   叩いた先はその欄なので通す(`TapTargetGeometry.nonInputTypeTargetNote` と同じ「ちょうど1つ」の考え方)。
///   入力欄そのものなら叩き直し(受け口は動かない)も通す
public enum FocusLanding {
    /// `movedSinceTap` = タップの前後で受け口が別の view になったか位置が変わったか(タップ前に受け口が
    /// 無ければ true)。`target` = 叩いた要素の今の枠(取れなければ nil = 面積の無い受け口は通さない)。
    /// `soleInnerInput` = 叩いた要素の中の入力欄がちょうど1つならその枠(0個・2個以上は nil)
    public static func landed(receiver: CGRect, tapped: CGPoint, target: CGRect?, targetIsInput: Bool,
                              movedSinceTap: Bool, soleInnerInput: CGRect?) -> Bool {
        guard receiver.width <= 1 || receiver.height <= 1 else { return receiver.contains(tapped) }
        let centre = CGPoint(x: receiver.midX, y: receiver.midY)
        guard target.map({ $0.contains(centre) }) ?? false else { return false }
        return targetIsInput || movedSinceTap || (soleInnerInput?.contains(centre) ?? false)
    }
}

extension FocusLanding {
    /// 同じ要素と見なす枠の差(pt)。in-app の取り直しが id 無しの要素を同定する許容(frame ±2pt)と同じ
    static let sameElementFrameTolerance: CGFloat = 2

    /// ref 付きの type / clear が、打つ前の欄への合成タップを省くか。直前の tap(または同じ欄を空にできた ref 付きの clear =
    /// replace の前段)がこの欄へ焦点を立てていて(`priorTapLanded`)いま受け口がある(`receiverPresent`)ときだけ省く。
    /// 受け口が無い(キーボードが閉じた等)なら叩いて焦点を取り直す。CMP は焦点のある欄の2度目のタップで編集メニュー(Select All)を出して残す
    public static func skipsRetapBeforeText(priorTapLanded: Bool, receiverPresent: Bool) -> Bool {
        priorTapLanded && receiverPresent
    }

    /// 直前の ref の tap の記録(`priorTapLanded` の材料)を、この要求の前に残すか。残すのは読むだけの要求(GET)・記録を作る `/tap`・
    /// 記録を使う `/type` `/clear`(ref の無い打鍵・消去は呼び手が捨てる)だけ。それ以外(pressEnter・hideKeyboard・払い 等)は焦点を
    /// 動かしうるので捨てる = 次の type / clear は欄を叩き直す(残すと、pressEnter で焦点が次の欄へ移った後の clearInput が
    /// 叩き直さずに次の欄を消して ok を返した)
    public static func keepsPriorTapRecord(method: String, path: String) -> Bool {
        method == "GET" || path == "/tap" || path == "/type" || path == "/clear"
    }

    /// **直前の ref の tap が、いま叩き直している欄へ焦点を立てていたか**(`landed` を通さずに焦点の着地とする)。
    /// 叩き直しは焦点のある欄を叩くので受け口が動かない。Flutter の値入りの欄は木で `other`(入力欄と申告されない)・
    /// 木の枠は欄の実際の箱より小さく下にずれ(実測 E2EX-Flutter: 木 (16,271 370x10)・受け口は箱の左上 (16,249))、
    /// 受け口は動かない 1x1 なので、枠への包含でも「動いたか」でも着地と読めず、`tap(A); tap(B); type("x")` の救済が
    /// 409 になった(inapp F9)。「動かなかった」だけで通すと、前の欄を内側に含む容器を叩いて焦点が動かなかった形
    /// (前の欄へ打つ)と区別できないので、次の2つが揃うときだけ true(呼び手は、その tap の後に type / clear / 別の tap を
    /// 挟んだ記録を捨てる):
    /// ①その tap の前から今までに受け口が動いた / ②いま叩き直す要素が、その tap の対象の中にある
    /// (同じ id の要素の今の枠。中身の入力欄は包みの枠に収まる)。
    /// **受け口を tap の直後に採って「それ以降動かない」とは見ない**: Flutter の焦点は tap から遅れて移る(直後に採ると
    /// まだ前の欄で、実測 6 回中 2 回が外れた)
    /// ③受け口が面積を持つ(CMP・UIKit)なら、**いまの受け口が叩き直す欄の中心を含む**。in-app から見えない経路
    /// (XCUITest で打った Enter)で焦点が次の欄へ移っても記録は残るので、①②だけだと移った先の欄を消した(OI-163 ①)。
    /// 面積の無い受け口(Flutter の 1x1)は位置で欄を指さないので見ない。含まなければ叩き直す(`focusTapPoint` が点を決める)
    /// `liveCurrent` = 叩き直す欄の今の AX の枠(面積が無ければ nil)。③は撮った時点の枠ではなくこちらと比べる
    /// (キーボードで欄が動いた後は、撮った時点の枠の中心に受け口は居ない)。無ければ撮った時点の枠で比べる
    public static func priorTapLanded(receiverMovedSinceThatTap: Bool, recordedTargetNow: CGRect?,
                                      current: CGRect?, receiverNow: CGRect?, liveCurrent: CGRect?) -> Bool {
        guard receiverMovedSinceThatTap, let target = recordedTargetNow, let current else { return false }
        let t = sameElementFrameTolerance
        guard target.insetBy(dx: -t, dy: -t).contains(current) else { return false }
        guard let receiverNow, receiverNow.width > 1, receiverNow.height > 1 else { return true }
        let field = liveCurrent ?? current
        return receiverNow.insetBy(dx: -t, dy: -t).contains(CGPoint(x: field.midX, y: field.midY))
    }

    /// 面積 0 に潰れた入力欄に焦点が立った形か: 受け口と叩いた欄の今の枠が、どちらも片辺が潰れていて同じ位置・大きさ(±`sameElementFrameTolerance`)。
    /// CMP の iOS 横向きではキーボードが出ると欄が高さ 0 へ詰められ(実測: 受け口 (78,154 718x0)・欄は木から消える)、受け口の中心が
    /// 撮った時点の枠に入らず「別の欄にある」と断っていた(焦点は立っていて、ロケータなしの type は入る)。呼び手は入力欄の ref だけに使う
    public static func receiverIsCollapsedTarget(receiver: CGRect, liveTarget: CGRect) -> Bool {
        let collapsed = { (r: CGRect) in r.width <= 1 || r.height <= 1 }
        guard collapsed(receiver), collapsed(liveTarget) else { return false }
        let t = sameElementFrameTolerance
        return abs(receiver.minX - liveTarget.minX) <= t && abs(receiver.minY - liveTarget.minY) <= t
            && abs(receiver.width - liveTarget.width) <= t && abs(receiver.height - liveTarget.height) <= t
    }

    /// 焦点を当てる合成タップの点が見えている帯として要る最小の厚み(pt)。`TapTargetGeometry.minimumVisibleTapExtent` と同じ値
    /// (in-app はこのファイルだけをコンパイルするので写す。等号は `FocusLandingPriorTapTests.testFocusTapPointAvoidsTheKeyboard` が固定)
    public static let minimumVisibleBand: CGFloat = 8

    /// type / clear が欄へ焦点を当てる合成タップの点。中心がキーボードの下なら、欄のうちキーボードより上に見えている帯
    /// (厚み `minimumVisibleBand` 以上)の中央へ寄せる。帯が無ければ nil = 撃たない(呼び手は staleRef で断り、ホストが容器を送る)。
    /// 中心のまま撃つとキーを押し、焦点のある別の欄へ打鍵が入る(CMP: Enter で焦点が次の欄へ移った後の clearInput が「か」を押した。
    /// 合成タップでもキーに当たった)。複数行の欄は上側が見えたまま中心が縁にかかる(帯を叩けば焦点は正しく立つ)
    public static func focusTapPoint(centre: CGPoint, field: CGRect, keyboard: CGRect?) -> CGPoint? {
        guard let keyboard, keyboard.contains(centre) else { return centre }
        let band = min(field.maxY, keyboard.minY) - field.minY
        guard band >= minimumVisibleBand else { return nil }
        return CGPoint(x: centre.x, y: field.minY + band / 2)
    }
}

/// 座標タップ(in-app)でどの snapshot 要素を activate するか。**ブリッジと共有する純粋関数**
/// (in-app ブリッジはこのファイルをそのままコンパイルする)。
/// 候補は **frame が点を含み、かつ見えている範囲(`clips` = 祖先のスクロール容器で切った後)にも
/// 点が入る要素**で、その中の最小面積を選ぶ。容器で切れた行は frame 上は点を含んでも描かれていない
/// (SwiftUI では行の AX ノードがホスティング view にしか辿れず、hitTest では見分けられない)ので、
/// 候補から外さないと見えない要素を撃ち抜く。clips に無い要素(祖先に容器が無い)は frame だけで判定する
public enum BridgeCoordinateTapTarget {
    public struct Choice: Equatable {
        /// activate する要素(無ければ呼び手は点へ合成タッチ)
        public let ref: Int?
        /// 点を frame に含むが容器で切れていたため外した要素のうち、**選んだ要素より小さい**もの
        /// (= 見えていれば撃たれたはずの要素。呼び手が注記で名指しする)。無ければ nil
        public let clippedRef: Int?
    }

    /// 端の端数(1/scale pt)で見えている行を落とさないための見逃し幅(pt)
    static let clipTolerance: CGFloat = 0.5

    public static func choose(point: CGPoint, frames: [Int: CGRect], clips: [Int: CGRect]) -> Choice {
        var best: (ref: Int, area: CGFloat)?
        var clipped: (ref: Int, area: CGFloat)?
        // 同じ面積なら ref の小さい方(辞書の走査順に結果を依存させない)
        func smaller(_ ref: Int, _ area: CGFloat, than current: (ref: Int, area: CGFloat)?) -> Bool {
            guard let current else { return true }
            return area < current.area || (area == current.area && ref < current.ref)
        }
        for (ref, frame) in frames where frame.contains(point) {
            let area = frame.width * frame.height
            if let clip = clips[ref],
               !clip.insetBy(dx: -clipTolerance, dy: -clipTolerance).contains(point) {
                if smaller(ref, area, than: clipped) { clipped = (ref, area) }
                continue
            }
            if smaller(ref, area, than: best) { best = (ref, area) }
        }
        let named = clipped.flatMap { c in smaller(c.ref, c.area, than: best) ? c.ref : nil }
        return Choice(ref: best?.ref, clippedRef: named)
    }
}

/// GET /snapshot が maxSnapshotElements を超えたときに何を先に捨てるかの判定。
/// **in-app dylib と XCUITest ランナーの共通実装**(BridgeSourceSet 参照)。Android は `AndroidRunner/.../SnapshotBuilder.java` の
/// `priorityTier` に個別実装 —— **こちらが正。tier0〜2 を変えたら Java 側も直す**。tier3(bulk)は iOS だけ(コーパス14本で Android は
/// 1画面も発火しなかった。出る画面を見つけたら写して VERSION_CODE を上げる)。
/// 捨てる順: tier2(それ以外)→ tier3(bulk)→ tier1(ラベル/identifier あり)→ tier0(操作可能・scrollable な容器)。同じ tier は
/// preorder の後ろから捨てる。容器そのものは indicesToKeep が tier に関係なく cap 免除する。
/// bulk の根拠: 地図の装飾ピン(同一 identifier ×90・非操作)が枠の大半を占めて本物のコンテンツ(リスト・詳細シート)を押し出した。
/// **免除は「自身がスクロール容器か」だけ** —— 祖先で免除すると、地図(スクロール容器)の中の POI がラベル付きの tier1 として
/// 木の先頭に最後まで残り、後方のカード内容から先に落ちた(実測 Apple マップ・+84 切り詰め)。リスト行のラベル群(同一 id ×20+)も
/// bulk になるが、無ラベルの装飾(tier2)が先に落ちるので本物の行が先に消えることはない
public enum BridgeSnapshotThinning {

    /// 同一 identifier の出現数がこの数以上なら bulk tier の対象候補。
    ///
    /// **「畳める群は枠も1つぶんにする」案は却下**(実装して撤回): 地図の POI が
    /// 上限の 64% を占めるのは事実だが、**同じ述語はリストの行にも当たる**(同一 id ×20 以上の
    /// 行は普通にある)。群の尾を先に落とすと、30 行のリストの 21 行目以降が
    /// **無ラベル装飾より先に**消える —— tier2 → tier3 の順序はまさにそれを防ぐために
    /// 選ばれている(下の「捨てる順序」参照)。地図 POI とリスト行を木から見分ける手掛かりは
    /// 無く、祖先ベースの区別は 58 で一度失敗している。**代わりに MCP 側が
    /// 「どの id 群が枠を食っているか」を打ち切り注記で名指しする**(MCPServer.truncationNote)
    public static let bulkGroupMinimum = 20

    /// 操作可能とみなす正規化型名(ElementInfo.normalizedType 後の綴り = ElementInfo.init が
    /// 自動で適用するので、makeInfo が返す ElementInfo.type は既にこの形)。bulk tier からは
    /// 常に除外する
    public static let operableTypes: Set<String> = [
        "button", "cell", "textField", "secureTextField", "searchField", "switch",
        "checkBox", "link", "slider", "tab", "menuItem", "clickable", "textView",
    ]

    /// 間引き判定の入力。tier/bulk 判定は info(自身のプロパティ)だけで決まる
    /// (祖先由来の情報は 58 で撤去。ElementInfo.scrollable は自身が容器かどうかの申告)
    public struct Candidate {
        public var info: ElementInfo

        public init(info: ElementInfo) {
            self.info = info
        }
    }

    /// bulk 群を予算外で送るときの安全弁。木が壊れたアプリで応答が無制限に膨らむのを防ぐ
    /// だけの値で、通常は当たらない(実測の最大は Apple マップの 87)
    public static let bulkExemptCeiling = 400

    /// 超過時に残す候補の添字を、元の配列と同じ順序(preorder)で返す。max 以下ならそのまま全添字。
    /// **並べ替えない**: RefGuard.lineage が preorder+depth からツリーを復元し、ref の大小を
    /// z-order の代理に使う。
    ///
    /// **bulk 群(tier3)は要素上限の勘定に入れない**(61): 上限は「読み手が選ぶ
    /// 対象」に使い切らせるためのもので、同一 id の飾りがその枠を食うのは上限の目的に反する。
    /// 実測(Apple マップの経路手順)では `#VKPointFeature` が保持 119 件中 87 件 = 73% を占め、
    /// 操作可能要素とラベル持ち要素がその分だけ押し出されていた。
    /// **捨てるのではなく予算から外す**ので、ref タップも SelectorInventory への記録も
    /// expandBulk の展開もそのまま効く(捨てる案は却下済み。bulkGroupMinimum のコメント参照)。
    /// 予算外にした分だけ `elements.count` は max を超え得る —— スクロール容器の cap 免除と同じ扱い
    public static func indicesToKeep(_ candidates: [Candidate], max: Int) -> [Int] {
        let n = candidates.count

        var identifierCounts: [String: Int] = [:]
        for candidate in candidates {
            guard let id = candidate.info.identifier, !id.isEmpty else { continue }
            identifierCounts[id, default: 0] += 1
        }

        var keep = [Bool](repeating: true, count: n)
        // ① bulk は予算外。天井を超えた分だけは落とす(内訳では "bulk" として申告される)
        var exempt = [Bool](repeating: false, count: n)
        var exemptCount = 0
        for index in 0..<n where isBulk(candidates[index], identifierCounts: identifierCounts) {
            if exemptCount < bulkExemptCeiling {
                exempt[index] = true
                exemptCount += 1
            } else {
                keep[index] = false
            }
        }

        // ② 上限が掛かるのは bulk 以外だけ
        var remaining = (0..<n).filter { keep[$0] && !exempt[$0] }.count
        guard remaining > max else { return (0..<n).filter { keep[$0] } }
        // tier3 は予算外になったので掃き出しの順序から外れる
        for currentTier in [2, 1, 0] {
            guard remaining > max else { break }
            for index in stride(from: n - 1, through: 0, by: -1) {
                guard remaining > max else { break }
                // スクロール容器自身は tier に関係なく cap 免除(容器が落ちると scrollFrame
                // 解決が退化する。数個しかないので実害なし)。max を僅かに超えて返ることを許容する
                guard keep[index], !exempt[index], candidates[index].info.scrollable != true,
                      tier(candidates[index], identifierCounts: identifierCounts) == currentTier
                else { continue }
                keep[index] = false
                remaining -= 1
            }
        }
        return (0..<n).filter { keep[$0] }
    }

    /// 予算外で送った bulk 要素の数(ホストが「上限の外で何件届いたか」を言うために使う)。
    /// `indicesToKeep` と**同じ判定**で数える
    public static func bulkExemptCount(_ candidates: [Candidate]) -> Int {
        var identifierCounts: [String: Int] = [:]
        for candidate in candidates {
            guard let id = candidate.info.identifier, !id.isEmpty else { continue }
            identifierCounts[id, default: 0] += 1
        }
        let bulk = candidates.filter { isBulk($0, identifierCounts: identifierCounts) }.count
        return Swift.min(bulk, bulkExemptCeiling)
    }

    /// WebView DOM マージ用の間引き。ネイティブ(間引き済み)の直後に各 webView コンテナの
    /// DOM 要素を差し込んだ合算列を作り、max 超過なら indicesToKeep と同じ優先度で捨てる。
    ///
    /// なぜ要るか(E2E-iOS の密グリッドページで実測): 従来の先着順カットは
    /// 装飾セル 115 個を残して**ページ上の操作可能要素(送信・入力欄・リンク・状態 echo)を
    /// 全部**押し出した —— iOS ネイティブ側が版54で直した形がマージ側に残っていた。
    ///
    /// bulk 判定は info.scrollable(自身のプロパティ)だけを見るので、祖先情報が失われる
    /// マージ後の flat な列でも1段目と矛盾なく再適用できる(58 より前は祖先ベースの判定で
    /// ここだけ bulk を無効化する必要があったが、その回避は不要になった)。
    public enum MergeSlot: Equatable, Sendable {
        /// base[i](ネイティブ要素)
        case base(Int)
        /// dom[container]![j](container = ネイティブ側 webView コンテナの ref)
        case dom(container: Int, index: Int)
    }

    public static func mergedSlots(base: [ElementInfo], dom: [Int: [ElementInfo]],
                                   max: Int) -> (kept: [MergeSlot], dropped: Int) {
        let (slots, candidates) = mergedCandidates(base: base, dom: dom)
        let kept = indicesToKeep(candidates, max: max)
        return (kept.map { slots[$0] }, slots.count - kept.count)
    }

    /// マージ側で捨てた分の内訳。**`mergedSlots` の戻り値は増やさない** —— 位置分解で
    /// 受けている呼び出し側とテストを巻き込むだけで、得るものが無い。組み立ては
    /// `mergedCandidates` に寄せてあるので二重定義にはならない。
    /// 呼ぶのは `dropped > 0` のときだけ(捨てていないなら走らせる意味が無い)
    public static func mergedDroppedByTier(base: [ElementInfo], dom: [Int: [ElementInfo]],
                                           max: Int) -> [String: Int] {
        let (_, candidates) = mergedCandidates(base: base, dom: dom)
        return droppedByTier(candidates, kept: indicesToKeep(candidates, max: max))
    }

    /// ネイティブ(間引き済み)の直後に各 webView コンテナの DOM 要素を差し込んだ合算列
    static func mergedCandidates(base: [ElementInfo],
                                 dom: [Int: [ElementInfo]]) -> ([MergeSlot], [Candidate]) {
        var slots: [MergeSlot] = []
        var candidates: [Candidate] = []
        for (i, info) in base.enumerated() {
            slots.append(.base(i))
            candidates.append(Candidate(info: info))
            guard let elements = dom[info.ref] else { continue }
            for (j, element) in elements.enumerated() {
                slots.append(.dom(container: info.ref, index: j))
                candidates.append(Candidate(info: element))
            }
        }
        return (slots, candidates)
    }

    /// 捨てた候補の内訳(`SnapshotResponse.truncatedTiers`)。**間引きの方針を実データで
    /// 議論するために要る** —— 件数だけでは「選べる物が消えたのか、飾りが消えただけか」を
    /// 区別できない(Apple マップの経路プランナーで 211 → 120 の 91 件脱落を
    /// 観測したが、内訳が無く原因を断定できなかった)。
    /// `kept` は indicesToKeep の戻り値(元配列の添字)
    public static func droppedByTier(_ candidates: [Candidate], kept: [Int]) -> [String: Int] {
        let keptSet = Set(kept)
        guard candidates.count > keptSet.count else { return [:] }
        var identifierCounts: [String: Int] = [:]
        for candidate in candidates {
            guard let id = candidate.info.identifier, !id.isEmpty else { continue }
            identifierCounts[id, default: 0] += 1
        }
        var result: [String: Int] = [:]
        for index in candidates.indices where !keptSet.contains(index) {
            let key = tierKey(tier(candidates[index], identifierCounts: identifierCounts))
            result[key, default: 0] += 1
        }
        return result
    }

    /// tier 番号 → `SnapshotResponse.truncatedTiers` のキー。**番号をそのまま外へ出さない**
    /// (ホストが tier の並び順を知っている必要が生まれ、順序を変えた瞬間に嘘になる)
    public static func tierKey(_ tier: Int) -> String {
        switch tier {
        case 0: return "operable"
        case 1: return "labelled"
        case 3: return "bulk"
        default: return "decoration"
        }
    }

    /// 0(高優先・最後まで残す) … 3(bulk・最初に捨てる)
    static func tier(_ candidate: Candidate, identifierCounts: [String: Int]) -> Int {
        if isBulk(candidate, identifierCounts: identifierCounts) { return 3 }
        if operableTypes.contains(candidate.info.type) || candidate.info.scrollable == true { return 0 }
        let hasText = !(candidate.info.label ?? "").isEmpty || !(candidate.info.identifier ?? "").isEmpty
        return hasText ? 1 : 2
    }

    /// bulk 判定の3条件(すべて満たすときだけ true): 同一 identifier の群が bulkGroupMinimum 以上・
    /// **自身が**スクロール容器でない(祖先ベースにしない —— 地図 POI はスクロール容器[地図]の
    /// 中に居るので素通りする)・操作可能な型でない
    private static func isBulk(_ candidate: Candidate, identifierCounts: [String: Int]) -> Bool {
        guard candidate.info.scrollable != true else { return false }
        guard let id = candidate.info.identifier, let count = identifierCounts[id],
              count >= bulkGroupMinimum else { return false }
        return !operableTypes.contains(candidate.info.type)
    }
}

extension BridgeAPI {
    /// 出す要素ごとの、**木に出した直近の祖先**の位置(`order` の中の添字。nil = 出した祖先が無い)。
    /// `parents[i]` = 集めた候補 i の直近の「集めた」祖先の添字(nil = 根)、`order` = 出す候補の添字を出す順に。
    /// 間引き・重複除きで落とした祖先は飛ばして上へ辿る。**親は子より先に `order` に現れること**(preorder なら成り立つ)
    public static func keptParents(parents: [Int?], order: [Int]) -> [Int?] {
        var position: [Int: Int] = [:]
        position.reserveCapacity(order.count)
        var out: [Int?] = []
        out.reserveCapacity(order.count)
        for (at, index) in order.enumerated() {
            var parent = parents[index]
            while let p = parent, position[p] == nil { parent = parents[p] }
            out.append(parent.flatMap { position[$0] })
            position[index] = at
        }
        return out
    }

    /// `keptParents` から `ElementInfo.keptDepth`(木に出した祖先の数)を出す
    public static func keptDepths(keptParents: [Int?]) -> [Int] {
        var depths: [Int] = []
        depths.reserveCapacity(keptParents.count)
        for parent in keptParents { depths.append(parent.map { depths[$0] + 1 } ?? 0) }
        return depths
    }

    /// Flutter のセマンティクスの容器(`SemanticsObjectContainer`。木に出ない。先頭の子が容器自身のノードで、中身はその後ろの兄弟)の
    /// 子の親を決める。in-app / XCUITest ランナーが同じ規則で `keptParents` の材料(`parent`)を作るための共有部。
    /// 先頭の子を木に出したら、後ろの兄弟はその先頭の子の中身として数える
    public struct SemanticsContainerChildren {
        public private(set) var parent: Int?
        private var tracksOwn: Bool
        /// `tracksOwn` = 容器と判定済み(ランナーは `isContainerClass` で確かめた後)
        public init(parent: Int?, tracksOwn: Bool) {
            self.parent = parent
            self.tracksOwn = tracksOwn
        }
        /// 次の子を集めるときの親。先頭の子の処理が終わると、先頭の子を出していればその添字へ変わる
        public mutating func finishedChild(isFirst: Bool, gatheredIndexIfKept: Int?) {
            guard isFirst, tracksOwn, let index = gatheredIndexIfKept else { return }
            parent = index
        }
    }

    /// 容器かどうかを本当のクラス名で問う価値のある形か。**問うのはこの形だけ**(1問い合わせ約 2ms)。
    /// 木に出さないノードの、先頭の子が子の無い other で、子が2つ以上
    public static func shouldQuerySemanticsContainer(included: Bool, childCount: Int,
                                                     firstChildIsLeafOther: Bool) -> Bool {
        !included && childCount >= 2 && firstChildIsLeafOther
    }

    /// 問いの答え(`XC_kAXXCAttributeElementType`)が Flutter のセマンティクスの容器か。nil(問いの失敗)は容器と言わない
    public static func isSemanticsContainerClass(_ name: String?) -> Bool {
        name == "SemanticsObjectContainer"
    }
}
