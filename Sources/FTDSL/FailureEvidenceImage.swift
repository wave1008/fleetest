import FTCore
import Foundation

/// 失敗時のスクリーンショットを保存する前の整形(純関数)
enum FailureEvidenceImage {
    /// 向きは撮った絵(PNG の eXIf)が申告したものだけで決める。横向きの画面の絵は画素が縦のまま向きを eXIf で持つので、
    /// そのまま保存すると向きを読まない読み手(レポートの埋め込み・画像ビューア)には 90° 回って見える。
    /// 木の screen の幅・高さは回す向き(左右)を言えないので使わない。申告が無い・回せないときは元のまま返す
    static func displayOriented(_ png: Data?) -> Data? {
        guard let png else { return nil }
        return ImageDownscale.displayOrientedPNG(png: png) ?? png
    }
}
