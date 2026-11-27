// avdmanager の機種定義の読みと、`api device-traits` の登録。破ると: 機種名が引けず @RequiresDevice(.model) が読めない扱いになる/
// 親が remote exec で引く口が消える。

import ArgumentParser
import XCTest
@testable import fleetest

final class DeviceTraitsObserverTests: XCTestCase {
    /// `avdmanager list device` のブロック形式(id 行の次の Name 行と対にする)
    func testDeviceDefinitionsFromAvdmanagerOutput() {
        let out = """
            Available devices definitions:
            id: 0 or "tv_1080p"
                Name: Android TV (1080p)
                OEM : Google
                Tag : android-tv
            ---------
            id: 5 or "pixel_9_pro_fold"
                Name: Pixel 9 Pro Fold
                OEM : Google
            ---------
            Error: Could not load devices from /x/devices.xml
            """
        XCTAssertEqual(DeviceTraitsObserver.deviceDefinitions(avdmanagerOutput: out),
                       ["tv_1080p": "Android TV (1080p)", "pixel_9_pro_fold": "Pixel 9 Pro Fold"])
        XCTAssertEqual(DeviceTraitsObserver.deviceDefinitions(avdmanagerOutput: ""), [:])
    }

    func testApiDeviceTraitsIsRegisteredAndHidden() {
        XCTAssertTrue(ApiCommand.configuration.subcommands.contains { $0 == ApiDeviceTraitsCommand.self })
        XCTAssertFalse(ApiDeviceTraitsCommand.configuration.shouldDisplay)
        XCTAssertEqual(ApiDeviceTraitsCommand.configuration.commandName, "device-traits")
    }
}
