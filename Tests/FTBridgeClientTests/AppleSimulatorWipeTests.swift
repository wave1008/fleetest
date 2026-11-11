import XCTest
@testable import FTBridgeClient
import FTCore

/// `AppleSimulatorWipe`: group コンテナの列挙の読み取り・中身だけ消す規律・応答の事実
final class AppleSimulatorWipeTests: XCTestCase {
    func testParsesTabAndSpaceSeparatedGroupLines() {
        let parsed = AppleSimulatorWipe.parseGroupContainers(
            "group.com.apple.Maps\t/Users/x/Library/Developer/CoreSimulator/Devices/U/data/Containers/Shared/AppGroup/A\n"
            + "group.com.apple.maps.shared /tmp/with space/B\n")
        XCTAssertEqual(parsed.groups.map(\.id), ["group.com.apple.Maps", "group.com.apple.maps.shared"])
        XCTAssertEqual(parsed.groups[1].path, "/tmp/with space/B")
        XCTAssertEqual(parsed.unparsableLines, 0)
    }

    func testNoGroupsAndGarbageLines() {
        XCTAssertTrue(AppleSimulatorWipe.parseGroupContainers("").groups.isEmpty)
        XCTAssertEqual(AppleSimulatorWipe.parseGroupContainers("\n  \n").unparsableLines, 0)
        let garbage = AppleSimulatorWipe.parseGroupContainers(
            "An error was encountered\nnopath\ngroup.a relative/path\n/abs/only\ngroup.ok\t/ok\n")
        XCTAssertEqual(garbage.groups, [AppleSimulatorWipe.GroupContainer(id: "group.ok", path: "/ok")])
        XCTAssertEqual(garbage.unparsableLines, 4)
    }

    func testEmptyContentsKeepsTheDirectoryAndSkipsMetadata() throws {
        let dir = NSTemporaryDirectory() + "apple-wipe-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/Library/Preferences", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/a.txt", contents: Data())
        FileManager.default.createFile(atPath: dir + "/" + AppleSimulatorWipe.containerMetadataName, contents: Data())
        let result = AppleSimulatorWipe.emptyContents(of: dir, skipping: [AppleSimulatorWipe.containerMetadataName])
        XCTAssertEqual(result?.removed, 2)
        XCTAssertEqual(result?.failed, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), [AppleSimulatorWipe.containerMetadataName])
    }

    func testSymbolicLinkRootIsNotFollowed() throws {
        let base = NSTemporaryDirectory() + "apple-wipe-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base + "/real", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: base + "/real/keep", contents: Data())
        try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/real")
        XCTAssertNil(AppleSimulatorWipe.emptyContents(of: base + "/link"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base + "/real/keep"))
    }

    func testSummaryStatesCountsAndProblemsAsFacts() {
        var report = AppleSimulatorWipe.Report(dataContainerPath: "/d", dataItemsRemoved: 3)
        report.groups = [("group.com.apple.Maps", "/g", 5)]
        let ok = AppleSimulatorWipe.summary(bundleID: "com.apple.Maps", report: report)
        XCTAssertTrue(ok.contains("3 item(s)") && ok.contains("group.com.apple.Maps (5 item(s))"), ok)
        XCTAssertFalse(ok.contains("NOT done"), ok)
        report.problems = ["could not list the app group containers"]
        let partial = AppleSimulatorWipe.summary(bundleID: "com.apple.Maps", report: report)
        XCTAssertTrue(partial.contains("NOT done: could not list the app group containers"), partial)
    }
}

/// Apple のアプリの消去は MCP だけが呼ぶ(DSL の子プロセスは SandboxBroker が `get_app_container … groups` を許さない)
final class AppleSimulatorWipeScopeTests: XCTestCase {
    func testOnlyTheMCPServerCallsTheWipe() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources").standardized
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var callers: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("AppleSimulatorWipe.wipe(") { callers.append(url.lastPathComponent) }
        }
        XCTAssertEqual(callers, ["MCPServer+SessionTools.swift"])
    }
}
