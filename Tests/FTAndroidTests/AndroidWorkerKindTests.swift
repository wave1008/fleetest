// Android のワーカーの種類(`RunWorker.deviceKind`。DR-214 = 同じ種類の台は対象外を試した扱い)。デバイス不要。
// 破ると: Emulator のワーカーが nil のまま = 同じ機種の Emulator を毎回別の台として回し直す(遅い)/
// 実機に種類が付く = 実機を同じと読んで誤った緑。

import XCTest
@testable import FTAndroid
import FTCore

final class AndroidWorkerKindTests: XCTestCase {
    func testPhysicalAndAVDlessDevicesAreUnknown() {
        var phys = DeviceSpec(name: "real")
        phys.kind = .physical
        phys.serial = "R5"
        XCTAssertNil(ProfileWorkerFactory.androidKind(of: ResolvedDevice(platform: "android", spec: phys)), "実機は種類が不明 = 覆わない")
        XCTAssertNil(ProfileWorkerFactory.androidKind(of: ResolvedDevice(platform: "android", spec: DeviceSpec(name: "x"))), "AVD 名が無い")
    }

    func testUnreadableAVDIsUnknown() {
        var spec = DeviceSpec(name: "ghost")
        spec.avd = "No_Such_AVD_For_Kind_Test"
        XCTAssertNil(ProfileWorkerFactory.androidKind(of: ResolvedDevice(platform: "android", spec: spec)), "config.ini が読めない")
    }

    /// 両方のワーカー構築(通常・復帰)が種類を付ける(`deviceKind: nil` を Android のワーカーへ直書きしない)
    func testAndroidWorkerBuildersPassTheKind() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTAndroid/ProfileWorkerFactory.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let androidBlocks = text.components(separatedBy: "platform: \"android\"").dropFirst()
        XCTAssertGreaterThanOrEqual(androidBlocks.count, 2)
        for block in androidBlocks {
            let head = block.prefix(700)
            if let range = head.range(of: "logicalName: device.name, deviceKind:") {
                XCTAssertTrue(head[range.upperBound...].hasPrefix(" androidKind(of: device)"), "Android のワーカーに deviceKind: nil を直書きしない")
            }
        }
        XCTAssertEqual(text.components(separatedBy: "deviceKind: androidKind(of: device)").count - 1, 2)
    }
}
