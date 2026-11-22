# 性能: 実測の記録

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 記録 | 個別の実測(ブラウザ DOM・実機 iOS の tap・xcuitest のスクロール探索)とドライバ改良の A/B 再計測・表示設定と devicectl / simctl の所要(PT-9〜13) | 過去の実測を確かめるとき | 調整ノブと現在の既定(→ [guide.md](guide.md)) |

現在の仕様ではない。日付はその時点のもの。

## PT-9 ブラウザ DOM の snapshot が 9.5 秒だった(2026-08-14)

**凍った背面タブに評価と同じ締切を払っていた。** Chrome は背面タブの JS を止めるので、
その相手は**待っても絶対に答えない**。にもかかわらず候補ごとに 3 秒(`evaluateTimeout`)を
使い切っており、上限3候補で最悪 9 秒を捨てていた。

実測(同一ページ・同一端末・DOM の on/off を交互に3ブロック × 各5回。
Android はセッション内で劣化するのでドリフトを相殺する並べ方にした):

| | 修正前 | 修正後 |
|---|---|---|
| DOM オン | **中央値 9481ms** | **中央値 1430ms** |
| DOM オフ(a11y のみ) | 126ms | 126ms |

**直し方は「生死の判定を評価から分ける」だけ**。`1+1` を `livenessTimeout`(0.4 秒)で撃ち、
答えたタブにだけ本命の JS を撃つ。タブごとの実測は **生きている1つが 11ms・
凍った 18 個が 3005ms** で、生死の判定に 3 秒は要らない。

**残る 1.3 秒の内訳は未測定**(adb forward の張り直し・`/json`・WebSocket 接続・
生死の1往復)。測る前に切らない。

## PT-10 実機 iOS の tap の内訳と起動時注入(2026-10-21 実測・iPhone SE3 / iOS 26.6.2)

**XCUITest の1操作の往復**(ホストから USB 経由・各30回の中央値・ランナーを起動し直した直後):
`/status` 5.8ms・`/snapshot` 54.6ms・**`/tap` 415.0ms**。所要のほとんどは tap。
起動から1時間44分たったランナーでは tap 476.6ms・snapshot 64.2ms(1回の観測。プロセスの寿命との関係は未確認)。

**tap の直接合成**(`XCSynthesizedEventRecord` を `eventSynthesizer` で送る。`XCUICoordinate.tap()` を経由しない):
接触 0.05s で 295.4ms(−29%)・**0.01s で 243.6ms(−41%)**。接触時間を 40ms 縮めると 52ms 縮むので、
残りの約 230ms は合成の往復そのもの(デーモン側の固定費。ツールからは削れない)。**採用は 0.05s**。
0.01s の接触は SwiftUI・Compose Multiplatform・Flutter・React Native の4 SUT すべてでボタンの押下と画面遷移として
拾われたが、**実機の SwiftUI の `Toggle`(UISwitch)を反転させない回があった**(E2E-iOS の `画像で要素を探す.S0010` を
XCUITest で各6回: 0.01s で SE3 4/6・iPhone 13 5/6 が赤 → 0.05s で両機 6/6 緑。`coordinate.tap()` に戻すと SE3 6/6 緑。
Simulator の E2E は in-app で回るのでこの経路を通らず、実機を回すまで出なかった)。下の v200・v204 の正味は 0.01s での値。
**直接合成は XCTest の割り込み監視を通らない** —— 写真の権限アラートの「許可しない」の座標へ撃つと、
`coordinate.tap()` は 422 で触れないのに対し、直接合成(既存の `/doubletap` を含む)は 200 でボタンを押した
(Simulator で実測)。直接合成の送る口ではシステムアラートを自分で確かめる(`SystemAlertProbe`)。
**採用した形の正味**(同じビルドを環境変数で切り替え、ランナーを毎回起動し直し、他の SUT を止めた同じ状態で ABAB):
- v200(直接合成 + アラートの確認。向きは `app.frame`): `coordinate.tap()` 411.7 / 413.4ms → 363.5 / 366.5ms(−11.5%)。
  ハンドラの中の内訳(SE3・12回): アラートの確認 100〜130ms(1回目。続けて撃つと 2回目は 60〜80ms = quiescence を飛ばしても
  変わらない)・`app.frame` 20〜45ms・`app.state` 0ms(取得済みの値)・`XCUIDevice.orientation` 1〜5ms・合成 約 190ms。
  **アラートの確認は `coordinate.tap()` の中の割り込みの確認と同じ仕事なので、直接合成で浮いた分の大半はここで払い直している**
- v204(向きは非公開の `interfaceOrientation`・操作の前の待ちを両方の経路に足した形): `coordinate.tap()` 448.4 / 458.8ms →
  377.8 / 379.4ms(−16〜17%)。**main(v199)の tap 412ms に対する正味は約 −8%**(操作の前の待ちの分だけ両方が重くなった)

**直接合成の座標は主画面の本来の向き(portrait)**: `XCSynthesizedEventRecord` の `interfaceOrientation` を
どの値にしても点は回らない(横向きの木の座標をそのまま送ると1〜4のどれでも外れた)。木の座標をアプリの
インターフェースの向き(XCUIApplication の非公開 `interfaceOrientation`)で portrait へ回してから送る
(`CoordinatePinch.nativePoint(_:interface:)`。landscapeRight = (幅 − y, x) を非対称な的で確かめた。
landscapeLeft・upsideDown の式は対称性からで未実測 = /rotate はデバイスを landscapeLeft にしか回さない)。
それまで横向きの doubleTap・長押し・ピンチ・`gesture` は点がずれていたことになる(main では再現していない)。
**計測の罠**: 他の SUT を起動したまま背面に残すと tap が約 45ms 遅くなり(v200 が 409.9ms)、差が消えて見えた。
A/B は端末の状態を揃えてから測る。

**実機の起動時注入は成立する**: 開発署名(`get-task-allow`)の SUT に、**同じチームの証明書で署名した dylib** を
`devicectl device copy to --domain-type appDataContainer` でアプリのデータコンテナ(`tmp/`)へ置き、
`devicectl device process launch --environment-variables '{"DYLD_INSERT_LIBRARIES":"<コンテナの絶対パス>/tmp/<dylib>"}'`
で起動すると、constructor が走ってマーカーを書いた(書いた pid = 動いているアプリの pid)。環境変数なしの起動では書かれない(陰性対照)。
**アプリのビルドし直しも再署名も要らない**。コンテナの絶対パスは `device copy to --json-output` の `destination` から得られる。
**本実装済み(2026-10-22・開発署名のアプリのみ)**: inapp-boost モードを実機でも選べる(
docs/design/ の該当節)。署名は `InAppCodeSign`・配置と起動は `InAppLauncher` の physical 経路・到達は
XCUITest 実機と同じ `IOSDeviceTransport`。プロセス内のタッチ合成も実機で効くことを SE3 で確認(タップ・ジェスチャ・型入力)。

## PT-11 xcuitest のスクロール探索スループット(2026-08-08 実測・未着手の較正候補)

E2E の 07 S0060(scrollFrame 指定で #row_40 到達 + 行タップ3回)の実測:
**CMP 25.5s / Flutter 38.6s / RN 56.2s(±0.2, n=3)/ SwiftUI 72.0s**。
RN 固有ではなく xcuitest モード一般の構造で、内訳は「1周(スワイプ+整定+snapshot)≈2s ×
周回数」。周回数は 移動距離 ÷ 刻み(容器×マージン 0.2/0.2 ≈ 0.6 掛け)で決まる。

較正候補(どちらもグローバルノブ = **全 SUT の実測を添えてからでないと回さない**):
1. scrollFrame の刻みマージンを 0.2/0.2 → 0.15/0.15(1周の移動 +17%)。飛び越しは
   travelCeiling の自己補正が受けるが、見切れ発見率が上がる(= clipRecoveryJump の
   出番が増える)ため相殺量は要実測
2. 探索周回の settle を「木の署名が動いた周だけ」二段待ちにする(現在は毎周)

なお 2026-08-08 の飛び越しフレーク3レバー(横逆走査・clipRecoveryJump・弾切れ時逆走査)は
失敗経路の追加であり、上の正常系スループットには影響しない(S0060 は前後とも 56s)。

## PT-12 ドライバ改良の効果の A/B 再計測(2026-07-21)


実施日: 2026-07-21 / 対象: main(PR #1 マージ後の HEAD)

### 目的

Appium 比較 PoC 由来のドライバ改良(PR #1)が main 上で期待どおりの効果を出しているかを、
マージ後のバイナリで再計測して確認する。

### 計測条件

- 専用シミュレータ iPhone 17 Pro(iOS 27.0 / 24A5390f)を新規作成・単独使用
  (フリート6台は起動中だがアイドル。負荷は全系統に等しく乗る)
- シナリオ4本(タブナビ25step・カート追加15step・検索絞り込み8step・ログイン3テスト29step)
- 各系統 warmup 1 + 計測 2。計測は wall(ハーネス側)と step NDJSON(FT_EVENT_LOG_PATH)
- **全36ラン失敗ゼロ**・計測ばらつき ±0.3s 以内
- 改良オフ側は `FT_NO_FAST_LAUNCH=1`(fast launch 無効)で同一バイナリ内 A/B

### 結果1: シナリオ全体(wall 中央値・秒)

| シナリオ | inapp-boost | xcuitest(改良on=既定) | xcuitest(改良off) | 改良効果 |
| タブナビ | 7.5 | **11.5** | 13.3 | **−14%** |
| カート追加 | 7.2 | **9.6** | 11.3 | **−15%** |
| 検索絞り込み | 4.5 | **6.8** | 8.6 | **−21%** |
| ログイン(launch×3) | 15.2 | **23.5** | 28.6 | **−18%** |

- xcuitest の改良効果(fast launch)は同一バイナリ A/B で **−14〜21%** を再現
- inapp-boost モードのログイン 15.2s は改良前ベースライン(bench-6: 18.9s)比 **−20%**
  (inapp type の Compose 対応の効果。同一ランタイム・専用シミュレータ条件)

### 結果2: 操作単位(step 中央値・ms)

| 操作 | inapp-boost | xcuitest(改良on) | xcuitest(改良off) |
| launch(アプリ再起動) | 2,480 | **3,467** | 5,208(fast launch で −33%) |
| type | **266**(in-app 直接挿入) | 1,176 | 1,172 |
| tap | 126 | 406 | 416 |
| exist | 6 | 36 | 36 |

- **inapp-boost モードの type 266ms** = inapp の Compose 対応が main で機能している実証
  (従来は XCUITest attach 経由で 1.0〜1.3s だった)
- tap/exist は改良対象外のため on/off で一致(計測系の公平性の傍証)

### 判定

**マージされた改良は main 上で期待どおり機能・効果を再現している。**

| 改良項目 | 期待(改良ブランチでの実測) | 検証結果 |
|---|---|---|
| fast launch 既定化 | シナリオ −14〜19% | ✅ −14〜21% |
| inapp type の Compose 対応 | ログイン系 −19%・type 約1/4 | ✅ −20%・266ms |
| 安定性 | 失敗ゼロ | ✅ 36/36 成功 |

### 再現手順

```bash
# 専用シミュレータ+verify 用の実行プロファイル(runs/ios-verify-xcuitest.json 等)を用意して
FT_EVENT_LOG_PATH=<file> fleetest run --project sut-ec-mobile \
  --profile <ios-verify-xcuitest|ios-verify-inapp-boost> --scenario <シナリオ> --skip-build
# 改良オフ側: FT_NO_FAST_LAUNCH=1 を前置
```

計測口の詳細は PT-4、改良の経緯・不採用判断は同 PT-6/PT-7 と
`poc/appium-driver-benchmark` ブランチの docs/poc-appium-benchmark.md を参照。

## PT-13 端末の表示設定と、iOS Simulator での devicectl と simctl の所要(2026-11-22 実測)

確認環境: macOS 27.2.1・Xcode 27.2・M2 Ultra・iOS Simulator(iPhone 17・iOS 27.2 のランタイム)・iOS 実機 SE3(iOS 26.6.2・USB)・
Android Emulator(API 37)・Pixel 4a(API 33・USB)。**静かな機械で1台ずつ**(他の run・負荷なし)。5回(一部3回)の値。

**Xcode 27.2 の `devicectl` は iOS Simulator にも使え、同じ操作の `simctl` より約3倍速い。** 並列の run(E2E)の最中は未計測。8台へ同時に呼んだときは下の追試(`devicectl` はほとんど伸びない)。

| 操作(Simulator) | simctl | devicectl |
|---|---|---|
| 外観 + 文字サイズの設定 | 1.3 秒(`ui appearance` と `ui content_size` が各 0.6。同じ値でも 0.55。起動直後の1回目は 6.2) | 0.2〜0.3 秒(`device settings appearance` の1コマンド) |
| 外観の読み取り | 0.5 秒(`ui appearance`) | 0.26 秒(`device info appearance`) |
| 入っているアプリの一覧 | 0.5〜0.6 秒(`listapps`。初回 2.1) | 0.16〜0.21 秒(`device info apps`。初回 0.59) |
| プロセスの一覧 | 0.7〜0.9 秒(`spawn launchctl list`) | 0.26〜0.29 秒(`device info processes`) |
| スクリーンショット | 0.82〜0.89 秒(`io screenshot`) | 0.53〜0.55 秒(`device capture screenshot`) |
| URL を開く | 0.6〜0.9 秒(`openurl`。1回 3.1) | 0.19〜0.32 秒(`device process openURL`) |
| 向きの読み取り | — | 0.15 秒(`device orientation get`。初回 0.46) |
| データコンテナの場所 | 0.6〜0.9 秒(`get_app_container`) | (対応する口なし) |
| アプリを止める | 0.47〜0.61 秒(`terminate`) | `device process terminate` は pid が要る(一覧と合わせると差が無い) |

表示設定(外観・文字サイズ)の実地:

- iOS の実機・Simulator とも `devicectl device settings appearance --device <udid> --mode <light|dark> --text-size <段階名>` で、
  前面のアプリがその場で反映した。実機 SE3 は 0.27〜0.32 秒。
- iOS で accessibility の段階(`accessibility-large` 等)を設定するには `--larger-accessibility-sizes on` が要る。無いと
  「Enable Larger Accessibility Sizes on the device before setting an accessibility text size」(CoreDeviceError 21063)で失敗する。
  同じコマンドで `--larger-accessibility-sizes on --text-size accessibility-large` を渡すと 0.31 秒で効いた(SE3)。
- `devicectl device settings appearance` のヘルプは対応の条件を「(if supported)」としか書かない。効く最低の iOS の版は不明。
- Liquid Glass の項目は版で変わる: SE3(iOS 26.6.2)は「Clear / Tinted Liquid Glass」の2種類、Simulator(iOS 27.2)は
  「Liquid Glass」1種類と不透明度(50%)。
- Android は `cmd uimode night yes|no` と `settings put system font_scale <倍率>` の2つで、Emulator 0.08〜0.16 秒・
  Pixel 4a 0.15〜0.30 秒。Android 13(Pixel 4a)でも `font_scale 2.0` が効いた(設定画面の上限は 1.3)。
  `am get-config` の構成の文字列には倍率が出ない(画面で確かめた)。

同時に呼んだとき(2026-11-22 追試。同じ機械・iPhone 18 Pro の Simulator 8台・iOS 27.2・ブリッジなし。8台へ同じ操作を同時に撃つのを
5ラウンド。1台あたりの所要の中央値 / 最大):

| 条件 | devicectl 読み取り | devicectl 設定 | simctl ui 読み取り | simctl ui 設定(外観 + 文字サイズ) |
|---|---|---|---|---|
| モニター停止(`monitor pause`) | 0.27 / 0.34 | 0.39〜0.46 / 0.67 | 3.63 / 3.80 | 1.60〜4.43 / 5.39 |
| モニターが8台を配信中(load average 約 500) | 0.97 / 2.08 | 0.45〜0.65 / 1.42 | 8.71 / 21.83 | 17〜20 / 31.94 |
| 実機 SE3 + Simulator 8台を同時(モニター停止) | 0.22 / 1.20 | 0.57〜0.72 / 1.44 | — | — |

- **`devicectl` は同時に呼んでもほとんど伸びない。`simctl ui` は同時に呼ぶと桁で伸びる**(1台 0.5〜0.6 秒 → 8台同時で数秒〜30 秒)。
- 同時に設定した直後に `simctl ui` で読み返すと、4回とも8台すべて設定どおり(`devicectl` が反映を待たずに返っているのではない)。
- 繰り返し切り替えても PosterBoard の落ちた記録(.ips)は 0 件。
- `devicectl` の `--timeout` は整数の秒だけ(0.1 などは「invalid」で終了コード 64)。
- `devicectl` を途中で強制終了した場合: 要求が届く前(0.03・0.08 秒)なら反映されず、届いた後(0.15 秒)なら止めた時点で反映済み。
  3 秒後に遅れて反映されることは無かった。
- CoreDevice が詰まった状態は人工的に起こせなかった(過去の記録では SE3 で 60〜170 秒応答しなかった = MN-50.4 の周辺)。
- 並列の run(E2E)の最中には測っていない。上の「モニターが8台を配信中」は、負荷の高い状態の代わりとして読む。

`simctl` を `devicectl` に置き換える候補(2026-11-22 時点で未着手。並列の run の最中の計測が先。8台同時の単独の計測では `devicectl` は伸びなかった):

- 速くする余地がある経路: DSL の `openURL` / `launchApp(url:)` の Simulator 側(実機は既に `devicectl`)・凍結の監視
  (`DisplayFreezeWatch`)とモニターのブリッジの無い Simulator の撮影(`io screenshot`)・アプリの生死の照会
  (`SimulatorAppProcess` の `launchctl list`。失敗の切り分けと回復の経路)・`ft_list_apps`(`listapps`)。
- 置き換えても速くならない経路: 起動・起動前の検査は既に CoreSimulator を直接呼んでいる(`simctl get_app_container` 703ms → ほぼ 0ms。
  launch の内訳は PT-3)。止める操作は pid が要るので差が無い。
- 撮影は `SimulatorActiveDisplay` が画面の選択(iPhone Duo の複数の画面)を `simctl io` の引数で渡しているので、`devicectl` で同じ
  選択ができるかを先に確かめる。
