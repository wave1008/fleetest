// 状態を申告しない要素への checkIsON / OFF の失敗文の直し方は OS ごと。破ると: Android のアプリに SwiftUI の書き方と
// selected trait を勧める(探索 11/27 alocal F2 = Flutter・RN の FilterChip で従えない案内)
import XCTest
@testable import FTCore

final class CheckStateWordingByOSTests: XCTestCase {
    func testAndroidAdviceNamesAndroidWaysAndNotSwiftUI() {
        let android = StepExecutor.checkStateMismatch(.unknown, locator: "#chip", isAndroid: true)
        XCTAssertFalse(android.contains("SwiftUI"), android)
        XCTAssertFalse(android.contains("selected trait"), android)
        XCTAssertTrue(android.contains("Modifier.toggleable"), android)
        let ios = StepExecutor.checkStateMismatch(.unknown, locator: "#chip", isAndroid: false)
        XCTAssertTrue(ios.contains("SwiftUI .accessibilityRepresentation"), ios)
        let failure = StepExecutor.checkStateFailure(.unknown, locator: "#chip", classification: nil,
                                                     classifierError: "no samples", isAndroid: true)
        XCTAssertFalse(failure.contains("selected trait"), failure)
    }
}
