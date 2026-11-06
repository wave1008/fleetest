// doubleTap も tap と同じく撃った要素の記録(recordInteraction)を残す。記録が無いと
// noteCoverSuspect が覆いの疑いを控えられず、後続の赤が覆いを名指せない。

import XCTest
@testable import FTCore

final class DoubleTapInteractionRecordTests: XCTestCase {
    func testDoubleTapRecordsTheTargetBeforeThePreTouchPlan() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/StepExecutor+Actions.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let marker = "if action == \"doubleTap\" {\n                // tap と同じく"
        guard let start = source.range(of: marker) else { return XCTFail("doubleTap の記録の分岐が無い") }
        let tail = String(source[start.lowerBound...].prefix(600))
        let record = tail.range(of: "recordInteraction(step: step, element: element, in: snapshot)")
        let plan = tail.range(of: "coveredTouchPlan(")
        XCTAssertNotNil(record, "doubleTap が撃った要素の記録を残していない")
        XCTAssertNotNil(plan)
        if let record, let plan { XCTAssertLessThan(record.lowerBound, plan.lowerBound, "記録は覆いの控えより前") }
    }
}
