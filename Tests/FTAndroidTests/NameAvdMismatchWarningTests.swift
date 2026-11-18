// プロファイルの name が avd とは別の既存 AVD を指すときだけ警告する(解決は avd 優先)。

import XCTest
@testable import FTAndroid

final class NameAvdMismatchWarningTests: XCTestCase {
    private let installed: [(id: String, displayName: String?)] = [
        ("Pixel_10_Pro_Android_17_-05", nil), ("Pixel_10_Pro_Android_17_-06", nil)]

    func testNameOfAnotherAVDWarns() {
        let warning = AndroidDeviceCatalog.nameAvdMismatchWarning(
            name: "Pixel 10 Pro(Android 17)-06", avd: "Pixel_10_Pro_Android_17_-05", installed: installed)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("Pixel_10_Pro_Android_17_-05") == true)
        XCTAssertTrue(warning?.contains("Pixel_10_Pro_Android_17_-06") == true)
    }

    func testSameAVDDoesNotWarn() {
        XCTAssertNil(AndroidDeviceCatalog.nameAvdMismatchWarning(
            name: "Pixel 10 Pro(Android 17)-05", avd: "Pixel_10_Pro_Android_17_-05", installed: installed))
    }

    func testPlainLabelThatIsNoAVDDoesNotWarn() {
        XCTAssertNil(AndroidDeviceCatalog.nameAvdMismatchWarning(
            name: "my emulator", avd: "Pixel_10_Pro_Android_17_-05", installed: installed))
    }

    func testNoAvdDoesNotWarn() {
        XCTAssertNil(AndroidDeviceCatalog.nameAvdMismatchWarning(name: "x", avd: nil, installed: installed))
    }
}
