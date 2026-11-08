import Foundation
import XCTest
@testable import FTCore

/// セレクタ無しの type でブリッジが応答に載せた注記(末尾が欄に残らなかった等)は、その type のステップの説明に載る。
/// 読まないと Android のドライバは読むまで持ち越すので、次の操作の説明に付き、次が検証なら消えた(40周目 phys F1・F2・alocal F1・amax F3)
final class RefLessTypeBridgeNoteTests: XCTestCase {
    private let note = "the field did not keep the last 1 character(s) written: read back \"765432\" after writing \"7654321\""

    func testRefLessTypeCarriesTheBridgeNoteOnItsOwnStep() async {
        let driver = NoteOnTypeDriver(note: note)
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        let typed = await executor.execute(FlowStep(action: "type", text: "7654321", timeout: 0.1))
        XCTAssertTrue(StepExecutor.isSuccess(typed.status), "\(typed.status)")
        XCTAssertTrue(typed.driverFallback?.contains("did not keep the last 1 character") == true,
                      "type の説明に注記が無い: \(typed.driverFallback ?? "nil")")
        let tapped = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "key_1"), timeout: 0.1))
        XCTAssertFalse(tapped.driverFallback?.contains("did not keep") == true,
                       "type の注記が次の tap に持ち越された: \(tapped.driverFallback ?? "nil")")
    }

    /// 注入器が欄を読み返せた(注記がある)なら、木に焦点が無くても「どこにも行っていないかも」を並べない(41周目 phys F1)。
    /// 注記が無ければ従来どおり type-focus-not-reported を付ける
    func testReadBackNoteSuppressesTheNowhereWarning() async {
        let withNote = StepExecutor(driver: NoteOnTypeDriver(note: note, focused: false), isAndroid: true, tunables: RunTunables())
        let typed = await withNote.execute(FlowStep(action: "type", text: "7654321", timeout: 0.1))
        XCTAssertTrue(StepExecutor.isSuccess(typed.status), "\(typed.status)")
        XCTAssertFalse(typed.notes.contains(.typeFocusNotReported), "読み返した注記と矛盾する: \(typed.notes)")
        let withoutNote = StepExecutor(driver: NoteOnTypeDriver(note: nil, focused: false), isAndroid: true, tunables: RunTunables())
        let plain = await withoutNote.execute(FlowStep(action: "type", text: "7654321", timeout: 0.1))
        XCTAssertTrue(plain.notes.contains(.typeFocusNotReported), "\(plain.notes)")
    }
}

/// type の応答に注記を載せ、読んだら消える(AndroidDriver.lastActionNote と同じ規約)
private final class NoteOnTypeDriver: AppDriver {
    let note: String?
    let focused: Bool
    private var pending: String?
    init(note: String?, focused: Bool = true) { self.note = note; self.focused = focused }
    var lastActionNote: String? {
        defer { pending = nil }
        return pending
    }
    func snapshot() async throws -> SnapshotResponse {
        let field = ElementInfo(ref: 1, type: "textField", identifier: "field_otp", label: nil, value: "765432", placeholder: nil,
                                enabled: true, frame: FTRect(x: 10, y: 100, width: 300, height: 60), depth: 1, focused: focused)
        let key = ElementInfo(ref: 2, type: "button", identifier: "key_1", label: "1", value: nil, placeholder: nil, enabled: true,
                              frame: FTRect(x: 10, y: 400, width: 100, height: 60), depth: 1)
        return SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                elements: [field, key], truncatedCount: 0)
    }
    func status() async throws -> StatusResponse { StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil) }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func tap(ref: Int) async throws {}   // AndroidDriver の tap は type の注記を消さない(読むまで残る)
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws { pending = note }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}
