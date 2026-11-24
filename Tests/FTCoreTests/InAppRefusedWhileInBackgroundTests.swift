// in-app ブリッジが背面の間に断る表(`refusedWhileInBackground`)の集合を固定する。
// in-app の dylib は swift test でリンクされないので、ソースを走査する。
// 表から漏れたルートは背面のアプリへ操作が届いて 200 を返す(誤った緑。/sliderStep が漏れていた)。

import XCTest

final class InAppRefusedWhileInBackgroundTests: XCTestCase {

    func testRefusedSetIsPinned() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("InAppBridge/Sources/InAppBridge.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "static let refusedWhileInBackground: Set<String> = ["))
        let end = try XCTUnwrap(source.range(of: "]", range: start.upperBound..<source.endIndex))
        let listed = Set(source[start.upperBound..<end.lowerBound]
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty })
        let expected: Set<String> = [
            "/snapshot", "/tap", "/type", "/clear", "/pressEnter", "/hidekeyboard", "/swipe", "/doubletap", "/pinch",
            "/drag", "/press", "/sliderStep",
        ]
        XCTAssertEqual(listed, expected)
    }
}
