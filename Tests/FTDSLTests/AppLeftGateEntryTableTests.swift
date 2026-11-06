// 撃つ前の前面の門(StepExecutor.appLeftRefusal)を通らない入口の表。`perform`(FlowStep → StepExecutor.execute)と
// `canSelect` は門を通るが、`performCustom` は通らない。17〜25周目にこの抜けが周ごとに1つずつ見つかった
// (launchApp(url:) の後の印・back() の activate・select の「無い」側)ので、performCustom の入口を全部この表で分類する。
// 新しい performCustom を足すと落ちる = 「門を通す」か「通さない理由」を必ず書く

import XCTest

final class AppLeftGateEntryTableTests: XCTestCase {

    /// performCustom の command → 門の扱い。"gated" は本体で appLeftRefusal を呼ぶもの。それ以外は通さない理由
    static let table: [String: String] = [
        "back": "gated",
        "home": "アプリを離れる操作そのもの(撃った後に印を立てる)",
        "appSwitcher": "アプリを離れる操作そのもの(撃った後に印を立てる)",
        "tapAppIcon": "アプリへ戻る操作(ホーム画面を読む。撃った後に印を立てて前面を聞き直す)",
        "openURL": "配送はホストの外部コマンド。撃った後に印を立てる",
        "launchApp": "アプリを前面へ出す(印を落とす。url: なら配送の後に立て直す)",
        "restartApp": "アプリを前面へ出す(印を落とす)",
        "terminateApp": "アプリを止める(読まない・触らない)",
        "removeApp": "アプリを消す(読まない・触らない)",
        "installApp": "ホストの外部コマンド(読まない・触らない)",
        "clearAppData": "ホストの外部コマンド(読まない・触らない)",
        "addMedia": "ホストの外部コマンド(読まない・触らない)",
        "wait": "待つだけ",
        "appIs": "前面のアプリそのものを確かめる検証",
        "fold/unfold/hinge": "端末側の操作(StepExecutor.runsWithoutTheApp と同じ扱い)",
        "tap": "画像で見つからなかった要素の tap = 何も撃たずに必ず失敗する",
        "type": "画像で見つけた要素への type = 何も撃たずに必ず失敗する",
    ]

    func testEveryPerformCustomEntryIsClassified() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/FTDSL")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var found: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            var rest = source[...]
            while let call = rest.range(of: "performCustom(") {
                let window = rest[call.upperBound...].prefix(400)
                // 宣言(func performCustom)は飛ばす
                let before = rest[..<call.lowerBound].suffix(6)
                rest = rest[call.upperBound...]
                if before.hasSuffix("func ") { continue }
                if let literal = window.range(of: #"command: "([A-Za-z]+)""#, options: .regularExpression) {
                    found.append(String(window[literal].dropFirst("command: \"".count).dropLast()))
                } else if window.contains("command: command") {
                    found.append("fold/unfold/hinge")
                } else {
                    XCTFail("\(file.lastPathComponent): command を読み取れない performCustom がある")
                }
            }
        }
        XCTAssertFalse(found.isEmpty, "走査が Sources/FTDSL に届いていない")
        let unclassified = Set(found).subtracting(Self.table.keys)
        XCTAssertEqual(unclassified, [], "門の扱いが表に無い performCustom の入口がある: \(unclassified.sorted())")
        let stale = Set(Self.table.keys).subtracting(found)
        XCTAssertEqual(stale, [], "表にあるのに入口が無い: \(stale.sorted())")
    }

    /// "gated" と書いたものは本当に門を呼ぶ(表の嘘を落とす)
    func testGatedEntriesCallTheGate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTDSL/CommandsAppControl.swift"), encoding: .utf8)
        for (command, how) in Self.table where how == "gated" {
            guard let call = source.range(of: "command: \"\(command)\"") else { return XCTFail("\(command) の入口が無い") }
            let body = source[call.upperBound...].prefix(1500)
            XCTAssertTrue(body.contains("appLeftRefusal("), "\(command) は gated と書いたが門を呼んでいない")
        }
    }
}
