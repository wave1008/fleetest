// OI-116: 300 字の名前は正規表現を通り、`<name>_disabled` の作成で「file name is invalid」の生の OS 文言になっていた。

import XCTest
@testable import FTCore

final class ProjectNameLengthTests: XCTestCase {
    func testNameAtTheLimitIsValidAndOneOverIsNot() {
        XCTAssertTrue(ProjectStore.isValidName(String(repeating: "a", count: ProjectStore.maxNameBytes)))
        XCTAssertFalse(ProjectStore.isValidName(String(repeating: "a", count: ProjectStore.maxNameBytes + 1)))
    }

    func testInvalidNameMessageStatesTheLimit() {
        let message = ProjectStoreError.invalidName("x").errorDescription ?? ""
        XCTAssertTrue(message.contains("at most \(ProjectStore.maxNameBytes) bytes"), message)
    }
}
