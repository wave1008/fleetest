// MCP で「Android か」を決めるときは、引数の platform だけでなくプロファイルからも決める(`Self.platformName`)。
// 引数だけを見ると、platform を省いた Android のプロファイルの呼び出しを iOS と読む(ft_capture_element の
// variant が「iOS の UDID が分からない」で断った)。コンパイラは止めないので、MCP の全ソースを走査して固定する。

import XCTest

final class PlatformFromProfileScanTests: XCTestCase {

    /// 引数の platform だけで Android かを決めてよい箇所(理由付き)
    private static let allowed: [String: String] = [
        // profile も serial も無い呼び出しだけに効く分岐(`args["profile"] == nil, args["serial"] == nil` が前置)
        "MCPServer+SessionTools.swift": "ftStatus の複数台の一覧はプロファイルの無い呼び出しだけ",
        // テスト用の差し替えドライバの既定のブリッジ名(本番の経路ではない)
        "MCPServer+Driver.swift": "makeDriver の差し替え経路の既定",
    ]

    func testAndroidIsNotDecidedFromTheRawPlatformArgument() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "走査の前提(MCP のソースの場所)が崩れた")
        var offenders: [String] = []
        for file in files where Self.allowed[file.lastPathComponent] == nil {
            let code = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in code.components(separatedBy: "\n").enumerated()
            where line.contains(#"(args["platform"] as? String) == "android""#) {
                offenders.append("\(file.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "Android かを引数の platform だけで決めている。Self.platformName(args) を使う")
    }
}
