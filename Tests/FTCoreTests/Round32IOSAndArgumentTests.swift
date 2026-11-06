import Foundation
import XCTest
@testable import FTCore

/// 32周目: iOS の静的テキストへの type を撃つ前に断る(im4 F1・ilocal F1)・モーダルの申告の言い方(iultra F1)・
/// `linkText: ""` を撃つ前に断る(iultra 回し直し)
final class Round32IOSAndArgumentTests: XCTestCase {
    private func el(_ type: String) -> ElementInfo {
        ElementInfo(ref: 1, type: type, identifier: "x", label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    private func executor(isAndroid: Bool) -> StepExecutor {
        StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]]),
                     isAndroid: isAndroid, tunables: RunTunables())
    }

    /// iOS の staticText への type は撃つ前に断らない(RN の iOS の OTP の箱が staticText で来る = 33周目 im4 F1)。
    /// 断るのは Android だけ(AndroidStaticTextTypePreflightTests)
    func testIOSStaticTextTypeIsNotRefusedBeforeTapping() {
        let label = el("staticText")
        XCTAssertNil(executor(isAndroid: false).nonTextInputPreflightRefusal(label, in: [label], action: "type"))
    }

    func testModalHintStatesOnlyWhatIsKnown() throws {
        let snapshot = SnapshotResponse(sessionBundleID: "app", screen: FTRect(x: 0, y: 0, width: 402, height: 874), elements: [],
                                        truncatedCount: 0, modalScope: ModalScopeCover(
                                            droppedCount: 1, frames: [FTRect(x: 8, y: 415, width: 386, height: 450)]))
        let hint = try XCTUnwrap(StepExecutor.modalScopeHint(snapshot))
        XCTAssertTrue(hint.contains("(8,415 386x450)") && hint.contains("left 1 element group(s) out of the tree"), hint)
        XCTAssertTrue(hint.contains("if the target is behind it"), hint)
        XCTAssertFalse(hint.contains("probably behind"), "存在しない id にも言う断定をしない: \(hint)")
    }

    func testEmptyLinkTextIsRefusedBeforeAnyOCR() async {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [[el("staticText")]])
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "x"), timeout: 0.1, linkText: "")
        XCTAssertNotNil(step.linkTextArgumentViolation)
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(step)
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("linkText must not be empty"), message)
        XCTAssertTrue(log.entries.isEmpty, "断る前にデバイスへ触った: \(log.entries)")
        XCTAssertNotNil(FlowStep(action: "tap", locator: FlowLocator(id: "x"), linkText: "  ").linkTextArgumentViolation)
        XCTAssertNil(FlowStep(action: "tap", locator: FlowLocator(id: "x"), linkText: "こちら").linkTextArgumentViolation)
        XCTAssertNil(FlowStep(action: "tap", locator: FlowLocator(id: "x")).linkTextArgumentViolation)
    }
}
