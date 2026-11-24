// コーパスの各フィクスチャが「どの UI フレームワークのアプリか」の表(DR-230)。
// 利用者へ見える警告の経路(`RefGuard.overlapWarning` = 覆いの名指しの出口)は、アプリの UI フレームワークと
// OS を渡されて初めて名指しを止める。コーパスの数え方(`SweepHarnessTests.counts`)は幾何の件数なので
// フレームワークを渡さない。出口の件数は `SweepHarnessTests.namedOverlayCount` が表を通して測る。
//
// **推定(当時の APK が無い)**: Google マップ・Chrome・設定・電話などの Android の標準アプリは View 系と見なして
// `.androidView` を置いた。標準アプリは Compose / View が混在し得るので、この値は出どころの申告ではない。
// 名指しを止める側(`.flutter`)ではないので、推定が外れても件数は動かない(Flutter 以外は常に名指す)。
// iOS は OS が iOS で名指しは止まらないので nil。
// **フィクスチャを足したらここにも足す**(testEveryFixtureHasAFrameworkEntry が食い違いを検出)。

import XCTest
import FTCore
import FTTestSupport

enum RealAppSnapshotFrameworks {
    static let table: [String: AppUIFramework?] = [
        "and-apps_list": .androidView, // 推定: 当時の APK が無い
        "and-browser_error_page": .androidView, // 推定: 当時の APK が無い
        "and-browser_j1_standings": .androidView, // 推定: 当時の APK が無い
        "and-browser_jma_notree": .androidView, // 推定: 当時の APK が無い
        "and-browser_urlmenu": .androidView, // 推定: 当時の APK が無い
        "and-browser_weather": .androidView, // 推定: 当時の APK が無い
        "and-browser_weather_weekly": .androidView, // 推定: 当時の APK が無い
        "and-browser_weektable": .androidView, // 推定: 当時の APK が無い
        "and-camera_canvas": .androidView, // 推定: 当時の APK が無い
        "and-dialer_keypad": .androidView, // 推定: 当時の APK が無い
        "and-dialog_confirm": .androidView, // 推定: 当時の APK が無い
        "and-directions_tabs": .androidView, // 推定: 当時の APK が無い
        "and-e2e_input_keyboard_resized": .androidView, // 確定
        "and-flutter_fab": .flutter, // 確定
        "and-flutter_hide_bars": .flutter, // 確定
        "and-form_keyboard": .androidView, // 推定: 当時の APK が無い
        "and-home": .androidView, // 推定: 当時の APK が無い
        "and-maps_suggest_ime": .androidView, // 推定: 当時の APK が無い
        "and-maps_transit_results": .androidView, // 推定: 当時の APK が無い
        "and-overflow": .androidView, // 推定: 当時の APK が無い
        "and-place": .androidView, // 推定: 当時の APK が無い
        "and-place_expanded": .androidView, // 推定: 当時の APK が無い
        "and-results": .androidView, // 推定: 当時の APK が無い
        "and-settings_root": .androidView, // 推定: 当時の APK が無い
        "and-sutec_home": .compose, // 確定
        "ios-browser_j1_standings": nil, // iOS(名指しは止まらない)
        "ios-browser_jma_hscroll": nil, // iOS(名指しは止まらない)
        "ios-browser_nationwide": nil, // iOS(名指しは止まらない)
        "ios-browser_startpage": nil, // iOS(名指しは止まらない)
        "ios-browser_weather_weekly": nil, // iOS(名指しは止まらない)
        "ios-browser_weektable": nil, // iOS(名指しは止まらない)
        "ios-browser_yahoo_top": nil, // iOS(名指しは止まらない)
        "ios-home": nil, // iOS(名指しは止まらない)
        "ios-maps_route_options": nil, // iOS(名指しは止まらない)
        "ios-maps_station": nil, // iOS(名指しは止まらない)
        "ios-maps_suggest_guides": nil, // iOS(名指しは止まらない)
        "ios-maps_suggest_keyboard": nil, // iOS(名指しは止まらない)
        "ios-maps_transit_boarding_cards": nil, // iOS(名指しは止まらない)
        "ios-maps_transit_steps": nil, // iOS(名指しは止まらない)
        "ios-maps_transit_steps_expanded": nil, // iOS(名指しは止まらない)
        "ios-messages_keyboard": nil, // iOS(名指しは止まらない)
        "ios-news_feed": nil, // iOS(名指しは止まらない)
        "ios-photos_grid": nil, // iOS(名指しは止まらない)
        "ios-place": nil, // iOS(名指しは止まらない)
        "ios-place_guides_scrolled": nil, // iOS(名指しは止まらない)
        "ios-profile": nil, // iOS(名指しは止まらない)
        "ios-safari_article": nil, // iOS(名指しは止まらない)
        "ios-settings_root": nil, // iOS(名指しは止まらない)
        "sut-cmp_controls": .compose, // 確定
        "sut-cmp_home": .compose, // 確定
        "sut-e2e_noid": .compose, // 確定
        "sutec-calendar_day": nil, // iOS(名指しは止まらない)
        "sutec-detail": nil, // iOS(名指しは止まらない)
        "sutec-home": nil, // iOS(名指しは止まらない)
    ]

    static func isAndroid(_ name: String) -> Bool { name.hasPrefix("and-") }
}

final class RealAppSnapshotFrameworksTests: XCTestCase {
    func testEveryFixtureHasAFrameworkEntry() throws {
        let names = try RealAppSnapshotCorpus.all().map(\.name)
        XCTAssertEqual(Set(names), Set(RealAppSnapshotFrameworks.table.keys),
                       "フィクスチャとフレームワーク表が食い違っている(表に無い: "
                       + "\(Set(names).subtracting(RealAppSnapshotFrameworks.table.keys).sorted()) / 実体が無い: "
                       + "\(Set(RealAppSnapshotFrameworks.table.keys).subtracting(names).sorted()))")
    }
}
