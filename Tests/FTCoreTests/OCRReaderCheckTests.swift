import XCTest
@testable import FTCore

/// doctor / ft_doctor の OCR 判定。サンドボックスの中で読めなかった回を ❌(故障)に数えない
final class OCRReaderCheckTests: XCTestCase {
    func testUnsupportedWinsOverEverything() {
        XCTAssertEqual(OCRReaderCheck.verdict(supported: false, alive: false, sandboxed: true), .unsupported)
        XCTAssertEqual(OCRReaderCheck.verdict(supported: false, alive: true, sandboxed: false), .unsupported)
    }

    func testReadingTheImageIsAliveEvenInsideASandbox() {
        XCTAssertEqual(OCRReaderCheck.verdict(supported: true, alive: true, sandboxed: true), .alive)
        XCTAssertEqual(OCRReaderCheck.verdict(supported: true, alive: true, sandboxed: false), .alive)
    }

    func testReadingNothingIsDeadOnlyOutsideASandbox() {
        XCTAssertEqual(OCRReaderCheck.verdict(supported: true, alive: false, sandboxed: false), .dead)
        XCTAssertEqual(OCRReaderCheck.verdict(supported: true, alive: false, sandboxed: true), .undeterminedInSandbox)
    }

    /// テストのプロセスはサンドボックスの外で動く(中なら sandbox_check を引けていない側の誤りも疑う)
    func testThisTestProcessIsNotSandboxed() {
        XCTAssertFalse(ProcessSandbox.isSandboxed)
    }
}
