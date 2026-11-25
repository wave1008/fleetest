# home, back, appSwitcher, tapAppIcon, rotateTo, setAppearance, setTextSize, fold, unfold, hinge

[in English](navigation.md)

ホーム画面・戻る・アプリスイッチャー・ホーム画面のアイコン・画面回転・端末の外観と文字サイズ・折りたたみ端末の開閉など OS レベルの操作です。

## 関数

| 関数 | 説明 |
|---|---|
| `home()` | ホーム画面へ移動します。 |
| `back(settle:)` | 前の画面へ戻ります(Android = 戻るキー / iOS = ナビゲーションバーの戻るボタン、無ければ左端エッジスワイプ)。 |
| `appSwitcher()` | アプリスイッチャーを開きます。ホームボタンの iPhone(iPhone SE など)ではスイッチャーがハードのダブルプレスで送れないため、失敗にせず、この step 以降を対象外(skipped)としてシナリオを記録します。 |
| `tapAppIcon(name?)` | ホーム画面のアプリアイコンを探してタップします。`name` はホーム画面のアイコンの下に出る名前と**完全一致**で照合します。省略時はアプリプロファイルのその OS の `appName`(`ios.appName` / `android.appName`)です。 |
| `rotateTo(.portrait, settle:)` / `rotateTo(.landscape, settle:)` | 画面をその向きへ回します。値はこの2つだけです。書かずに全シナリオを横向きで回すなら、[実行プロファイル](../project/run_profile_ja.md)の `orientation` を使います。 |
| `setAppearance(.light)` / `setAppearance(.dark)` | **端末の**外観を切り替えて読み返し、読み返した値が指定と違えば失敗します(既にその値なら成功)。シナリオの終わりに light へ戻ります。 |
| `setTextSize(.small / .default / .large / .extraLarge / .accessibility)` | **端末の**文字サイズを切り替えて読み返し、読み返した値が指定と違えば失敗します(既にその値なら成功)。シナリオの終わりに `.default` へ戻ります。 |
| `fold(waitSeconds:)` | 折りたたみ端末を外側の画面へ畳み、デバイスが切り替わったと報告するまで待ちます(上限 `waitSeconds`・省略時は実行の既定タイムアウト)。切り替わらなければ失敗します。 |
| `unfold(waitSeconds:)` | 内側の(大きい)画面へ開きます。ルールは `fold` と同じです。 |
| `hinge(90)` | ヒンジ角を 0(閉じる)〜180(全開)で設定します。約 130 が半開きのブック姿勢です。どちらの画面が出るかは確かめません。 |

## setTextSize の段階

名前ごとに端末へ設定する値です。アプリに何が見えるか(どれだけ大きく描かれるか)はアプリ次第で、アプリが文字サイズに追従しない作りなら見た目は変わりません。

| 名前 | iOS の段階(`devicectl` に渡す名前) | iOS の `UIContentSizeCategory`(アプリが受け取る値) | Android の `font_scale` |
|---|---|---|---|
| `.small` | `small` | `UICTContentSizeCategoryS` | 0.85 |
| `.default` | `large`(iOS の標準) | `UICTContentSizeCategoryL` | 1.0 |
| `.large` | `extra-large` | `UICTContentSizeCategoryXL` | 1.15 |
| `.extraLarge` | `extra-extra-extra-large` | `UICTContentSizeCategoryXXXL` | 1.3 |
| `.accessibility` | `accessibility-large`(「より大きな文字」も有効) | `UICTContentSizeCategoryAccessibilityL` | 2.0 |

## 例

```swift
launchApp()
tap("#settings")
back()                  // 前の画面へ戻る
home()
tapAppIcon()             // アプリプロファイルの名前でアイコンを探してタップ
appSwitcher()
rotateTo(.landscape)
rotateTo(.portrait)
setAppearance(.dark)    // ダークモード(シナリオの終わりに light へ戻る)
setTextSize(.extraLarge)
fold()                  // 折りたたみ端末のみ
unfold()
hinge(130)              // 半開きのブック姿勢(引数のラベルは書かない。hinge(degrees: 130) はコンパイルエラー)
```

## 注意点

- **iOS の inapp-boost モード(既定)と Android では、`home()`・`appSwitcher()`・`tapAppIcon()`・`openURL()`・`launchApp(url:)`・`back()` の後は、アプリを前面へ戻してから操作します。** iOS では、テスト対象のアプリが前面に無い間(ホーム画面・別のアプリ・アプリスイッチャーが出ている間)は、アプリを読む・触る step(`back()` を含む)は
  いつもの待ち時間のあいだアプリが戻るのを待ち、戻らなければ見えないアプリへ操作せずに失敗します。
  Android のツリーは前面の画面そのものなので、同じ扱いになるのは「無い」で通ってしまう `notExist`・`countIs(0)`・`select`・条件の判定(`ifCanSelect` 等)と、
  別のアプリへ届いてしまうスクロールの送りだけです(それ以外の読み・操作は前面の画面に効きます。ホーム画面のアイコンを押す・読むこともできます)。断られたときの `failureKind` は `app-in-background`、アプリスイッチャーが開いている間は
  `system-ui-covered` です。`tapAppIcon()` か `launchApp()` で戻してください。
  `home()` 自体も、アプリが前面から外れたことを確かめてから終わります(外れなければ押し直し、3回押しても前面のままなら失敗します)。
- **`back(settle:)` の確実さは画面によります。** iOS では、システムのナビゲーションバーを持つ画面は
  決定的に戻れますが、フレームワーク独自のナビゲーション(自前描画のナビバー等)を持つ画面は
  エッジスワイプに落ち、これは interactive pop に対応している画面でしか成立しません —
  戻れない画面で `back(settle:)` を実行しないでください(代わりにアプリ内の戻るボタンを `tap()` します)。
  Android では、ソフトキーボードが開いていると1回目の `back(settle:)` はキーボードを閉じるのに
  消費されます(OS の仕様)。入力欄にフォーカスが残っている可能性があるときは2回呼んでください。
- **Android の `back()` は、そのアプリに戻れる画面が無いとアプリを抜けます。** ブラウザの新しいタブ(履歴が無い)で `back()` を呼ぶと、
  タブが閉じるのではなく前の画面のアプリへ移ります。タブを閉じる検証は、タブの一覧の閉じるボタンで書きます。
- `back()` の前後で画面が変わらなかったときは、ステップに注記(`the tree is identical to the one before back …`)が付きます(アプリ独自のナビゲーションが
  システムの戻る操作を無視している形)。ステップは失敗しません(注記が付くだけです)。
  対処は、アプリ自身の戻るボタンを `tap` するか、`back()` をもう一度呼ぶことです。
- **`back()` の注記はほかにもあります。** iOS で、戻るボタンが無く左端のスワイプに落ちた `back()` の後の画面が、前と同じ識別子の組のままのとき、ステップに注記 `back-stayed-on-screen` が付きます(スワイプが画面自身の中身に届いた可能性があります。どの画面に着いたか確かめてください)。失敗にはならず、識別子が3個未満の画面では(別の画面と見分けられないので)付きません。Android で、`back()` の後に前面のアプリがテスト対象のアプリでなくなったとき(アプリの最初の画面で戻るキーを押してランチャーへ抜けた形)は、注記 `back-left-app` が付きます。これも失敗にはなりませんが、続くステップは前面にあるものに対して動きます。シナリオを続けるなら `launchApp()` か `tapAppIcon()` でアプリを戻してください。続くステップが「別の窓がアプリの手前にある」という警告つきで失敗したときは、直前の `back()` がアプリを抜けたことがログに添えられます。同じく Android で、ソフトキーボードが出ていて `back()` がそれを閉じただけ(画面はそのまま)のときは、注記 `back-closed-keyboard` が付きます。戻すにはもう一度 `back()` を呼んでください。
- **`tapAppIcon` の探索順**: まず現在の画面を探し、見つからなければ Android はアプリドロワーを
  開いて `flickCenterToTop` で最大8回スクロール、iOS は `flickRightToLeft` で最大5ページ送り
  (2回連続不変化で打ち切り)します。iOS でホームのページに無いとき(App ライブラリにだけ入っている
  アプリ)は、送り切った先の App ライブラリの検索欄を押して出る名前順の一覧から開きます(一覧は行が見えるまで送ります)。その一覧に名前の無い行があるとき(iOS がアプリの名前を欠いたまま行を描くことがあります)は、App ライブラリの見えているカテゴリのフォルダも順に開いて探します。最後まで見つからなければ `"App icon not found.(name)"` で
  失敗します。アイコンは、位置が連続2回の画面読み取りで同じになってからタップします(動いている
  ドロワーやページはタップを飲むため)。アイコンが自分のアプリのものなら、その後アプリが前面に
  来るまで待ち、来なければ(再試行せずに)失敗します。
- **iOS の `tapAppIcon` は、ホーム画面の手前に出ているシステムアラートを名指して失敗します。** アラートが出ている間はツリーにアラートの中の要素しか載らないので、アイコンは見つかりません。アイコンがツリーに無く、アラートが手前に出ているときは、ページを送り続けずにアラートを名指して失敗します(`App icon not found.(name) — … is in front of the home screen, so the icons are not in the element list and the search was not run`)。シナリオの中でアラートに答えるか、アラートが出るステップの前に [`iosAlertHandler`](./ios_alert_handler_ja.md) を登録してください。
- **`tapAppIcon` は、ホーム画面のツリーが表示中の画面と一致しないときは実行しません。** iPhone Duo の Simulator と Xcode 27.2 RC の組み合わせで、内側の画面の配置がツリーに混ざる事象を確認しています。内蔵画面が2枚の Simulator ではツリーの画面の大きさを表示中の画面と照合し、違えば `the home screen tree reports a … screen but the shown display is …` で失敗します。アイコンの中心が画面の外に載っているときは画面の待ち時間まで読み直し、直らなければ `the home screen reports the icon outside the screen …` で失敗します(当たらない所へ送りません)。
- **Android の `tapAppIcon` は、中心が覆われた・枠が切れたアイコンを押さず、ホーム画面を離れたかも確かめます。** 名前が一致する要素のうち、中心が別の要素(ランチャーの検索バーなど)の下に無く、枠がリストの縁で切り詰められていないものだけを押すので、同名のアイコンが重複して出ても見えている側を押します。条件を満たすものが無ければドロワーを送って探し続け、最後まで無ければ別の物を押さずに `App icon not found.(name) (an icon with this name was on screen but its centre was covered …, so it was not tapped)` で失敗します。テスト対象以外のアプリでは、ランチャーが前面から離れるまで画面待ちの上限まで待ち、離れなければ `the home screen (<package>) stayed in the foreground … the tap did not start another app` で失敗します(iOS では固定 1.5 秒の待ちです)。
- **`terminateApp()`・`removeApp()`・`clearAppData()` で止めた後(アプリが動いていないとき)の iOS の扱い**(Simulator ではアプリが動いているかを確かめます。実機では確かめられないので、止めた後にアプリを起動しうる操作を挟んでいないときだけ同じ扱いになります。止めた後は `launchApp()` で起動するのが確実です): `back()` は実行せずに失敗します(`back()` はアプリを起動してしまいますが、人は動いていないアプリへ「戻る」ことはできません)。`launchApp()` か `tapAppIcon()` で起動してください。inapp-boost モードの `tapAppIcon()` は、アイコンを見つけた後、押す代わりにアプリを起動し、ステップに注記(`the app was not running, so after finding its icon this launched the app …`)が付きます(アイコンから起きたアプリには inapp-boost モードの操作の口が載らず、後の手順が全部届かないため)。アプリが背面で動いているだけなら、これまでどおりアイコンを押します。inapp-boost モードでは、ほかの操作(`rotateTo` など)も、止めたアプリを起動せずに `The app under test (…) is not running — this scenario stopped it — so this step was not sent` で失敗します。
- **`rotateTo` が契約するのはアプリの UI の向き**であって、実機の傾きではありません —
  シナリオが読む frame はアプリ座標系で、iOS / Android のどの UI フレームワークでも同じ意味で
  振る舞います。値は `.portrait` / `.landscape` の2つだけです(左右の区別はありません)。
- `rotateTo` は向きが実際に変わるまで待ってから返ります。
- **回転を使ったシナリオは終了時に元の向きへ自動で戻ります**(Android は自動回転の設定も
  戻します)。
- **アプリがその向きを許可していないと回りません**(iOS の
  `UISupportedInterfaceOrientations`、Android の `screenOrientation`)。
  Android は前面のアプリがその向きを禁じていれば待たずに失敗し、理由にアプリの宣言を示します。
- このコマンドで回すあいだ、Android は自動回転を切ります(切らないと角度が保持されません)。
- **`settle: false`** を渡すと、このコマンドの操作後の「画面が落ち着くまでの待ち」を省きます(次のステップは動いている最中の画面を見ることがあります)。詳細は [tap](./tap_ja.md) 参照。
- **`setAppearance` / `setTextSize` は端末全体を変え、シナリオごとの終わりに元へ戻ります。** 各シナリオの終わりにツールが端末をライト・標準の文字サイズ(`.default`)へ戻します(戻せなければ実行ログに警告を出します)。全シナリオをダークモードや大きい文字で回すなら、代わりに[実行プロファイル](../project/run_profile_ja.md)の `appearance` / `textSize` を使います。
- **`beforeRun()` / `afterRun()` / `setUpDevice()` / `tearDownDevice()` / `beforeAll()` / `afterAll()` の中では使えません。** 各シナリオの後に基準の状態(ライト・標準の文字サイズ)へ戻すので、そこで変えても最初のテストにしか効きません。ステップはその旨のメッセージで失敗します。run 全体に効かせるなら実行プロファイルの `appearance` / `textSize` を使います。dry-run では端末を変えません。
- **`beforeEach()` / `afterEach()` の中では使えます。** テストごとに走るので、クラスの全テストに効きます。
- **画面が作り直されることがあります(多くは Android)。** アプリが `configChanges` に `uiMode`(`setAppearance`)や `fontScale`(`setTextSize`)を宣言していないと、表示中の Activity が破棄されて作り直され、メモリにだけ持っている状態は失われます。シナリオの終わりに戻すときも同じです。画面の状態を保存しないアプリは、そのとき最初の画面に戻ります。表示条件はシナリオの最初(目的の画面へ移る前)に変えるか、変えた後にアプリを起動し直して目的の画面を開き直してください。**Android に限りません。** React Native の iOS(iPad)でも、`setAppearance` / `setTextSize` の後にアプリがホームへ戻ったことがあります(観測1件)。OS・フレームワークを問わず、目的の画面へ移った後で変えたときは、変えた後に `launchApp()` で開き直してください。
- **MCP(`ft_run_scenario`)の確認では、アプリへ外観が届いたかを確かめません。** `ft_run_scenario` は iOS では XCUITest で走る(`xcuitest` モード相当)ので、端末は dark なのにアプリが light のままの Simulator の状態があっても検出しません。端末は dark なのにアプリが light のままなら、Simulator がアプリへ設定を届けていない状態です。本番の run(`inapp-boost`)は `display-not-applied` で検出して回復します(次の項目)。
- **ステップが確かめるのは端末の設定値で、アプリの表示ではありません。** 配色を外観に追従させないアプリは、ダークにすると背景だけ暗くなって文字が読めなくなり、テキストの可視性検証がステップを失敗にします(正しい失敗です。アプリの配色を確かめてください)。
- **iOS の `inapp-boost` モードでは、アプリが設定を受け取ったかも確かめます。** `launchApp()` / `restartApp()` の直後と `setAppearance` / `setTextSize` の後に、アプリが受け取っている外観と文字サイズを in-app ブリッジに聞き、一致するまで最大 5 秒待ちます。一致しなければそのステップは `failureKind=display-not-applied` で失敗し、次のシナリオの前にその Simulator の SpringBoard を再起動して(動いていたアプリと XCUITest ブリッジも一緒に再起動します)実行ログに残します。`fleetest run` では、失敗したシナリオの結果を捨てて1回だけ回し直します(同じ Simulator なら再起動の後に回ります)。回し直しても届かなければ失敗のまま残ります。実機の iPhone は再起動せず、ステップが失敗するだけです。`xcuitest` モードと Android では、端末の設定値だけを確かめます。
- **文字サイズの名前は各 OS の段階に対応します(表は上の「setTextSize の段階」)。** iOS: `.small` = `small`・`.default` = `large`(iOS の標準)・`.large` = `extra-large`・`.extraLarge` = `extra-extra-extra-large`・`.accessibility` = `accessibility-large`(「より大きな文字」も有効にし、シナリオの終わりに元の値へ戻します)。Android: `font_scale` が 0.85 / 1.0 / 1.15 / 1.3 / 2.0 で、Android 14 以降は OS が文字を非線形に拡大するので、見た目の大きさの比は倍率と一致しません。確かめた環境は iPhone の実機(iOS 26.6.2)・iOS 27.2 の Simulator・Android の Emulator と実機です。
- **`fold` / `unfold` / `hinge` は折りたたみ端末が必要です。**
  - iOS: iPhone Duo の **Simulator**(Xcode 27.2 以降)。XCUITest ブリッジ経由で送るので、どちらの iOS モードでも使えます。
  - Android: 折りたたみの **Emulator**(ヒンジセンサー付きの AVD。Pixel 9 Pro Fold など)。
  - iOS の実機は開閉を送れず状態も読めないので、そのシナリオを対象外(skipped)として記録します(理由は `fold / unfold / hinge cannot drive a physical iPhone (fold it by hand); they run on the iPhone Duo simulator`)。
  - Android の実機は、折りたためない機種なら下の対象外の扱い、折りたたみの機種なら非対応(手で畳んでください)の文言でステップが失敗します。
- **折りたためないデバイスでは、失敗にせず、この step 以降を対象外(skipped)としてシナリオを記録します**(ホームボタンの iPhone での `appSwitcher()` と同じ扱い)。理由は `fold / unfold / hinge need a foldable device (the iPhone Duo simulator or a foldable Android Emulator)` です。`setUpDevice()` の中で対象外になったときは、同じデバイスで流れる同じクラスの残りのテストも同じ理由の対象外になります。
- **対象外のシナリオは、同じ run のまだ試していないデバイスへ回し直されます。** シナリオが対象外を宣言したとき(折りたためないデバイスでの `fold()`・ホームボタンの iPhone での `appSwitcher()`)、その結果はすぐには確定せず、同じ run の同じ OS のデバイス(同じマシンの別のデバイスか別のマシンのデバイス)のうち、まだ試していないものへ回されます。対象外(skipped)として記録されるのは、その OS のデバイスが全部試して対象外だった場合と、その run に他の同じ OS のデバイスが最初から居なかった場合だけです。試していないデバイスが run から落ちた(合流できなかった・離脱した)ときは、何も実行しないまま通る代わりに**失敗**(`not run: …`)として記録されます。1台に寄せるクラス(`@RunInOrder` / `@RunOnSingleDevice`)は別のデバイスへ動かさず、`@RunOnSingleMachine` は同じマシンの中だけで回し直します。捨てた試行は run の再実行の一覧に載ります。
- **`beforeAll()` の中では、対象外にならず失敗します。** `beforeAll()` は run に1回、そのクラスの最初のシナリオを受け取ったデバイスで走り、別のデバイスでは走り直さないためです。`fold()` / `unfold()` / `appSwitcher()` のようにデバイスで結果が変わる準備は `setUpDevice()` に書きます(デバイスごとに走り、対象外ならそのデバイスのそのクラスのシナリオが対象外になります)。
- **折りたたみ状態はシナリオ終了時に自動で元へ戻ります**(`rotateTo` の向きと同じ)。戻すのはシナリオで最初に `fold` / `unfold` / `hinge` を呼ぶ前の状態です。
- **`fold()` / `unfold()` を既にその状態で呼んでも失敗しません。** 呼ぶ前に状態を読み、そのまま信号を送って、その状態になっていることを確かめて通ります。
- **`setUpDevice()` で `unfold()` した状態は、クラスの2本目以降のテストには残りません。** `setUpDevice()` は、デバイスで最初に走るテストのプロセスの中で走り、シナリオの終わりの戻しがそのテストの後に開閉を元へ戻します(2本目以降は元の状態で始まります)。全テストを開いた画面で始めるなら `beforeEach()` に `unfold()` を書きます。
- **Android の折りたたみ機は、閉じるとアプリの上にロック画面(「上にスワイプで続行」)が出ます。** `fold()` はそれを外してアプリを外側の画面に出してから次へ進みます(画面ロックの解除と同じ操作。PIN やパターンのロックは外せません)。
- **`hinge` はどちらの画面が出るかを確かめません。** iPhone Duo の Simulator は切り替わりが直前の状態に依存します(実測: 開く方向は 120° と 150° の間、閉じる方向は 20° と 10° の間で切り替わる)。折りたたみ Android の Emulator は姿勢が角度の範囲で決まります(Pixel 9 Pro Fold の AVD: 0〜30 が閉じ・30〜150 が半開き・150〜180 が開き)。特定の画面が要るシナリオは `fold()` / `unfold()` を使ってください。
- **iOS の仕組み**: Simulator を畳む公開 API は Apple にありません。fleetest は Xcode の DeviceHub と同じ非公開のヒンジイベントを送ります。将来の Xcode が受け付けなくなる可能性がありますが、`fold` / `unfold` は切り替わりを確かめるので、その場合は黙って通らず失敗として表に出ます。
- **iPhone Duo の Simulator は開くと落ち続けることがある**: `unfold()` の後に、Simulator のホーム画面(SpringBoard)とキーボードのプロセスが十数秒おきに落ちて起き直すことがあります(iOS 27.2 の Simulator の不具合)。起き直す間はアプリが背景に回り、キーボードも消えます。その間のステップは、キーボードが無いので `hideKeyboard()` が何もせずに通る、のように欠けた画面を相手にします。落ちていたシナリオのレポートには、落ちた回数・時刻・報告ファイルが載ります。開いた画面で検証するときは、操作の後に `keyboardIsNotShown()` などで結果を確かめてください。落ち続けて Simulator が応答しなくなったときは、run はその Simulator を止め、その run では使わずに残りのデバイスで続けます(次の run で起動し直します)。

### Link
- [index](../../index_ja.md)
