// 失敗時の絵は、PNG が申告した向き(eXIf)で回して保存する。申告が無ければ回さない・絵が無ければ nil。

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FTDSL

final class FailureEvidenceImageTests: XCTestCase {

    private func png(width: Int, height: Int, orientation: Int?) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary })
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        if let orientation {
            let props = CGImageSourceCopyPropertiesAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(out as CFData, nil)), 0, nil)
                as? [CFString: Any]
            try XCTSkipUnless((props?[kCGImagePropertyOrientation] as? Int) == orientation, "この環境の ImageIO は PNG に向きを書かない")
        }
        return out as Data
    }

    private func size(_ data: Data) throws -> (Int, Int) {
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)), 0, nil))
        return (image.width, image.height)
    }

    func testLandscapeDeclaredPNGIsRotatedToDisplayOrientation() throws {
        let rotated = try XCTUnwrap(FailureEvidenceImage.displayOriented(try png(width: 600, height: 1200, orientation: 6)))
        let (w, h) = try size(rotated)
        XCTAssertEqual(w, 1200)
        XCTAssertEqual(h, 600)
    }

    func testPNGWithoutOrientationIsKeptAsIs() throws {
        let source = try png(width: 600, height: 1200, orientation: nil)
        XCTAssertEqual(FailureEvidenceImage.displayOriented(source), source)
    }

    func testNilAndUndecodableInputsPassThrough() {
        XCTAssertNil(FailureEvidenceImage.displayOriented(nil))
        let junk = Data([0, 1, 2])
        XCTAssertEqual(FailureEvidenceImage.displayOriented(junk), junk)
    }

    /// 失敗時の絵は回してから記録に入れる(配線を外しても単体の関数のテストは落ちないので、呼び出しをソースで縛る)
    func testFailureScreenshotIsRecordedDisplayOriented() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/FTDSL/FTRuntime.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("failureScreenshot = FailureEvidenceImage.displayOriented(screenshot)"))
        XCTAssertFalse(src.contains("failureScreenshot = screenshot"), "回さずに記録している経路がある")
    }
}
