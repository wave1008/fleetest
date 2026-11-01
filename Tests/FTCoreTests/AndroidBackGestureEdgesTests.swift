// `adb shell dumpsys activity service com.android.systemui/.SystemUIService` の実測(Pixel 9・
// Android 15 エミュレータ)を固定する。swipeBy が back を奪う帯を避けるための唯一の入力元

import XCTest
@testable import FTCore

final class AndroidBackGestureEdgesTests: XCTestCase {

    /// 実測スニペット(前後の無関係な行を含む。ブロックの終端はインデントの浅い次の行)
    private static let gestureNavSnippet = """
          EdgeBackGestureHandler:
            mIsBackGestureAllowed=true
            mIsGestureHandlingEnabled=true
            mEdgeWidthLeft=78
            mEdgeWidthRight=78
          mLastReportedConfig=
        """

    private static let threeButtonNavSnippet = """
          EdgeBackGestureHandler:
            mIsBackGestureAllowed=true
            mIsGestureHandlingEnabled=false
            mEdgeWidthLeft=78
            mEdgeWidthRight=78
          mLastReportedConfig=
        """

    func testParsesTheRealGestureNavigationSnippet() {
        let widths = AndroidBackGestureEdges.parse(Self.gestureNavSnippet)
        XCTAssertEqual(widths?.left, 78)
        XCTAssertEqual(widths?.right, 78)
    }

    /// 3ボタン navigation は帯そのものが無効 = 除外不要(実測 0 ではなく仕様として (0, 0))
    func testThreeButtonNavigationReturnsZeroZero() {
        let widths = AndroidBackGestureEdges.parse(Self.threeButtonNavSnippet)
        XCTAssertEqual(widths?.left, 0)
        XCTAssertEqual(widths?.right, 0)
    }

    /// ブロックが無い/鍵が読めない出力は nil(呼び手は除外しない側に倒す)
    func testUnparseableOutputReturnsNil() {
        XCTAssertNil(AndroidBackGestureEdges.parse("garbage\nnot a dumpsys at all\n"))
        XCTAssertNil(AndroidBackGestureEdges.parse(""))
    }

    /// mIsGestureHandlingEnabled 自体が読めない(欄が欠けている)ときも nil
    func testMissingEnabledKeyReturnsNil() {
        let snippet = """
              EdgeBackGestureHandler:
                mIsBackGestureAllowed=true
                mEdgeWidthLeft=78
                mEdgeWidthRight=78
            """
        XCTAssertNil(AndroidBackGestureEdges.parse(snippet))
    }

    /// enabled かつ幅が読めなければ nil(bool は読めても数値が壊れている形)
    func testEnabledWithUnreadableWidthsReturnsNil() {
        let snippet = """
              EdgeBackGestureHandler:
                mIsGestureHandlingEnabled=true
                mEdgeWidthLeft=notanumber
                mEdgeWidthRight=78
            """
        XCTAssertNil(AndroidBackGestureEdges.parse(snippet))
    }

    /// dumpsys はセクションを複数回吐きうる。**最初のブロックの値を一貫して採る**
    func testRepeatedBlocksPickTheFirstOccurrenceConsistently() {
        let snippet = """
              EdgeBackGestureHandler:
                mIsGestureHandlingEnabled=true
                mEdgeWidthLeft=78
                mEdgeWidthRight=78
              EdgeBackGestureHandler:
                mIsGestureHandlingEnabled=true
                mEdgeWidthLeft=999
                mEdgeWidthRight=999
            """
        let widths = AndroidBackGestureEdges.parse(snippet)
        XCTAssertEqual(widths?.left, 78)
        XCTAssertEqual(widths?.right, 78)
    }

    /// Android 12・13 の実機(Pixel 4a・3a)の実測: 有効の欄の名前が mIsGesturalModeEnabled。下端は mBottomGestureHeight
    func testParsesTheAndroid13DeviceFieldName() {
        let snippet = """
              EdgeBackGestureHandler:
                mIsEnabled=true
                mIsGesturalModeEnabled=true
                mEdgeWidthLeft=82
                mEdgeWidthRight=82
                mBottomGestureHeight=88.0
              mLastReportedConfig=
            """
        let widths = AndroidBackGestureEdges.parse(snippet)
        XCTAssertEqual(widths?.left, 82)
        XCTAssertEqual(widths?.right, 82)
        XCTAssertEqual(widths?.bottom, 88)
    }

    func testAndroid13ThreeButtonNavigationReturnsZeroes() {
        let snippet = """
              EdgeBackGestureHandler:
                mIsGesturalModeEnabled=false
                mEdgeWidthLeft=82
                mEdgeWidthRight=82
            """
        let widths = AndroidBackGestureEdges.parse(snippet)
        XCTAssertEqual(widths?.left, 0)
        XCTAssertEqual(widths?.bottom, 0)
    }

    /// 横向きは切り欠き側の inset が帯の幅に乗る(Pixel 4a の実測: mLeftInset=136 + 82 = 218)。縦向きの inset 0 は従来と同じ
    func testLandscapeInsetsAreAddedToTheBand() {
        let landscape = """
          EdgeBackGestureHandler:
            mIsGestureHandlingEnabled=true
            mEdgeWidthLeft=82
            mEdgeWidthRight=82
            mLeftInset=136
            mRightInset=0
          mLastReportedConfig=
        """
        let widths = AndroidBackGestureEdges.parse(landscape)
        XCTAssertEqual(widths?.left, 218)
        XCTAssertEqual(widths?.right, 82)
        let rotated = landscape.replacingOccurrences(of: "mLeftInset=136", with: "mLeftInset=0")
            .replacingOccurrences(of: "mRightInset=0", with: "mRightInset=136")
        XCTAssertEqual(AndroidBackGestureEdges.parse(rotated)?.right, 218)
        XCTAssertEqual(AndroidBackGestureEdges.parse(Self.gestureNavSnippet)?.left, 78, "inset の欄が無い版は従来どおり")
    }
}
