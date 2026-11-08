// Vision の文字認識(OCR)を使ってよいかの単一判定点(FMVisionSupport と同じ形)。
//
// OCR を使う機能(テキストの可視性検証の OCR 段・tap(linkText:)・type の読み返しの画面確認・doctor の読み手確認)は
// macOS 27+ でだけ撃つ。macOS 26 でも他の機能は動く。
// 入口は RegionText.recognizeObservations の1箇所で、そこが保険の門(OCRUnsupportedError)。
// 呼び手は「非対応」を「OCR の故障」(readerIsAlive が false)と混ぜない。

import Foundation

public enum OCRSupport {
    /// 陽性対照の注入口: macOS 27+ の上でも非対応として振る舞う
    public static let fakeUnsupportedKey = "FT_FAKE_OCR_UNSUPPORTED"

    /// 純粋関数(テスト用)。`osSupported` は実際の OS の答え
    public static func isSupported(environment: [String: String], osSupported: Bool = osSupportsOCR) -> Bool {
        osSupported && environment[fakeUnsupportedKey] != "1"
    }

    /// 既定の環境(プロセスの環境変数)で読む
    public static var isSupported: Bool { isSupported(environment: ProcessInfo.processInfo.environment) }

    public static let osSupportsOCR: Bool = {
        if #available(macOS 27, *) { return true }
        return false
    }()

    /// 無効理由(ユーザー向け文言。失敗文・注記・doctor 出力で共用)
    public static let requirement = "On-device OCR (Vision text recognition) requires macOS 27+"
}

/// OCR が非対応の環境で Vision を撃とうとした。`[]`(何も読めなかった)と区別するための専用のエラー
public struct OCRUnsupportedError: Error, CustomStringConvertible {
    public init() {}
    public var description: String { OCRSupport.requirement }
}
