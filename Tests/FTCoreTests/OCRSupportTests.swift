import CoreGraphics
import XCTest
@testable import FTCore

/// OCR は macOS 27+ だけ(OCRSupport)。非対応を「OCR の故障」「読めなかった」に倒さないことを、注入口
/// `FT_FAKE_OCR_UNSUPPORTED` で通す(macOS 27 の上で非対応として振る舞わせる)
final class OCRSupportTests: XCTestCase {
    override func tearDown() {
        unsetenv(OCRSupport.fakeUnsupportedKey)
        super.tearDown()
    }

    func testIsSupportedFollowsOSAndInjection() {
        XCTAssertTrue(OCRSupport.isSupported(environment: [:], osSupported: true))
        XCTAssertFalse(OCRSupport.isSupported(environment: [:], osSupported: false))
        XCTAssertFalse(OCRSupport.isSupported(environment: [OCRSupport.fakeUnsupportedKey: "1"], osSupported: true))
        XCTAssertTrue(OCRSupport.isSupported(environment: [OCRSupport.fakeUnsupportedKey: "0"], osSupported: true))
    }

    func testRequirementNamesTheOSVersion() {
        XCTAssertEqual(OCRSupport.requirement, "On-device OCR (Vision text recognition) requires macOS 27+")
    }

    func testModeIsOffWhenUnsupported() {
        XCTAssertEqual(RegionText.mode(environment: [OCRSupport.fakeUnsupportedKey: "1"]), .off)
        XCTAssertEqual(RegionText.mode(environment: [OCRSupport.fakeUnsupportedKey: "1", "FT_OCCLUSION_OCR": "measure"]), .off)
    }

    func testGateThrowsInsteadOfReturningEmptyWhenUnsupported() async throws {
        setenv(OCRSupport.fakeUnsupportedKey, "1", 1)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(ctx.makeImage())
        do {
            _ = try await RegionText.recognizeObservations(image, languages: ["en-US"])
            XCTFail("非対応なのに Vision を撃った(または [] を返した)")
        } catch is OCRUnsupportedError {
        }
    }

    func testReaderIsNotReportedAliveOrReadyWhenUnsupported() async {
        setenv(OCRSupport.fakeUnsupportedKey, "1", 1)
        let before = RegionText.modelCompileRequestCount
        RegionText.compileModelIfNeeded(mode: .on)
        XCTAssertEqual(RegionText.modelCompileRequestCount, before, "非対応ではコンパイルを頼まない")
        let readable = await RegionText.awaitReadableVision()
        XCTAssertFalse(readable)
    }

    private func paragraph() -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: "terms", label: "Please accept the Terms of Service",
                    value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 360, width: 400, height: 60), depth: 1)
    }

    func testLinkTextRefusesBeforeShootingWhenUnsupported() async {
        setenv(OCRSupport.fakeUnsupportedKey, "1", 1)
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[paragraph()]], screenshots: [])
        let executor = StepExecutor(driver: driver, occlusionOCRMode: .off, isAndroid: true, tunables: RunTunables())
        var step = FlowStep(action: "tap", locator: FlowLocator(id: "terms"))
        step.linkText = "Terms of Service"
        let outcome = await executor.execute(step)
        guard case .failed(let message) = outcome.status else { XCTFail("実際は \(outcome.status)"); return }
        XCTAssertTrue(message.contains(OCRSupport.requirement), message)
        XCTAssertEqual(driver.screenshotCallCount, 0, "撮る前に断る")
    }

    func testTypedTextIsOnScreenIsUnknownWhenUnsupported() async {
        setenv(OCRSupport.fakeUnsupportedKey, "1", 1)
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[paragraph()]], screenshots: [])
        let executor = StepExecutor(driver: driver, occlusionOCRMode: .off, isAndroid: true, tunables: RunTunables())
        let answer = await executor.typedTextIsOnScreen(driver, element: paragraph(), text: "abc",
                                                        deadline: Date().addingTimeInterval(5))
        XCTAssertNil(answer.visible, "分からない(nil)= 追送しない。false に倒すと二重入力になる")
        XCTAssertEqual(answer.fact, OCRSupport.requirement)
        XCTAssertEqual(driver.screenshotCallCount, 0)
    }
}
