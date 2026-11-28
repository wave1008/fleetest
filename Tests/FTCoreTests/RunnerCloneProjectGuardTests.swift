import Foundation
import XCTest
@testable import FTCore

/// ランナーのクローンの中でクローン自身の TestProjects からデバイスを選ばせない判定(`RunnerCloneProjectGuard`)。
/// 4条件が全部そろったときだけ断る。1つずつ外して通ることで、「常に通す」「常に断る」変異の両方を落とす
final class RunnerCloneProjectGuardTests: XCTestCase {

    private func refusal(marker: Bool = true, inside: Bool = true, annotated: Bool = true,
                         explicit: Bool = false) -> String? {
        RunnerCloneProjectGuard.refusal(hasMarker: marker, projectInsideClone: inside,
                                        machineAnnotated: annotated, explicitMachineChoice: explicit)
    }

    func testRefusesWhenAllConditionsHold() throws {
        let message = try XCTUnwrap(refusal())
        XCTAssertTrue(message.contains("--runner <machine>"), message)
        XCTAssertTrue(message.contains("--device-machine"), message)
    }

    func testAllowsWithoutMarker() { XCTAssertNil(refusal(marker: false)) }
    func testAllowsProjectOutsideCloneProjects() { XCTAssertNil(refusal(inside: false)) }
    func testAllowsProjectWithoutMachineAnnotation() { XCTAssertNil(refusal(annotated: false)) }
    func testAllowsExplicitMachineChoice() { XCTAssertNil(refusal(explicit: true)) }  // --device-machine <機械> か run の --runner local

    func testMarkerContentCarriesNoAlias() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: RunnerCloneProjectGuard.markerContent) as? [String: String])
        XCTAssertEqual(object, ["kind": "runner-clone"])
        XCTAssertEqual(RunnerCloneProjectGuard.markerRelativePath, ".fleetest/runner-clone.json")
    }

    func testProjectInsideCloneVersusWorkCopy() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rcg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let clone = base.appendingPathComponent("fleetest")
        let work = base.appendingPathComponent("users/issuer/work")
        for dir in [clone.appendingPathComponent("TestProjects/P"), work.appendingPathComponent("TestProjects/P")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        XCTAssertTrue(RunnerCloneProjectGuard.isInsideCloneProjects(
            projectRoot: clone.appendingPathComponent("TestProjects/P"), toolRoot: clone))
        XCTAssertFalse(RunnerCloneProjectGuard.isInsideCloneProjects(
            projectRoot: work.appendingPathComponent("TestProjects/P"), toolRoot: clone))
        // 前方一致だけで「中」と読まない(兄弟のディレクトリ)
        XCTAssertFalse(RunnerCloneProjectGuard.isInsideCloneProjects(
            projectRoot: clone.appendingPathComponent("TestProjectsX/P"), toolRoot: clone))
    }
}
