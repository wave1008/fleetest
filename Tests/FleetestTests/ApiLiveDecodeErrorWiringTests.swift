import XCTest

/// api live serve が cmd の読める型違い行を黙殺していた実地(L3): 型付き Decodable の
/// 全体失敗で無応答のまま「JSON でない行」と区別が付かず、拡張の SERVE_REQUEST_TIMEOUT で
/// serve ごと再起動していた。パース自体(decodeError の中身)は
/// Tests/FleetestTests/ApiLiveServeCommandParsingTests.swift が固定するので、ここは
/// handle が decodeError を最優先で終端イベントに変えて答えることを配線として縛る。
///
/// **2つ目の実地**: decodeError 分岐が actionResult だけを出して return していたため、
/// 拡張が次に来るはずの観測イベント(snapshot)を20秒待ち続けて serve を再起動していた
/// (pinch/tap の型違い行で発生)。ここは「actionResult に続けて観測イベントを出す」を
/// ブロック単位で検分する(コメント中に `{`/`}` が無い前提の素朴な波カッコ対応で本体を切り出す)。
final class ApiLiveDecodeErrorWiringTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `{` の直後(openBraceEnd)から対応する `}` までの範囲を返す(ネストを数えて対応を取る)
    private func balancedBraceBody(in code: String, afterOpenBrace openBraceEnd: String.Index) -> Range<String.Index> {
        var depth = 1
        var idx = openBraceEnd
        while idx < code.endIndex {
            let ch = code[idx]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return openBraceEnd..<idx }
            }
            idx = code.index(after: idx)
        }
        return openBraceEnd..<code.endIndex
    }

    private struct MarkerNotFound: Error {}

    private func decodeErrorOpenRange(in code: String) throws -> Range<String.Index> {
        guard let handleRange = code.range(of: "private func handle(") else {
            XCTFail("handle が見当たらない")
            throw MarkerNotFound()
        }
        guard let openRange = code.range(
            of: "if let decodeError = command.decodeError {",
            range: handleRange.upperBound..<code.endIndex
        ) else {
            XCTFail("handle が command.decodeError を見ていない"
                + " — 型違いの行が無応答のまま黙殺される(実地 L3)")
            throw MarkerNotFound()
        }
        return openRange
    }

    /// decodeError の確認は通常の経路(perform)より前に行うこと
    /// (後回しにすると型違いの行が黙って操作・観測へ流れる)
    func testDecodeErrorCheckPrecedesTheNormalPath() throws {
        let code = try source()
        let openRange = try decodeErrorOpenRange(in: code)
        let blockEnd = balancedBraceBody(in: code, afterOpenBrace: openRange.upperBound).upperBound
        guard let performRange = code.range(of: "try await perform(command: command", range: blockEnd..<code.endIndex) else {
            return XCTFail("通常の経路(perform の呼び出し)が decodeError ブロックの後ろに見当たらない")
        }
        XCTAssertTrue(openRange.lowerBound < performRange.lowerBound)
    }

    /// 型違い行は actionResult(ok:false) に続けて観測イベントを出す(通常経路と同形)。
    /// **操作(perform)は実行しない** —— 引数が壊れているので撃てる状態ではない
    func testDecodeErrorEmitsActionResultThenObservationWithoutPerforming() throws {
        let code = try source()
        let openRange = try decodeErrorOpenRange(in: code)
        let tail = String(code[balancedBraceBody(in: code, afterOpenBrace: openRange.upperBound)])
        XCTAssertTrue(tail.contains("ApiLiveActionResultEvent(ok: false"),
                      "型違いは actionResult(ok:false) で答えること")
        XCTAssertTrue(tail.contains("await emitObservation("),
                      "actionResult に続けて観測イベントを出すこと —— 拡張は続く snapshot で"
                      + " リクエストを解決するため、これが無いと20秒の SERVE_REQUEST_TIMEOUT で"
                      + " serve ごと再起動される(実地: pinch/tap の型違い行で発生)")
        XCTAssertFalse(tail.contains("perform(command:"),
                       "型違いの行では操作(perform)を実行しないこと(引数が壊れている)")
        XCTAssertTrue(tail.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("return"),
                      "decodeError ブロックはここで終えること(以降の通常経路へフォールスルーしない)")
    }

    /// ファイル冒頭のプロトコルコメントも更新済みであること(片方だけ変えない)
    func testProtocolCommentDocumentsTheTypeErrorResponse() throws {
        let code = try source()
        XCTAssertTrue(code.contains("cmd は読めたが他の引数の型が違う行は無視しない"),
                      "プロトコルコメント(ファイル冒頭)が型違い行の扱いを説明していない")
    }
}
