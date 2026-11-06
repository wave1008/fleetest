import XCTest
@testable import FTCore
@testable import FTAndroid

/// `StepExecutor.ownDialogWindowMarker`(FTCore)と `AndroidForegroundWindows.ownDialogs` が窓の名前に付ける語尾は別のモジュールの
/// 文字列なので、片方だけ変えると失敗文がダイアログを名指さなくなる(静かに従来の文へ戻る)
final class OwnDialogWindowMarkerPinTests: XCTestCase {
    func testOwnDialogsEndWithTheMarkerTheExecutorLooksFor() {
        let package = "com.example.app"
        let main = "\(package)/\(package).MainActivity"
        let dumpsys = """
          Window #0 Window{a u0 \(main)}:
            mAttrs={(0,0)(fillxfill) priority=0 ty=APPLICATION fmt=TRANSLUCENT}
            isVisible=true
        """
        let lines = AndroidForegroundWindows.ownDialogs(package: package, dumpsys: dumpsys)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.allSatisfy { $0.hasSuffix(StepExecutor.ownDialogWindowMarker) }, "\(lines)")
        XCTAssertNotNil(StepExecutor.ownDialogHint(windows: lines))
    }
}
