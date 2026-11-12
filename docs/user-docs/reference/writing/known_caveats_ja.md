# 注意事項の一覧

[in English](known_caveats.md)

シナリオを書く前に、このページを必ず読んでください。各行は、そのコマンド・部品を使うときに気をつけることの要約で、リンク先に詳しい説明と書き方があります。
黙って誤る(緑のまま正しくない)ものは特に注意してください。該当するコマンドや部品を使うときは、リンク先の節も開いて確かめます。

## コマンド

### アプリの検証(appIs)
- [bundle ID / package 名を直接書く](../commands/app_assertion_ja.md#注意点) — ニックネーム機構は無いので、`appIs` には bundle ID / package 名をそのまま渡します。
- [iOS の失敗メッセージには前面の bundle ID が出ない](../commands/app_assertion_ja.md#注意点) — Android は実際の前面 package 名が出ますが、iOS では取得できないので文言から実際のアプリは分かりません。
- [Android で前面アプリを読めない間は待ち続ける](../commands/app_assertion_ja.md#注意点) — `waitSeconds` まで読めなければ「読めなかった」という失敗になります。

### ifCanSelect, ios, android
- [ifCanSelect は既定で即時1回の判定](../commands/branch_ja.md#注意点) — 遅れて出る要素を待つなら `waitSeconds:` を渡さないと「無い」と判定されます。
- [ifCanSelect は出るか不定の画面の無害化に使う](../commands/branch_ja.md#注意点) — 出るか不定のダイアログやバナーの分岐は、専用の引数が無いので常に `ifCanSelect` で書きます。
- [ifCanSelect はスクロールして探さない](../commands/branch_ja.md#注意点) — `withScroll*` の中でも今の画面だけを照合し、画面外の要素は不成立(ブロック不実行)になります。
- [条件判定も宣言済みの割り込みを先に閉じる](../commands/branch_ja.md#注意点) — 覆われた要素は閉じてから判定されます。閉じないと黙って「無い」と読まれ、誤った分岐になるためです。
- [値や画面状態の分岐は2種類だけ](../commands/branch_ja.md#注意点) — 読んだ値には素の Swift `if`、画面に出ているかには `ifCanSelect` を使います。
- [ios { } / android { } は OS 固有の小さな差だけに使う](../commands/branch_ja.md#注意点) — 両 OS 共有のシナリオで片方だけに当てはまる確認をするときに使います。

### clearInput
- [Android で欄が候補一覧などの下にあると触らず失敗する](../commands/clear_input_ja.md#注意点) — 焦点を当てるタップが候補を選んで別の欄を書き換えるので、先に一覧を閉じます。
- [入力欄でない要素(ボタン等)を指すと消す前に失敗する](../commands/clear_input_ja.md#注意点) — 事前タップで送信・購入ボタンを押す事故を防ぐための断りです。入力欄を指して書きます。
- [値が入力を映さない欄は消した後も値が残って見える](../commands/clear_input_ja.md#注意点) — iOS の Material 3 の SearchBar 等では、OCR で欄に何も描かれていなければ注記付きで通り、ほかの文字が描かれている・伏せ字・キーボードが重なる・OCR 不可のときは失敗します。
- [空白は検証できない](../commands/clear_input_ja.md#注意点) — 空白が欠けても検出されないので、空白が意味を持つ値は `valueIs` で確かめます。
- [type は追記なので書き換えはクリアが先](../commands/clear_input_ja.md#注意点) — `type(sel, "文字列", replace: true)` でクリアと入力を1コマンドにできます。
- [Flutter の iOS ビルドは XCUITest ブリッジへ自動で切り替わる](../commands/clear_input_ja.md#注意点) — in-app ブリッジでは欄を消せないため、この1コマンドだけ1〜2秒余分にかかります。
- [settle: false は操作後の落ち着き待ちを省く](../commands/clear_input_ja.md#注意点) — 早く戻る代わりに、次のステップが動いている最中の画面を見ることがあります。

### group, procedure, beforeEach, afterEach, beforeAll, afterAll, setUpDevice, tearDownDevice
- [procedure { } は失敗後に走らせたくない処理の置き場](../commands/descriptors_ja.md#注意点) — シーンのブロックに直接書いた生の Swift は、前段が失敗しても実行されます。
- [beforeAll() で設定したプロパティは他のシナリオから見えない](../commands/descriptors_ja.md#注意点) — 値の受け渡しは `writeMemo` / `readMemo` を使い、失敗するとそのクラスの残りは実行されず失敗になります。
- [setUpDevice() で設定したプロパティも他のシナリオから見えない](../commands/descriptors_ja.md#注意点) — 値は `writeMemo` / `readMemo` で渡し、失敗すると同デバイスの同クラスの残りは失敗として記録されます。
- [afterEach() は @Test が失敗した後でも実行される](../commands/descriptors_ja.md#注意点) — アプリの終了など、成否に関わらず必要な後片付けに使います。
- [tearDownDevice() は専用プロセスで走り、合否に数えない](../commands/descriptors_ja.md#注意点) — デバイスが使えなくなった場合や run を中断した場合は走りません。
- [@Deleted / @Draft は一括実行から除外される](../commands/descriptors_ja.md#注意点) — 完全一致 ID を明示したときだけ実行できます。
- [手順の説明は scene の題名に書く](../commands/descriptors_ja.md#注意点) — 説明は scene の題名に書きます。

### exist, notExist, countIs
- [exist の戻り値は text・value・id の検証にチェーンできる](../commands/existence_assertion_ja.md#注意点) — 各検証コマンドのページを参照してチェーンします。
- [exist / notExist / countIs は常にセレクタを取る](../commands/existence_assertion_ja.md#注意点) — 直前に掴んだ要素へ暗黙に効く形は無いので、毎回セレクタを書きます。
- [notExist は可視性を見ない](../commands/existence_assertion_ja.md#注意点) — 別のモーダルに覆われて木に残っている要素は「まだ在る」と扱われ、待ち時間後に失敗します。
- [モーダルの裏で通った「無い」には absence-behind-modal の注記が付く](../commands/existence_assertion_ja.md#注意点) — 裏の要素が木から外れると、要素が在っても `notExist` が通ります。合否は変わらないので注記を確認します。
- [Android で別アプリの画面を読んで通った「無い」には注記が付く](../commands/existence_assertion_ja.md#注意点) — 前面がテスト対象でないと、検証は対象について何も言っていません。合否は変わらないので注記を確認します。
- [先頭だけが描かれた文字の扱い(省略記号・半分以上は緑、注記付き)](../commands/existence_assertion_ja.md#注意点) — 末尾が省略記号なら緑(`text-ellipsized`)、描かれたのが期待の半分より多いと緑(`text-partially-hidden`)、半分以下は失敗です。大部分を隠す画面は `requireVisible: false` を使います。

### 画像で探す(findImage, findImages, existImage)
- [記録の距離を threshold の目安にする](../commands/find_image_ja.md#注意点) — 記録には距離と比べた候補の数が出ます。見つからないときは最も近かった距離が出ます。
- [文字だけが違う同じ形の部品は別の行を掴むことがある](../commands/find_image_ja.md#注意点) — 距離が既定の `threshold`(0.15)を下回るためです。記録の距離を見て `threshold: 0.03` などに絞ります。
- [見本は OS の版・画面の倍率ごとに採る](../commands/find_image_ja.md#注意点) — 版が違うと距離が離れます。版ごとの見本を同じラベルのフォルダへ足せば、両方の端末で掴めます。
- [waitSeconds の既定は 0(今の画面を1回だけ見る)](../commands/find_image_ja.md#注意点) — 画面切り替え直後は `waitSeconds: 3` のように秒数を渡して待ちます。
- [existImage の失敗時は最も近かった距離と使った画像が出る](../commands/find_image_ja.md#注意点) — 失敗文言に距離と `threshold` が出て、判定に使ったスクリーンショットがレポートに添えられます。
- [withScrollDown { } の中ではスクロールしながら探す](../commands/find_image_ja.md#注意点) — 今の画面だけを見るなら `scroll: .noScroll` を渡します。
- [スクロールして探すときは scroll: を渡す](../commands/find_image_ja.md#注意点) — `findImageWithScrollDown` のような別名は無く、`findImage("[Icon]", scroll: .down)` と書きます。
- [見本が1枚も無いと設定の誤りとして失敗する](../commands/find_image_ja.md#注意点) — ラベルのフォルダに見本を置いてから使います。
- [Vision が一時的におかしな特徴量を返すことがある](../commands/find_image_ja.md#注意点) — Mac が混んでいるときに出ます。待って探し直し、戻らなければ失敗します(注記 `vision-anomaly-retried`)。
- [スクリーンショットが一色だと撮れていないとみなして比べない](../commands/find_image_ja.md#注意点) — 待って撮り直し(注記 `blank-screenshot-retaken`)、それでも一色なら失敗します。
- [inapp-boost モードでの絵の撮り方はテキストの可視性検証と同じ](../commands/find_image_ja.md#注意点) — 覆われた要素は、画面全体の絵では覆いの絵として比べられます。
- [見つけた要素にセレクタがあれば検証をつなげられる](../commands/find_image_ja.md#注意点) — id か一意なラベルがある要素には `textIs` などをチェーンできます。
- [見つけてから画面が動くと tap() は古い座標を押す](../commands/find_image_ja.md#注意点) — 見つけた直後にタップします。
- [候補の切り出しはアクセシビリティ要素の枠](../commands/find_image_ja.md#注意点) — アクセシビリティに出てこない部品は探せません。

### flick
- [flick はコンテンツを見ないジェスチャ](../commands/flick_ja.md#注意点) — 要素が見つかるまで探す `scroll*` と違い、速い1ストロークを送るだけで、既定の時間は `swipe` より短いです。
- [対象領域は scrollFrame: で指定する](../commands/flick_ja.md#注意点) — `scroll` と同じセレクタ式で指します。
- [flick は端に着いたかを判定しない](../commands/flick_ja.md#注意点) — 並べて送っても到達は分かりません。払った後は自分で到達先を検証します。

### マップ・キャンバス系のジェスチャ(doubleTap, pinchIn, pinchOut, gesture, hold)
- [`setPickerValue` が回すのはホイール1本だけ](../commands/gestures_ja.md#注意点) — ピッカー全体ではなくホイール自体(`.pickerWheel[n]` か `#id`)を指してください。複数のホイールやホイールでない要素は、何も送る前に断ります。
- [`setSliderValue` はスライダーの帯をタップすることがある](../commands/gestures_ja.md#注意点) — アクセシビリティの操作で動かせないスライダーは、帯の上のタップで値を合わせます(途中の値を通ります)。
- [スナップショットに値が出ないスライダーは setSliderValue で合わせられない](../commands/gestures_ja.md#注意点) — iOS の xcuitest モードの Flutter のスライダーがこれにあたります。既定の inapp-boost モードでは合わせられます。
- [settle: false は操作後の落ち着き待ちを省く](../commands/gestures_ja.md#注意点) — 早く戻る代わりに、次のステップが動いている最中の画面を見ることがあります。

### 画像の検証(imageIs)
- [見本が無いと待たずに失敗する](../commands/image_assertion_ja.md#注意点) — `label` を含むラベルの見本も必要で、無いと待たずに失敗します。
- [失敗の文言に分類されたラベルと確信度が出る](../commands/image_assertion_ja.md#注意点) — 文言を見て、見本とのずれを判断します。

### installApp, removeApp, clearAppData
- [iOS の inapp-boost では installApp() の直後に launchApp() を呼ぶ](../commands/install_app_ja.md#注意点) — インストールでアプリの中のブリッジが終了し、再起動まで tap などが届きません。
- [入れ直しても権限は戻らない](../commands/install_app_ja.md#注意点) — iOS Simulator は再インストールしても許可が残ります。権限から戻すなら `clearAppData()` を使います。
- [clearAppData() は権限も未許可へ戻す](../commands/install_app_ja.md#注意点) — 権限ダイアログが再び出るので、初回起動の権限フローの検証に使えます。
- [iOS 実機の clearAppData() はアプリを入れ直して消す](../commands/install_app_ja.md#注意点) — 時間がかかり、アプリプロファイルの `appPathPhysical` と `--profile` が要り、有効な入れ元が無ければアンインストールせずに失敗します(注記 `reinstalled-to-clear-data`)。
- [キーチェーン / Keystore の値は clearAppData() で消えない](../commands/install_app_ja.md#注意点) — オンボーディング判定をそこに置くアプリでは初回起動が再現しません。
- [fleetest 自身のブリッジは removeApp / clearAppData の対象にできない](../commands/install_app_ja.md#注意点) — ブリッジの ID を渡すと何も送らずに失敗します。消すとデバイスを操作できなくなるためです。
- [自分のテスト対象アプリを removeApp() で消すと以降が壊れる](../commands/install_app_ja.md#注意点) — そこでシナリオを終える意図があるときだけ呼びます。
- [Android のインストール中だけ Play Protect の検証を切る](../commands/install_app_ja.md#注意点) — アプリは Google へ送られず、終わると設定を元に戻します。有効のままだと `adb install` がダイアログで止まります。

### iOS のシステムアラート(iosAlertHandler)
- [空または * と見えない文字だけの分岐は宣言時に失敗する](../commands/ios_alert_handler_ja.md#注意点) — どのアラートにも一致してしまうためです。具体的な文言を書きます。

### irregularHandler
- [操作の待機中・検証の待機中のどちらでも発火する](../commands/irregular_handler_ja.md#注意点) — 検証のポーリング中に開いたモーダルも、タップ中に開いたものと同じように閉じられます。
- [既定では1ステップ最大10回まで閉じる](../commands/irregular_handler_ja.md#注意点) — `maxDismissals:` で変えられます。2回閉じても残れば諦め、「完全には閉じられなかった」と記録します。
- [条件判定も割り込みを閉じてから答える](../commands/irregular_handler_ja.md#注意点) — 閉じないと覆われた対象が黙って「無い」と読まれ、誤った分岐になります。
- [OS のシステムダイアログ(権限の許可等)には効かない](../commands/irregular_handler_ja.md#注意点) — 別プロセスが描画するため対象外です。`iosAlertHandler` を使います。
- [iOS の別ウィンドウのモーダルは木に載るが、全面を覆うと背面が木から消える](../commands/irregular_handler_ja.md#注意点) — 背面の `exist` やタップは失敗するので誤成功にはならず、モーダルを閉じてから操作します。

### キーボードの検証(keyboardIsShown, keyboardIsNotShown)
- [表示 / 非表示はブリッジが申告する枠で決まる](../commands/keyboard_assertion_ja.md#注意点) — 枠が画面の外なら非表示で、どちらも不明なときは失敗します。iOS の xcuitest モードでは閉じたことを確定できないことがあるので、閉じた確認は inapp-boost モード(または Android)で書きます。

### launchApp, restartApp, terminateApp, openURL
- [launchApp は起動済みでも常にプロセスを終了して起動し直す](../commands/launch_app_ja.md#注意点) — 前面化ではないので、どの呼び出しもエントリー画面から始まります。
- [launchApp はアプリのデータを消さない](../commands/launch_app_ja.md#注意点) — 消えるのはプロセスと画面の状態だけです。データを消すのは `clearAppData()` です。
- [iOS の inapp-boost で他のアプリを launchApp / restartApp すると失敗する](../commands/launch_app_ja.md#注意点) — in-app ブリッジは別のアプリを駆動できません。そのアプリの手順は別のシナリオに分けます。
- [fleetest 自身のブリッジは launchApp / restartApp の対象にできない](../commands/launch_app_ja.md#注意点) — ブリッジの ID を渡すと何も送らずに失敗します。
- [既定アプリは実行プロファイルの app → アプリプロファイル → platform の順で決まる](../commands/launch_app_ja.md#注意点) — `@TestClass` に `app:` は書けないので、同じシナリオを別プロファイルで回すとアプリが変わります。複数のアプリを扱うなら bundle ID を渡すか、アプリごとの実行プロファイルを使います。
- [openURL はプロセスを再起動しない](../commands/launch_app_ja.md#注意点) — 起動済みのアプリへディープリンクを届ける用途です。`launchApp(url:)` は先に再起動します。
- [初回の openURL で iOS Simulator の確認アラートが出ることがある](../commands/launch_app_ja.md#注意点) — 自動了承されます。向け直せなかった場合は注記 `open-url-session…` が付き、続く操作が届かないことがあります。
- [未起動のアプリへの openURL は想定用途ではない](../commands/launch_app_ja.md#注意点) — 未起動から URL で開く検証には `launchApp(url:)` を使います。

### home, back, appSwitcher, tapAppIcon, rotateTo, fold, unfold, hinge
- [home() 等の後はアプリを前面へ戻してから操作する](../commands/navigation_ja.md#注意点) — iOS の inapp-boost と Android で、アプリが前面にない間は `select` や `notExist` などが断られます。
- [back(settle:) の確実さは画面による](../commands/navigation_ja.md#注意点) — iOS の自前描画のナビバーの画面は戻れないことがあります(アプリ内の戻るボタンを `tap()`)。Android はキーボードが開いていると1回目の `back()` がそれを閉じるだけで消費されます。
- [back() の前後で画面が変わらなくても失敗しない](../commands/navigation_ja.md#注意点) — 注記が付くだけです。アプリ自身の戻るボタンを `tap` するか、`back()` をもう一度呼びます。
- [back() の注記(back-stayed-on-screen など)](../commands/navigation_ja.md#注意点) — 失敗にはならないので、注記が出たらどの画面に着いたかを自分で確かめます。
- [tapAppIcon の探索順](../commands/navigation_ja.md#注意点) — 現在の画面、Android はドロワー、iOS はページ送りと App ライブラリの順に探します。
- [iOS の tapAppIcon はホームの手前のシステムアラートを名指して失敗する](../commands/navigation_ja.md#注意点) — アラートが出ている間はアイコンが木に無いので、先にアラートを処理します。
- [tapAppIcon はホーム画面の木が表示中の画面と一致しないと撃たない](../commands/navigation_ja.md#注意点) — 内蔵画面が2枚の Simulator で木の画面の大きさが違うと失敗します。
- [terminateApp() 等で止めた後の iOS の back() 等は撃たずに失敗する](../commands/navigation_ja.md#注意点) — 止めた後は `launchApp()` でアプリを起こしてから操作します。
- [rotateTo が契約するのはアプリの UI の向き](../commands/navigation_ja.md#注意点) — 実機の傾きではありません。値は `.portrait` / `.landscape` の2つだけです。
- [rotateTo は向きが変わるまで待ってから返る](../commands/navigation_ja.md#注意点) — 向きが変わったことを別に待つ必要はありません。
- [回転は終了時に元の向きへ自動で戻る](../commands/navigation_ja.md#注意点) — Android は自動回転の設定も戻します。
- [アプリがその向きを許可していないと回らない](../commands/navigation_ja.md#注意点) — Android は禁じていれば待たずに失敗し、理由にアプリの宣言を示します。
- [回転の間、Android は自動回転を切る](../commands/navigation_ja.md#注意点) — 切らないと角度が保持されないためです。
- [settle: false は操作後の落ち着き待ちを省く](../commands/navigation_ja.md#注意点) — 早く戻る代わりに、次のステップが動いている最中の画面を見ることがあります。
- [fold / unfold / hinge は折りたたみ端末が必要](../commands/navigation_ja.md#注意点) — iPhone Duo の Simulator か折りたたみの Emulator です。iOS 実機はそのシナリオが対象外(skipped)になります。折りたたみの Android 実機は非対応として失敗します。
- [折りたためないデバイスでは失敗でなく以降を skipped にする](../commands/navigation_ja.md#注意点) — 緑でも実行されていないステップがあるので、レポートで確認します。
- [折りたたみ状態は終了時に自動で元へ戻る](../commands/navigation_ja.md#注意点) — `rotateTo` の向きと同じ扱いです。
- [Android の折りたたみ機は閉じるとロック画面が出る](../commands/navigation_ja.md#注意点) — `fold()` はスワイプで外して進みますが、PIN やパターンのロックは外せません。
- [hinge はどちらの画面が出るかを確かめない](../commands/navigation_ja.md#注意点) — 切り替わる角度は直前の状態に依存します。特定の画面が要るなら `fold()` / `unfold()` を使います。
- [iOS の fold / unfold は非公開のヒンジイベントを送る](../commands/navigation_ja.md#注意点) — 将来の Xcode で受け付けなくなる可能性がありますが、切り替わりを確かめるので黙って通らず失敗します。

### pressEnter, hideKeyboard
- [pressEnter が改行か確定アクションかはフィールドが決める](../commands/press_enter_hide_keyboard_ja.md#注意点) — コマンド側では選べません。`type` の末尾 `\n` も同じです。
- [iOS の hideKeyboard はフレームワークで閉じ方が違う](../commands/press_enter_hide_keyboard_ja.md#注意点) — 背景タップで閉じるか Enter で閉じるかが違います。React Native の inapp-boost は Enter を送りません。閉じなければ失敗します。
- [キーボードの下にある対象は先にキーボードを閉じてから操作される](../commands/press_enter_hide_keyboard_ja.md#注意点) — `tap` / `type` / `clearInput` は先に副作用のない手段で閉じます。閉じられないと `type` / `clearInput` は触らず失敗し、`tap` は見えている部分だけを押します。リターンキーが要るなら先に `pressEnter()` を呼びます。
- [キーボードが出ているかの検証は別のコマンド](../commands/press_enter_hide_keyboard_ja.md#注意点) — `keyboardIsShown` / `keyboardIsNotShown` を使います。
- [settle: false は操作後の落ち着き待ちを省く](../commands/press_enter_hide_keyboard_ja.md#注意点) — 早く戻る代わりに、次のステップが動いている最中の画面を見ることがあります。

### repeatWhileCanSelect, doUntilTrue
- [maxLoopCount: は暴走防止の上限](../commands/repeat_ja.md#注意点) — 「ちょうどこの回数繰り返した」ことの検証にはなりません。
- [出る / 消えるを待つだけなら waitForDisplay / waitForClose か waitSeconds:](../commands/repeat_ja.md#注意点) — `doUntilTrue` で書くより記録が1ステップで済みます。
- [1周ごとにまとまりとして記録され、中の失敗でシナリオが止まる](../commands/repeat_ja.md#注意点) — ブロックの中のコマンドが失敗するとそこで止まります。
- [doUntilTrue が止まるのは waitSeconds: と maxLoopCount: だけ](../commands/repeat_ja.md#注意点) — コマンド1つの上限 120 秒は掛かりません。
- [条件ブロック内の throw はリトライせず即失敗する](../commands/repeat_ja.md#注意点) — 「絶対に true にならない条件」を検出したときに使います。

### 画面の検証(screenLooksLike)
- [screenLooksLike は experimental](../commands/screen_assertion_ja.md#注意点) — 日本語の説明文での判定精度はまだ計測していません。
- [macOS 27+ が必要](../commands/screen_assertion_ja.md#注意点) — macOS 26 では自動でスキップされます。可否は `fleetest doctor` で確認します。
- [厳密な合否ゲートとして使わない](../commands/screen_assertion_ja.md#注意点) — 同じ見た目でも撮られ方で合否が裏返ることがあります。大づかみの確認に留め、重要な検証は `exist` / `textIs` で書きます。
- [アサーションに数えない](../commands/screen_assertion_ja.md#注意点) — `expectation` に `screenLooksLike` しか無いと「アサーションが無い」と警告されます。
- [画面がどう見えるべきかは呼び出しごとに説明文で書く](../commands/screen_assertion_ja.md#注意点) — 説明文の言い回しが判定に強く効きます。

### screenshot
- [スクリーンショットは撮ったステップの直後にレポートへ入る](../commands/screenshot_ja.md#注意点) — 見たい位置に呼び出しを置きます。
- [Android の WebView 画面は写らないことがある](../commands/screenshot_ja.md#注意点) — 間欠的で、補完は WebView のデバッグが有効なときだけです。画面の到達確認は `exist` / `notExist` で行います。

### select, lastElement
- [select 単体ではシナリオを失敗させない](../commands/select_ja.md#注意点) — 見つからなければ空要素になるだけです。失敗しうるのはチェーンした検証側です。
- [Android でアプリが前面に無い間の select は断られる](../commands/select_ja.md#注意点) — 空要素を「要素が無い」と取り違えないための失敗です。先に `launchApp()` か `tapAppIcon()` で戻します。
- [lastElement は各 scene の開始時に空になる](../commands/select_ja.md#注意点) — 一度も掴んでいなければ空(+警告)です。
- [waitSeconds: を省くと defaultTimeout(既定 5 秒)まで探す](../commands/select_ja.md#注意点) — 今の画面を1回だけ見て分岐するなら `select(sel, waitSeconds: 0)` と書きます。

### 状態の検証(enabledIsTrue, enabledIsFalse, checkIsON, checkIsOFF)
- [チェック状態はアクセシビリティから読む](../commands/state_assertion_ja.md#注意点) — iOS は実装ごとに出し方が違い、fleetest が吸収します。
- [状態を一切報告しない要素がある](../commands/state_assertion_ja.md#注意点) — SwiftUI の `Button` 自作チェックボックスなどで `checkIsON` は失敗します。`textIs` で確かめるか、アプリ側で状態を公開します。`checkIsOFF` は状態を報告しない要素でも通ります(run 終了時に警告)。
- [オンのときだけ報告する実装では、オンを見ていない要素の checkIsOFF が通る](../commands/state_assertion_ja.md#注意点) — 状態が分からないまま通り、run 終了時に警告が出ます。先に `checkIsON` で確かめます。
- [「一部だけ選択」の要素は checkIsON でも checkIsOFF でも失敗する](../commands/state_assertion_ja.md#注意点) — indeterminate は別の状態として扱われます。
- [select の後の enabledIsTrue / enabledIsFalse は選んだ時点の状態で判定する](../commands/state_assertion_ja.md#注意点) — 文字を描かない要素(骨組みの行など)も、選んだ時点の状態で判定します。

### suppressHandler, useHandler, disableHandler, enableHandler
- [suppressHandler { } はブロック形で失敗しても自動で戻る](../commands/suppress_handler_ja.md#注意点) — モーダルとのやり取りが1ブロックに収まるならこちらを使います。
- [条件・操作・検証を跨げるのは disableHandler() / enableHandler() だけ](../commands/suppress_handler_ja.md#注意点) — `condition {}` で存在を確かめて `action {}` で操作したいときに使います。
- [useHandler { } は入れ子のブロックだけ自動クローズを戻す](../commands/suppress_handler_ja.md#注意点) — 外側の抑止は終わらず、ブロックを抜けると再び抑止に戻ります。
- [抑止してもアプリが割り込みを出すこと自体は止められない](../commands/suppress_handler_ja.md#注意点) — 止まるのはツールが閉じることだけで、モーダル中のタップは吸われることがあります。
- [抑止したまま失敗すると失敗の注記が追加される](../commands/suppress_handler_ja.md#注意点) — 成功したステップには何も足されません。
- [enableHandler() の呼び忘れは抑止がシナリオ終了まで続く](../commands/suppress_handler_ja.md#注意点) — 中断後の `afterEach()` で出た割り込みも閉じられません。気になるならブロック形を使います。
- [OS のシステムダイアログは抑止の影響を受けない](../commands/suppress_handler_ja.md#注意点) — シナリオが直接操作しているアラートも、抑止の有無に関わらず奪われません。

### swipe, swipePointToPoint, swipeElementToElement, swipeBy
- [swipe だけが指の動きを方向として扱う](../commands/swipe_ja.md#注意点) — `scroll*` 系はコンテンツ基準です(`.down` は指が上へ動きます)。向きを取り違えないでください。
- [swipe は何かが動いたかを確かめない](../commands/swipe_ja.md#注意点) — 動くものが無くても失敗しません。後続の `exist` などで検証します。
- [swipeBy と swipeElementToElement は地図・画像ビューア等の土台](../commands/swipe_ja.md#注意点) — パンやズームの詳細は gestures のページを参照します。
- [settle: false は操作後の落ち着き待ちを省く](../commands/swipe_ja.md#注意点) — 早く戻る代わりに、次のステップが動いている最中の画面を見ることがあります。

### tap, tapAppIcon
- [重なりの順を知れる画面でだけ3つの保護が働く](../commands/tap_ja.md#注意点) — 知れるのは iOS の UIKit・React Native(inapp-boost)と、Android の View・React Native です。
- [同じセレクタに複数一致するとき、覆われた先頭を避けて押す](../commands/tap_ja.md#注意点) — 覆われていない要素を押します(注記付き)。全部覆われているときは何も押さず失敗します。
- [対象の中心がタブバーや固定フッタの下にあると、見えている部分を押す](../commands/tap_ja.md#注意点) — まず一覧を送って外し、外せなければ見えている部分を押します。薄すぎる(8pt/8dp 未満)と失敗します。
- [スクロールで隠れた対象がナビバーの下にあると scroll: が要る](../commands/tap_ja.md#注意点) — `scroll:` が無いと何も押さず失敗し、向きを案内します。`scroll: .up` 等を書きます。
- [対象が見つからず手前の窓やモーダルが木から外しているときは失敗文が名指す](../commands/tap_ja.md#注意点) — 失敗文が窓やモーダルを名指ししても、`waitSeconds:` を伸ばして待つのは無駄です(閉じるまで対象は戻りません)。前のステップで閉じるか `irregularHandler` で宣言します。
- [重なりの順を知れない画面では推測せず対象の中心を押す](../commands/tap_ja.md#注意点) — SwiftUI・Compose Multiplatform・Flutter・xcuitest・MCP 操作が該当し、覆われていると別の物を押します。
- [アプリが落ちて別のアプリが前面のときは失敗する](../commands/tap_ja.md#注意点) — 同じ `#id` を持つ別のアプリを誤って操作しないための断りです。
- [tap は対象が enabled になるまで待ってから撃つ](../commands/tap_ja.md#注意点) — `waitSeconds:`(既定 5 秒)まで待ち、なお無効でもそのまま撃ちます。
- [要素が現れるまでの待ちは短い(約 0.7 秒)](../commands/tap_ja.md#注意点) — 遷移後に遅れて出る要素は `tap("#btn", waitSeconds: 5)` か `waitForDisplay` で待ちます。
- [tap してから type する書き方もできる](../commands/tap_ja.md#注意点) — Android で `#id` が容器に解決して焦点が移らないとき、`type` が入力欄を名指して入れ直します。
- [Android の画面最下端の帯の要素は OS に押下を取られることがある](../commands/tap_ja.md#注意点) — ジェスチャーナビの端末では、要素の帯より上の部分を押します(注記付き)。
- [iOS の in-app ブリッジは本物の指で押せない要素にも届くことがある](../commands/tap_ja.md#注意点) — 緑のまま「本物のタッチは別の物に当たる」注記が付くので、注記が出たら画面の覆いを疑います。
- [座標タップは最後の手段](../commands/tap_ja.md#注意点) — アプリが要素を公開しないときだけ使い、長く使うシナリオではセレクタを優先します。
- [settle: false はそのコマンド1回だけ操作後の待ちを省く](../commands/tap_ja.md#注意点) — 早く戻る代わりに、次のステップが動いている最中の画面を見て位置がずれることがあります。

### テキストの検証(textIs, textContains, …)
- [比べ方の約束は4つ](../commands/text_assertion_ja.md#注意点) — 見えているとおりに比較・半角と全角スペースと改行は区別・空の期待値は不可・正規表現は書いたとおりです。
- [正規表現が空だと比べる前に失敗する](../commands/text_assertion_ja.md#注意点) — 空文字・空白だけ・見えない文字だけのパターンはどんな文字にも一致してしまうためです。
- [期待値が空の Contains / StartsWith / EndsWith 系も比べる前に失敗する](../commands/text_assertion_ja.md#注意点) — どんな文字にも当てはまるためで、`value…` / `this…` も同じです。
- [比較は見た目が完全に一致していれば同じ](../commands/text_assertion_ja.md#注意点) — ゼロ幅などは無視し、半角と全角スペース・連続空白は別物です。NBSP は半角と同じで、`strict: true` で正規化なしにできます。
- [要素は在る前提で waitSeconds まで値の変化を待つ](../commands/text_assertion_ja.md#注意点) — 値が更新されるのを待つ用途にも使えます。
- [否定系と空判定は可視性を見ない](../commands/text_assertion_ja.md#注意点) — `textIsNot`・`textIsEmpty` などは「見えていないこと」を画面照合できません。
- [これらに scroll: は無い](../commands/text_assertion_ja.md#注意点) — 対象を先に `select(selector, scroll: .down)` などでビューに入れてから検証します。
- [チェーンした検証は掴んだ時点の値でまず判定する](../commands/text_assertion_ja.md#注意点) — 満たしていればデバイスを見に行かず、説明に `(from the grabbed value)` が付きます。

### type
- [type("") は打つ前に失敗する](../commands/type_ja.md#注意点) — 欄を空にするなら `clearInput()` か `type("", replace: true)` を使います。
- [Android で欄が候補一覧などの下にあると打つ前に失敗する](../commands/type_ja.md#注意点) — 焦点を当てるタップが候補を選んでしまうので、先に一覧を閉じます。
- [入力欄でない要素(ボタン等)を指すと打つ前に失敗する](../commands/type_ja.md#注意点) — 事前タップで送信・購入ボタンを押す事故を防ぐための断りです。入力欄を指して書きます。
- [値の入っている欄への type は追記で、失敗しない](../commands/type_ja.md#注意点) — 置き換えるなら `replace: true` か先に `clearInput(sel)` を呼びます。
- [改行(\n)は OS 既定の挙動になる](../commands/type_ja.md#注意点) — iOS は Return キーで、単一行なら確定アクションが発火します。Android は文中の改行を文字として書きます。
- [次の操作がソフトキーボードの表示を待つ](../commands/type_ja.md#注意点) — `type` はキーボードが出る前に返ることがあるため、次の操作は最大 1.5 秒待ちます。
- [tap(入力欄) → type("文字列") の書き方に対応している](../commands/type_ja.md#注意点) — Android で焦点が立たなかったときだけ、`type` が入力欄を名指して入れ直します。
- [Android のセレクタなし type は打った先を確かめ、焦点が出ないと注記が付く](../commands/type_ja.md#注意点) — 注記 `type-focus-not-reported` が出たら、文字がどこにも入っていない可能性があります。欄のセレクタを渡します。
- [Android で別のアプリが前面のままセレクタなしで打つと注記が付く](../commands/type_ja.md#注意点) — 文字が別のアプリへ入った可能性があります。欄のセレクタを渡して確実に打ちます。
- [入った値は読み返して直す](../commands/type_ja.md#注意点) — 欠けは追送、二重は削除、途中の欠落は全文を打ち直し(1回まで)ます。アプリの加工は受け入れるので、値は `valueIs` で確かめます。
- [Android で末尾が欄に残らなかったときは説明にそう書くが合否は変わらない](../commands/type_ja.md#注意点) — 上限のある欄では緑のまま末尾が落ちます。`textIs` / `valueIs` で全部入ったか確かめます。
- [値が1文字も動かないときは先に画面を見る](../commands/type_ja.md#注意点) — OCR(macOS 27+)で描かれていれば受け入れ、描かれていなければ追送します。追送は1回までで、なお動かなければ失敗します。
- [iOS の xcuitest モードでは欄の値を先頭の 512 単位までしか読めない](../commands/type_ja.md#注意点) — 長い文は読めた先頭の一致で受け入れ、残りは確かめません。全文はアプリの表示を `textIs` で見ます。
- [settle: false は操作後の落ち着き待ちを省く](../commands/type_ja.md#注意点) — 早く戻る代わりに、次のステップが動いている最中の画面を見ることがあります。

### 値の検証(valueIs, valueContains, …)
- [入力欄の内容は value* で見る](../commands/value_assertion_ja.md#注意点) — 一部のフレームワーク(Compose Multiplatform と Flutter の iOS・React Native)では入力欄の `text` が placeholder を返すので、`textIs` / `textIsEmpty` を当てません。空欄は `valueIsEmpty` で判定します。
- [否定系と空判定は可視性を見ず、scroll: も無い](../commands/value_assertion_ja.md#注意点) — テキストの検証と同じ規則です。
- [チェーンした検証は掴んだ時点の値でまず判定する](../commands/value_assertion_ja.md#注意点) — 満たしていなければデバイスをポーリングします。

### まとめて検証(verify)
- [アサーションが0個だと inconclusive(結論なし)になる](../commands/verify_ja.md#注意点) — passed でも failed でもなく、シナリオも中断しません。レポートには理由が出るので、検証を入れ忘れていないか確認します。
- [ブロック内のコマンドが失敗するとシナリオが中断する](../commands/verify_ja.md#注意点) — 通常の失敗と同じ扱いです。

### wait, waitForDisplay, waitForClose, waitForSettle
- [要素の出現待ちは既に暗黙](../commands/wait_ja.md#注意点) — `exist()` の前に `wait()` は不要です。足りなければ `waitSeconds:` を上げます。
- [wait() は整定のための最後の手段](../commands/wait_ja.md#注意点) — `waitForDisplay` / `waitForClose` の代わりにはならず、画面が止まるのを待つなら `waitForSettle` を使います。
- [waitForDisplay の判定は exist と同じ可視性込み](../commands/wait_ja.md#注意点) — 可視性の判定を外して待ちたいなら `exist(sel, requireVisible: false, waitSeconds: 15)` を使います。
- [waitForDisplay / waitForClose はスクロールして探さない](../commands/wait_ja.md#注意点) — 画面外にありうるなら、先にスクロールするか `scrollTo` を使います。

## セレクタ

### 型付きセレクタ(Sel)
- [綴り誤りは Sel ではコンパイルエラーになる](../selector/typed_selector_ja.md#注意点) — 文字列版では実行時の構文エラーか、黙って生ラベル扱いになります。
- [scrollFrame: だけは文字列版のみ](../selector/typed_selector_ja.md#注意点) — 他の引数が `Sel` 版を持つコマンドでも、`scrollFrame:` には文字列で書きます。
- [生成されるコードは既定で文字列版](../selector/typed_selector_ja.md#注意点) — `Sel` は手書きで型指定を好む人の選択肢です。詳細はセレクタ式のページを参照します。

## UI 部品ごとの癖(現時点の制約)

### モーダルが開いている間、背後の画面は木から消える
- [React Native の accessible な祖先の下は iOS で1要素に畳まれる](ui_component_patterns_ja.md#モーダルが開いている間背後の画面は木から消える) — `Tooltip` や `BottomSheetModal` の中身が iOS でだけ木から消えます。直せるのはアプリ側の `accessible={false}` だけです。
- [Flutter の iOS はオーバーレイを出すと a11y の矩形が縮む](ui_component_patterns_ja.md#モーダルが開いている間背後の画面は木から消える) — xcuitest モードでは補正されずタップがずれます。別の画面へ移って戻ってから操作します(既定の inapp-boost は自動補正)。

### ボトムシート
- [RN の BottomSheet を半分開いた状態では iOS の探索がシートを伸ばせない](ui_component_patterns_ja.md#ボトムシート) — 探す前にシートの見出しから上へ払って全開にしてから探します。

### 選択式の入力欄(読み取り専用ドロップダウン)
- [候補の行に id が無く、ラベルで選ぶ](ui_component_patterns_ja.md#選択式の入力欄読み取り専用ドロップダウン) — Android View の `MaterialAutoCompleteTextView` と Flutter の `DropdownMenu` は、候補をラベルで指します。

### 引っ張って更新
- [SwiftUI の .refreshable と RN の iOS RefreshControl は長く引かないと始まらない](ui_component_patterns_ja.md#引っ張って更新) — 実測約 470pt 必要です。短い `swipeElementToElement` では反応しないので、画面比率で大きく引く生ジェスチャを使います。
- [iOS の xcuitest モードでは scrollToTop() で更新が1回余分に走ることがある](ui_component_patterns_ja.md#引っ張って更新) — `#id` の無い一覧などで起きます。更新回数の検証は `scrollToTop()` より前に済ませます。
- [Flutter の iOS でも scrollToTop() で更新が走ることがある](ui_component_patterns_ja.md#引っ張って更新) — 更新が走ることがあり、調査中です。更新回数を検証するシナリオでは、回数を読むのを `scrollToTop()` より前に済ませます。
- [更新回数を検証するシナリオは scrollToTop() の後に回数を読まない](ui_component_patterns_ja.md#引っ張って更新) — 上の2件に共通の回避策で、回数の検証はそれより前に済ませます。
- [Android は全フレームワークで起きない](ui_component_patterns_ja.md#引っ張って更新) — `scrollToTop()` / `scrollToBottom()` は a11y のスクロール操作で送るので、端を越えた引っ張りにならないためです。

### アニメーション(フェード・切り替え)
- [Flutter の AnimatedOpacity は非表示にしても木から消えない](ui_component_patterns_ja.md#アニメーションフェード切り替え) — 「要素が無いこと」を可視性の根拠にせず、アプリの echo か `checkIsON` / `checkIsOFF` で判定します。

### 画面遷移(ナビゲーション)
- [Android View の NavHostFragment でツールバーの戻るが1つ戻らないことがある](ui_component_patterns_ja.md#画面遷移ナビゲーション) — 調査中です。複数階層を検証するシナリオでは、ツールバーのタップではなく OS の `back()` を使います。

### 伸縮するヘッダ
- [RN の collapsible-tab-view でタブを替えた直後、iOS では先頭の行がヘッダの裏に居る](ui_component_patterns_ja.md#伸縮するヘッダ) — 覆いを避けて送れないので、ヘッダの下に見えている行を押します。

### 入力の種類
- [Android は非フォーカスのポップアップの中身が木に出ないことがある](ui_component_patterns_ja.md#入力の種類) — オートコンプリート候補やツールチップは見えない画面があります。候補を直接検証できないときはアプリの echo で確定後の値を確かめます。
- [Android の Flutter のオートコンプリートは候補の位置がずれ、tap が選ばずに緑になる](ui_component_patterns_ja.md#入力の種類) — 候補を押した後は必ず選んだ値を `textIs` などで確かめます。
- [Android は一部の入力欄で ACTION_SET_TEXT を拒否する](ui_component_patterns_ja.md#入力の種類) — Material の `SearchView` などで起きます。回避策は無く、`type` は通常の打鍵で入力されます。
- [RN の iOS(inapp-boost)で欄の直下の候補を押せないことがある](ui_component_patterns_ja.md#入力の種類) — 調査中です。候補がキーボードに隠れない画面構成にするか、確定後の値をアプリの echo で確かめます。

### FAB(フローティングアクションボタン)
- [Android View の BottomAppBar は幅が足りないと項目を1アイコンへ畳む](ui_component_patterns_ja.md#fabフローティングアクションボタン) — 畳まれた行は id を持てないので、先に `tap("その他のオプション")` でオーバーフローを開いてから押します。

### 無限スクロール
- [RN の FlatList の onEndReached は初期表示だけで発火することがある](ui_component_patterns_ja.md#無限スクロール) — 回避策は無く、初期読み込み件数を厳密に assert するならアプリの対処に依存します。

### スクロールで隠れるバー
- [Flutter の AnimatedSlide で隠すバーは木では元の位置に居ると申告される](ui_component_patterns_ja.md#スクロールで隠れるバー) — 見た目には無いボタンを押すことがあります。隠れている間は押さず、バーが出たことを確かめてから押します。

### Link
- [index](../../index_ja.md)
