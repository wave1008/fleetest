import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageDownscale {
    /// PNG → 幅 maxWidth 以内へ縮小 → JPEG。ImageIO のサムネイル生成を使う(自前の描画より速い)。
    /// maxWidth は「幅」の上限。kCGImageSourceThumbnailMaxPixelSize は**長辺**の上限なので、
    /// 縦長画像ではそのまま渡すと幅が指定より大幅に小さくなる(1080x2340 で 360 指定 → 166x360)。
    /// 長辺換算に直してから渡す。失敗(壊れた PNG 等)は nil
    public static func jpeg(png: Data, maxWidth: Int, quality: Double) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let storedWidth = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? maxWidth
        let storedHeight = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? maxWidth
        // 出力は kCGImageSourceCreateThumbnailWithTransform で表示の向きへ回る。EXIF の向き 5〜8 は 90° 回転なので
        // 保存の幅・高さが入れ替わる(横向きの PNG は eXIf だけで向きを持つ)。入れ替えないと maxWidth が高さの上限として効く
        let orientation = (properties?[kCGImagePropertyOrientation] as? Int) ?? 1
        let (sourceWidth, sourceHeight) = (5...8).contains(orientation)
            ? (storedHeight, storedWidth) : (storedWidth, storedHeight)
        let longSide: Int = {
            guard sourceWidth > 0, maxWidth < sourceWidth else { return max(sourceWidth, sourceHeight) }
            let scale = Double(maxWidth) / Double(sourceWidth)
            return Int((Double(max(sourceWidth, sourceHeight)) * scale).rounded())
        }()
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(longSide, 1),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, image.width, image.height)
    }

    /// PNG の EXIF の向き(eXIf)が 2〜8 のとき、保存の画素を表示の向きへ回した絵。向き 1・向き無しは元のまま(回さない)。
    /// 横向きの画面のスクリーンショットは画素が縦のまま向きだけを持つので、画素を読む側(切り出し・fullSize)は
    /// 回してから使う。向きを絵から推さない = 回すのは PNG が申告した向きだけ
    public static func displayOriented(png: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? Int) ?? 1
        guard (2...8).contains(orientation) else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 向きを持つ PNG だけ、画素を表示の向きへ回した PNG(向きの申告は付けない)にして返す。回す必要が無い・回せないときは nil
    public static func displayOrientedPNG(png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? Int, (2...8).contains(orientation),
              let image = displayOriented(png: png) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
