import XCTest
@testable import FTCore

final class HealWriteBackScopeTests: XCTestCase {
    private func loc(_ s: String) -> FlowLocator? { FTSelector.parse(s).primary }

    func testScopedOriginalRewrittenWithoutScopeIsNotWrittenBack() {
        XCTAssertFalse(HealWriteBackScope.preservesScope(original: loc(".alert >> 写真を撮る"), healed: loc("写真を撮る")))
    }

    func testScopedOriginalKeepingAScopeIsWrittenBack() {
        XCTAssertTrue(HealWriteBackScope.preservesScope(original: loc(".alert >> 写真を撮る"), healed: loc(".sheet >> 写真を撮る")))
    }

    func testUnscopedOriginalIsUnaffected() {
        XCTAssertTrue(HealWriteBackScope.preservesScope(original: loc("#old"), healed: loc("新しい")))
        XCTAssertTrue(HealWriteBackScope.preservesScope(original: nil, healed: loc("新しい")))
    }

    func testFingerprintHealGateIsWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+Actions.swift"), encoding: .utf8)
        let gate = try XCTUnwrap(src.range(of: "HealWriteBackScope.preservesScope(original: step.locator"))
        XCTAssertTrue(String(src[gate.upperBound...].prefix(300)).contains("healedStep = healed"))
    }
}
