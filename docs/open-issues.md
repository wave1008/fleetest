# 残件(未解決の不具合の候補)

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 台帳 | 未解決の不具合の候補(バグ出し 2026-09-06・09-08・09-11 と、その後の負荷テスト・仕様監査・回帰で見つかり、まだ直していないもの) | 未解決の不具合の候補を探す/足す/直したら消すとき | 直した項目の経緯(→ コミット)・設計判断の根拠(→ [maintainer-notes/](maintainer-notes/README.md))・仕様監査で「欠陥ではなかった」と確かめた項目(→ MN-106) |

バグ出し(2026-09-06・09-08・09-11)で見つかり、まだ直していない項目の一覧。台帳は削除したので、
未解決の項目だけをここに残す。**当初の判定は 2026-10-07 の HEAD(c87b8c8f)のソースを読んだ結果で、デバイスでの再現はしていない**
(その後に足した・確かめた項目は、各項目に日付と確かめた範囲を書く)。
各項目の「状態」の「推測」は、症状の経路か指摘の対象をコードから推して特定したもの。
10/29 の探索の所見の経緯は MN-107。

直したら項目を消す(経緯はコミットに残す)。新しい残件は同じ形(ID・状態・確認・属性・症状・場所・手がかり)で足し、属性の節へ置く。

## 目次

- 属性ごとの一覧
- 着手可
- 要判断
- 木に材料なし
- 低頻度
- 環境側
- 据え置き

## 属性ごとの一覧

各項目に当てはまる属性を**全部**付ける(`- 属性:` の行に `・` 区切り)。**先頭は次の一手を決める属性**で、項目はその節に置く。下の表には属性ごとに該当する項目を全部載せる(同じ項目が複数の行に出る)。

| 属性 | 意味 | 件数 | 項目 |
|---|---|---|---|
| 着手可 | 原因か経路が分かっていて、次の手が決まっているもの | 16 | OI-75・OI-124・OI-125・OI-129・OI-138・OI-139・OI-146・OI-155・OI-156・OI-158・OI-161・OI-163・OI-167・OI-168・OI-169・OI-171 |
| 要判断 | 直し方の選択をユーザーが決めるもの | 0 |  |
| 木に材料なし | 木(スナップショット)に判定の材料が無く、ブリッジの申告など別の材料が要るもの | 7 | OI-121・OI-128・OI-129・OI-156・OI-161・OI-163・OI-170 |
| 低頻度 | たまにしか出ない(数十〜数百回に1回)か、しばらく再現していないもの。効果の判定や再現に多くの周回が要る | 8 | OI-127・OI-130・OI-132・OI-134・OI-135・OI-137・OI-164・OI-165 |
| 環境側 | OS・Simulator・GPU・マシンの側が原因と測定で分かった部分があるもの。ツールは検知と回復まで | 1 | OI-139 |
| 据え置き | 直さないと決めたもの。症状が出たら見直す | 3 | OI-58・OI-140・OI-170 |

## 着手可

### OI-124 terminateApp 前後
- 状態: 再現済み
- 確認: コミット未記録(2026-11-02)
- 属性: 着手可

in-app ブリッジの2回目の terminateApp の 409(xcuitest は直した)。ステップの無い区間の .ips の検索の上限は、箇所を特定できていない。
- 11/2 にコードを読んだ: in-app の `terminateApp` は `simctl terminate` だけで HTTP を撃たず 409 を返さない(in-app の `/terminate` は 501)。409 を返せるのは XCUITest ランナーの `requireApp()` だけ = 直後の操作が XCUITest へ落ちた経路の疑い。再現のログが要る

### OI-125 live と CLI の残り
- 状態: 再現済み
- 確認: コミット未記録(2026-11-02)
- 属性: 着手可

別ポートのランナーが固まっている間、live が1コマンド約 8.8 秒止まる。deep sleep の後の `bridge up` が失敗し、実機 SE3 が全面黒のまま(手で再起動が要る)。

### OI-138 MCP の `ft_screenshot` が、指定した Emulator ではない画面の絵を返した
- 状態: 再現済み
- 確認: コミット未記録(2026-11-02)
- 属性: 着手可

`serial: emulator-5570` の `ft_batch` の木は E2EX-Flutter の入力画面(`value="xyz"`)だったのに、続く `ft_screenshot` は別の SUT のホーム画面だった(`adb -s emulator-5570 exec-out screencap` は入力画面)。同じ時刻に他の Emulator は E2E-Android のホームを表示していた。MCP のプロセスは約3時間前に起動した古い版で、その間に Emulator 8台を止めて別の8台が同じ serial で起動している。新しい MCP のプロセスで再現するかは未確認(1回)

### OI-75 Android の横向きの探索の失敗文が、画面の持ち主の取り違えで「ロック画面」と言う
- 状態: 推測
- 確認: コミット未記録(2026-11-02)
- 属性: 着手可

横向きの探索の失敗文に「ロック画面」の帰属が出た(`StepExecutor+ScrollSearch.swift` の `frontAppIfSessionAppLeft` が見る木の種別)。同じ項目にあった横向きの3つの症状(CMP の行の端への tap が何も押さずに ok・Flutter の端の誤判定・E2EY-CMP の横向きの `scrollToTop` が上端へ戻らない)は、11/2 にデバイスで解消を確かめた(CMP 3/3・Flutter 4/4 が押せた・`scrollToTop` 2/2 が `msg_00` へ戻った。見えている部分が床に届かない要素を撃たない直しと、Android の払いをタッチの遊びの分だけ延ばす直しの後)
- 11/4: 横向きで失敗する探索を M1Max の Emulator で 36 回(と、存在しない行の探索を 4 台)回してロック画面の文言は 0 回。木の持ち主はアプリで種別は nil・前面はアプリ(`inFront`)。Android でロック画面と言うのは木の持ち主が `com.android.systemui` のときだけで、横向きで systemui が持ち主の木が出る契機は再現できていない

### OI-146 React Native の iOS の横向きで、寄せが収まりきらなかった回の次の画面の最初のタップが飲まれる
- 状態: 再現済み
- 確認: コミット未記録(2026-11-03)
- 属性: 着手可

E2E-RN の iOS(inapp-boost モード)を `orientation=landscape` で全台(8台)へ配ると、ホームの `tap("#nav_gesture")` の寄せが「not fully inside」(収まりきらない)になった2台だけで、遷移したジェスチャ画面の最初の `tap("#btn_tap_counter")` が飲まれた(`tap=1` / `tap=2`。どちらも in-app の合成タッチで「the screen looked the same when it settled」の注記付き = 誤った成功ではなく後の確かめで赤)。寄せが収まった6台では 0 件。寄せの払いの慣性・跳ね返りが残ったまま遷移し、最初のタッチが RN の応答者の切り替えに使われた疑い(未確認)。次に見るもの: 寄せの後に整定を待っているか・飲まれた回の木の動き
- 11/4: 手元の 8 台・横向きで 2 周とも 4/8 で `tap("#btn_tap_counter")` が飲まれた(`tap=1` / `tap=2`。注記は「飲まれたかも」を名指し = 黙りではない)。同じ run で手順 53 の上への払いが検出されない赤も 4/8(台帳に無い形・HEAD の対照は無し)

### OI-155 ft_batch の途中で別アプリが前面へ来た後の tap を ok と言い、前面を離れたことを言わずアプリの古い木を返す
- 状態: 再現済み
- 確認: コミット未記録(2026-11-03)
- 属性: 着手可

11/3 の6周目の探索(`_work/explore-20261103a/findings-*.md`)。冷えた状態から起動した設定アプリが手の開始から 3.8〜4.2 秒後に前面へ来た回で 7/7(MCP。2.2 秒後なら 422 で止まる 9/10 = batch F2)。各行の警告は「画面が変わらなかった」だけで、結論は「All 5 step(s) ran」
- 11/3: iOS の飲まれた tap の警告に「別アプリが既に前面へ来ていた可能性」を足した(文言のみ)。前面の移動そのものの検出は、/appstate が別アプリの起動後 1〜2 秒は前面と答え続けるため入れていない

### OI-158 React Native の iOS で、キーボードが出たまま見えている行を tap するとキーボードが閉じるだけで押されず ok
- 状態: 再現済み
- 確認: 2ecbb646(2026-11-03)
- 属性: 着手可

11/3 の7周目の探索(e2ey F5)。E2EY-RN の反転チャットで `type` → `tap("送信")` の後の `tap("メッセージ 57")` が、iOS(inapp-boost)で押されずに ok(4/4)。Android は撃つ前に戻るキーで閉じて直った。iOS は閉じる手段が「キーボードの上の空きを叩く」だけで、行が画面を埋めて叩いても閉じない(実測 `tapping (326, 512) above the keyboard did not close it`)。**今は閉じられなかった事実を注記に残すだけ**(`keyboardStayedUpNote`。撃つ判断は変えない = `keyboardShouldPersistTaps` を変えたアプリでは押せるので断らない)。残り: iOS で副作用なく閉じる手段(欄の resign 等。ブリッジの変更)・MCP の ft_tap 等はこの判定を呼んでいない(`PreFireGuard` の doc は MCP も呼ぶと書くが未実装)
- 11/4: MCP の `ft_tap` はキーボードが閉じるだけで押されなかった形の注記(`keyboardStayedUpNote`)を出さない(画面が変わらなかったことは別の警告で言う = 黙りではない)

### OI-161 探索・横向きの残り(7周目)
- 状態: 再現済み
- 確認: コミット未記録(2026-11-03)
- 属性: 着手可・木に材料なし

11/3 の7周目の探索(`_work/explore-20261103b/findings-*.md`)と、直しのデバイスでの確かめ。①横向きの低い一覧で1回の送りが行の高さを下回り既定の maxSwipes で届かない(ascroll F1)②Android の横向きの無限スクロールで特定の行を飛び越して「端に着いた」と断定(ascroll F5。15・45・57 で 5/5)③E2EY-RN の A11 横向きの `tap("#post_39", scroll: .down)` が2回払っただけで「nothing moved at all」の赤(3/6)④iOS の半開のシートの中を `tap(scroll:)` で探すと背面の一覧を送る(e2ey F2・iOS 12/12。`scrollFrame:` を付ければ通る)⑤ft_batch の途中で設定アプリが前面へ来た後の tap が警告なしの ok(batch F3。結論に「変化を見ていない触る手」を名指す形は入れた・根本未確定)⑥同じスイッチを続けて tap すると2回目に「may have been swallowed」(batch F8。Android の読みの古さの疑い)⑦Android で払いで切れた行への `select("行 01")` が空要素を返すまで 2.7〜22.3 秒(12 回。見えている行は 0.3〜0.5 秒)。調べた1件は所要 7.1 秒のうち guardMs 6.3 秒 = FM の推論2回(空の転写の訊き直しを含む。枠待ちは 1ms)で、select 固有の待ちではない(exist / textIs も同じ評価で同じ時間)。22 秒の回は6台へ同時に配った負荷の疑い(未確認。見るなら結果 JSON の `fm.byKind.occlusion.maxMs` と `gateWaitMaxMs`)⑧Flutter の横向きで Column からはみ出した欄の、木の上では覆われていない帯(タブの上の 32px)を押しても何にも当たらない(座標で直接撃って 4/4 無反応。親の箱の外の子へ Flutter のヒットテストが届かない推定。木に親の箱が無い)= 覆われた対象の見えている部分を押す tap は注記付きの ok のまま何も起きない⑨Android で欄を tap した後のキーボードの出現待ち(`armKeyboardAppearanceWaitAfterFieldTap`)が、type を撃っていないのに注記 `keyboard-not-shown-after-type` を出す(名前と事実の食い違い)⑩E2EY-iOS の `select("#txt_loading_state")` が「not visible: returned an empty element」なのに、続く `textIs("state=loaded")` が緑(1 回)⑪覆いの最前面がタブの中の文字(押せない型)のときは、見えている部分を押す扱いに入らず従来どおり警告して中心を撃つ(押せる祖先へ持ち上げる案は、祖先の復元が preorder+depth で行・包む祖先・無関係のボタンを拾うので外した)
- 11/4: ②を直した: 下端で見切れて現れた行が、寄せの1本で行き過ぎて上端で見切れた形になり、見切れ回収の向きが「中心が容器の中なら探索の向きのまま」だったのでさらに遠ざかって飛び越していた。中心が中でも片方の縁で見切れていれば、その縁の側へ戻す(`TapTargetGeometry.clippedEdgeRecoveryDirection`)。M1Max の Emulator 4 台・横向きで行 15・45・57 が修正前 12/12 赤 → 修正後 12/12 緑・縦向き 28/28 緑。同じ横向きで貼り付く見出し・グリッド・伸縮するヘッダは 12/12 赤(「still moving … raise maxSwipes」= ①の型。HEAD の対照は無し)

### OI-156 iOS のテキストの可視性検証が、ボタンは縁で切れていてもタブバーの下でも読まずに緑にする
- 状態: 再現済み
- 確認: 0a67f89b(2026-11-04)
- 属性: 着手可・木に材料なし

11/3 の7周目の探索(vis F2・F3)。**Android は直った**(行・ボタンが同じ label の文字の子を1つだけ持つときはその子で確かめる = `OcclusionEligibility.sameLabelTextDescendant`)。**iOS の行(セル)は 11/4 に赤へ上げた**(文字の子を持たない `clickable` / `cell` を行の枠で OCR だけで読む = `OcclusionEligibility.isLabelledRowWithoutText`。11/3 の回帰の全数で警告 2 件・2 件とも真陽性 = 横向きで潰れた一覧の行・木の順で掴んだ見えない行。後者は in-app の木のセルの並びを直し、前者は E2E-iOS のシナリオを直した)。残り: ボタン(`button "自己修復"` のタブバーの下)は対象外のまま(アイコンのボタンは描かれない説明文をラベルに持つ)

### OI-163 探索の残り(8周目)
- 状態: 再現済み
- 確認: 4605aa35(2026-11-03)
- 属性: 着手可・木に材料なし

11/3 の8周目の探索(`_work/explore-20261103c/findings-*.md`)で直さなかったもの。**重いもの**: ①iOS の CMP で、キーボードの下に隠れた欄へ clearInput が叩き直した点がかなキーボードのキーで、焦点のある別の欄を書き換えてから 422 で落ち、壊したことを言わない(kbd F3・1/1。11/3: 再現 8 台中 7 台。Enter で焦点が次の欄へ移る間は Compose が欄を動かし、XCUITest のキーボードの枠は画面の外で来る。①ホストが XCUITest で消す前に撮り直した欄を in-app のキーボードの枠と突き合わせる ②ランナーと in-app は焦点のタップの点がキーの上なら見えている帯へ寄せ、帯が無ければ撃たずに staleRef ③in-app の「直前の tap が焦点を立てた」は受け口が欄の上にあるときだけ、にして 16 回中 0 回。残り: 撃たずに断り続けて時間切れの赤が xcuitest 経路で 8 回中 1〜2 回あった(壊さない)③Flutter の Android の横向きで、キーボードを閉じた後に覆われた欄の見えている部分を押す tap が 5 回中 1 回タブを押して遷移した(land F2。11/3: 閉じた後は対象と覆いの枠が続けて同じになるまで読み直してから部分を決めるようにして 18 回中 0 回。押せた回も何も起きない形は OI-161 ⑧ のまま・長押しの部分押しは事後の確かめを通らないまま)④iOS の CMP の xcuitest モードと MCP で、タブの下に潜った行への tap がメディアのタブを押す(cover F4・既定の inapp-boost の DSL では出ない。11/4: 「木の順で奥に読まれる操作できる要素が中心を含み、ヒットテストが当たらないと断言したら覆いとして送る/外れなければ撃たない」を2回試して取り消した = E2EY-CMP の xcuitest で 8 回中 8 回赤のまま。送った後の木では行がタブから外れて見えるのに撃つとタブに当たり(慣性が止まるまで読み直しても同じ)、CMP の iOS の XCUITest の木の行の位置が描かれた位置とずれている疑い(手前を木だけで読めない形)。3 回は上の固定領域の裏でタップが飲まれる別の形(次の確かめで赤))。**その他**: ⑤CMP の iOS の横向きで MCP の `ft_tap` ref が、全画面で申告された容器のせいで縁のバーの外の描かれていない片を「見えている部分」として押す(land F5)⑥Android の RN でタブの下の行を送って外してから押す tap が飲まれて ok(cover F3・慣性の疑い)⑦iOS の inapp-boost で外側の容器に切り取られて見えない行への tap が送らず注記なしで ok(cover F1・in-app は要素を直接押すので echo は合う)⑧SwiftUI の横向きで高さ 0 に潰れた一覧の探索の払いが横のカルーセルを押す(land F3)⑨Flutter の Android の横向きで送れる容器が2つあると「nothing moved at all」で赤・scrollFrame の案内も無い(land F4)⑩Android で上端の一覧への `select` / `notExist` の `scroll: .up` が端を確かめる払いで引っ張って更新を2〜4回走らせる(scroll F1・4 SUT で 14/14)・下端から上の行を探しても1回走る(scroll F2・CMP / RN)⑪ブリッジ不達で振り直したシナリオが同じ不達のレーンへ戻る(run F2)⑫決定的に赤のシナリオだけで健全な端末が離脱する(run F1。11/3: 最後に通ってから別のデバイスでも落ちたシナリオの赤は数えないようにした = `ScenarioFailureWitnesses`。各シナリオを1回ずつ回す初回の run で赤が多いと離脱する形は残る = 区別の材料が無い)⑬Flutter の Android で続けて撃った2回目の pressEnter が届かずに ok(kbd F5)⑭CMP の Android で OTP の箱への `type("#otp_box_3")` が 500「target node not found」(kbd F2)⑮Android の pressEnter の失敗文が「in-app bridge … no XCUITest bridge」(kbd F6・`StepExecutor+DirectActions.swift`)⑯アプリが欄を空にした後の type に「the field already held」の事実と違う注記(kbd F4)⑰キーボードが出たまま `type("#field_bottom", scroll: .down)` が「nothing moved at all」(kbd F7)⑱Flutter の iOS の secure 欄の後の hideKeyboard が「still shown」(前の周の land F4・観測が要る)⑲MCP の ref で覆われた対象の見えている部分を押した応答に、中心についての古い警告(「may have hit #btn_bottom_b」・「under the sticky header」)が先頭に残る(後ろの文が「Warnings above about the frame's centre do not describe this point」と打ち消すので矛盾はしないが紛らわしい)

### OI-167 探索の残り(9周目)
- 状態: 再現済み
- 確認: 22012640(2026-11-04)
- 属性: 着手可

11/4 の9周目の探索(`_work/explore-20261104a/findings-*.md`)で直さなかったもの(副作用だった replace の順序とセルの並びの一部は 9df8df9e で直した)。②上端で 8〜12pt だけ見える行を「見えている部分」として撃つ(ilocal F1)③RN の iOS で、隠れたバーの下のボタンへの tap が覆いの下と書きながら撃って ✅(iultra F3)。`scroll:` の無い tap は直した(対象は隠れるバー自身を容器と推定されて判定の門で外れていた。一覧と交わらない容器は外の対象として扱い、撃たずに `scroll: .up` を案内する。案内どおりに書くと押せる)。逆向きの `scroll:` と hold は未確認④xcuitest の E2EX-CMP / inapp-boost の E2EX-RN で、別の欄の直後の `type(#field_number)` の焦点が動かず前の欄に打つ(im4 F2・F4。4/4・1/1。読み返しが赤にするので黙りではない)⑤E2EX-RN で Enter で焦点が移った直後の replace の type が 422「focus did not move」(im4 F6・両モード 2/2・撃たずに断る)⑥読み込み中に始めた向き付きの探索が既定の待ちで 0.6 秒で「動かない」と断定して赤・文言が `waitSeconds:` に触れない(iultra F1・F2)⑦横向きの入力画面のキーボードの下の欄への type の断り文の座標が実画面と合わない(ilocal F2)⑧覆われていない行に「the target is covered by」の注記(ilocal F3)⑨CMP の Android の横向きの伸縮するヘッダで、上への払いが2回目以降動かない(素の `scrollUp()` でも = 払いの始点の問題の疑い。amax F1・6/6)⑪11/4 のフル E2EX(M1Ultra)で E2EX-RN の iOS が全シナリオ赤: アプリが起動直後の tap で JS の致命的エラー(`RCTExceptionsManager reportFatal` の SIGABRT・クラッシュレポート 25 件)。同じアプリのまま直後に回し直すと 47/48 緑(残り1本はツールチップの既知の形)で再現せず。同じ日の2回目のフル E2EX でも全滅(2/2)。JS のエラーは毎回 `Failed to call into JavaScript module method RCTEventEmitter.receiveEvent(). Module has not been registered as callable`(最初の1回は供給の途中)。単独の実行では 4/4 緑(ディスパッチ2回・E2EX-CMP の直後・アプリを消してから・M1Ultra のクローンで直接)= フル E2EX の流れの中でだけ出る ⑫供給で in-app の dylib のビルドが失敗した run の機械ごとの行が `✅ local exit=0 ran=0` と出る(全体の終了コードは 1・「どのデバイスにも渡らなかった」の警告は出る)

### OI-168 探索の残り(10周目)
- 状態: 再現済み
- 確認: a5e87ce1(2026-11-04)
- 属性: 着手可

11/4 の10周目の探索(`_work/explore-20261104b/findings-*.md`)で直さなかったもの(直したものは 2dcc58ab・a5e87ce1・9c0e47eb)。③同じ序数のセレクタ(`.button[5]`)が in-app の木と XCUITest の木で別の要素になる(ilocal F6。in-app はナビゲーションバーを末尾に置く = ft_batch で通した列がシナリオで別の行を押す)⑥E2EY-CMP の Android の横向きの選択モードの一覧で、寄せの注記付きの `tap("項目 1*")` が ✅ なのに行が開かず選択モードに入る(amax F4・5 run 中 4)⑦`settle: false` の flick の直後のワイルドカードの tap が、寄せの後に見失って赤(im4 F6・既定の経路ではない)

### OI-169 探索の残り(11・12周目)
- 状態: 再現済み
- 確認: b41c86f0(2026-11-04)
- 属性: 着手可

11/4 の12周目の探索(`_work/explore-20261104d/findings-*.md`)で観測し、直さなかったもの。11周目の所見(`_work/explore-20261104c/`)の回し直しで直っていなかった分は12周目の各ファイルの冒頭にある(OI-170 の形を除く)。①inapp-boost でシナリオの途中にアプリのプロセスが死ぬと「ブリッジに届かない」として振り直し、2回目が緑なら run は `All passed`・exit 0(ilocal F17・外からの `simctl terminate` で 2/2。ツールは「process not running — it may have crashed」と観測している)②一覧の上に浮いた FAB の tap に「centre is covered by #row_f_NN」の注記(ilocal F15・SwiftUI 5/5・CMP 5/5。実際には FAB を押せている)③RN の縦で、バーが隠れた後の `tap("#fab_hiding", scroll: .up)` が not found・案内が `maxSwipes`(iultra F3・5/5。手で1回 `scrollUp()` すれば押せる)④CMP で探索が行き過ぎ、整定の待ちが打ち切られた後に `waitSeconds:` を案内して赤(iultra F5・13回中3回)⑤doubleTap の not found に `scroll:` の案内が無い(iultra F7。doubleTap は `scroll:` を持たないので先に送る手を案内する形)⑥`select(..., scroll: .up)` の探索の失敗の理由が捨てられ、後続の `textIs` は理由の無い not found(im4 F5・4/4。同じ状態の `exist` は理由を言う)⑦E2EY-Flutter の Android の A11(NestedScrollView + TabBarView)で、一覧の上端の近くの行への tap が ✅ なのに押されていない(amax F1・投稿 19/28・メディア 2/4・いいね 3/4。`scrollUp(repeat: 3)` → `wait(1.5)` → scroll 無しの tap でも 3/4 = 慣性では説明できない。外側のヘッダが伸びた後の内側の一覧の a11y の枠と描画のずれを疑う。撃った座標と描画の突き合わせが未了)⑧E2EY-Android の横向き: 枠なしの `scrollUp` が動かずに ✅(A10・4/4)・`scrollToTop` が上端に着かずに ✅(4/4)・`tap(scroll: .up)` の nothing moved の赤が逆向きの `scroll: .down` だけを案内し `scrollFrame` に触れない(A1・4/4)⑨11/4 の回帰(5754bf5d)で E2EX-Android の「スワイプで行を削除できること」S0010 が M1Max で1回赤(`swipeBy("#swipe_row_3", -0.5, 0)` の後も `removed=none`)。手元の 8 台へ同時に回すと 8/8 緑

### OI-171 探索の残り(13周目)
- 状態: 再現済み
- 確認: 6344e74e(2026-11-05)
- 属性: 着手可

11/5 の13周目の探索(20分・`_work/explore-20261105a/findings-*.md`)で観測し、直さなかったもの。①E2EY-Android の A9 でシートを全開にした裏の `本文 10` への `tap(scroll: .down)` が ✅(注記「may have hit #list_queue」だけ)で、実際はキューの行を押した(amax F1・5/5。探索の送りもしない = 最初の木で撃つ前の注記に落ちる。Android の z は塗り順として使っていない。塗り順の無い木の形なので OI-170 と同じく推測で直さない = `.claude/rules/fm-occlusion.md`)②同じ A9 でシートを半分にしたまま背面の `本文 20` / `本文 39` を `tap(scroll: .down)` で探すと、背面の一覧が動かないまま「the scroll area reached its end」で赤・対処文は対象の居ない `#list_queue` を勧める(amax F2・10/10。`scrollFrame: "#list_main"` でも 4/4 赤 = 払いの始点がシートの上に落ちる疑い)③M4Max(macOS 26.7.2)の OCR で `tap(linkText: "@alice")` が同じ行の URL の位置を撃って ✅(im4 F1・4回中1回。OI-139 の機械)。割り出した枠を読み直して確かめる直しを試したが、手元の E2EY-iOS で 24 回中1回、OCR が `a¿` と読んでリンクを見つけられない赤が出た(直しのせいかは未確定)ので入れていない(差分は `_work/explore-20261105a/linktext-verify.patch`)④CMP の A10 の `scrollTo("#row_h_30")` が整定の打ち切り(poll limit)のまま ok を返し、対象が固定領域の裏へ流れる(ilocal F6・4/4)。整定が打ち切られた回だけ撮り直して確かめる直しを入れた(7e0cfb31)。11/5 に手元の4台で直した版 4/4 緑(うち3回は撮り直しで見えず探索を続け、行き過ぎの逆走査で見つけた)・直しを外した版 3/4 赤(同じ形)= 直った

## 要判断

(いまこの属性を先頭に持つ項目は無い。要判断を含む項目は属性ごとの一覧の表を見る)

## 木に材料なし

### OI-121 ref なしの secure 欄の追記の誤った緑
- 状態: 再現済み
- 確認: コミット未記録(2026-11-02)
- 属性: 木に材料なし

`ab` のあと ref なしで `abかな` を打つとかなが落ちても緑。木からは「焦点を保った」と「タップで取り戻した」を区別できない(ロケータありは赤)。直すには直前に同じ欄へ打った記憶が要る。

### OI-128 貼り付くタブ帯の下の id の無いボタン
- 状態: 再現済み
- 確認: コミット未記録(2026-11-02)
- 属性: 木に材料なし

E2EY Flutter の折りたたみヘッダ: ヘッダを畳むとタブ帯の下に隠れる `post_02` の ref の ft_tap が無警告の done でタブに当たる(4/4)。`tab_posts` には逆向きの覆いの警告が出る(2/2。実際は当たっている)。
- 2026-11-02: 自動シナリオで 0/9・ref の形は状態を作れず未測定

### OI-129 5周目の探索で残した所見
- 状態: 再現済み
- 確認: コミット未記録(2026-11-02)
- 属性: 木に材料なし・着手可

`explore-20261102a/findings-*.md`。木だけでは手前を読めない形: はみ出した行の tap が別の部品に当たる(se3 F4・撃つ。注記のみ)、隠れたバーのボタンは警告が出るが撃つ(sim F10)、枠なしの払いが一覧の外に落ちる(pixel F7・F8。キーボードなしはブリッジ既定に任せる決定)。`scroll-leftover` の誤検知(emu F5 の横向きの固定ヘッダ・sim F6 の遷移中の木)。横向きの全画面 IME の打鍵は MCP の警告だけで DSL は未対応(emu F1)。SwiftUI のスライダへの `swipeBy` が動かない(se3 F5)。
- 11/4: 判断: 横向きの全画面 IME の打鍵は DSL にも MCP と同じ判定で警告を出す(着手可)。`scroll-leftover` の誤検知も着手可。手前を木だけで読めない形(はみ出した行・隠れたバー)はブリッジの `z` 待ち(in-app の UIKit・RN は 11/4 に入れた)

## 低頻度

### OI-135 xcuitest モードの CMP の複数行で、焦点を取り戻した打ち足しが先頭へ入る
- 状態: 再現済み
- 確認: 430d1097(2026-11-02)
- 属性: 低頻度

`テキスト入力が正しくechoされること.S0060` が `xL3` で赤。M1Ultra 13/18・M1Max 1/4・手元 0/24(手元の赤4件は OI-137)。Cmd+↓ で末尾へ送る処理(`moveCursorToEndAfterRefocus`)が効かない回がある。同じランナーの入力の処理で今朝は緑だったので、タイミングの疑い(推測)。
- 11/2(ブリッジ 246): 打った文字が元の値の前に入った形を読み返しで見分けて、末尾へ送ってから打ち直すようにした。M1Ultra の6台 × 2周で 1/12(以前 13/18)。残った1件は `actual "x"` = 元の値が丸ごと消えた別の形

### OI-137 マシンの FM・Vision が止まっていた間に、Simulator の文字消えでレーンが外れた
- 状態: 推測
- 確認: 430d1097(2026-11-02)
- 属性: 低頻度

起動から約 11 時間の M2Ultra で FM が dead・Vision の OCR が空(`Hello 123` の絵も読めない)だった間、E2E-CMP の xcuitest が「none of the N text element(s) … is drawn」で 4/24 赤・レーン離脱。**この判定(`RenderCollapse`)は OCR ではなく切り出した領域の輝度のばらつきで見る**ので、絵に文字が無かったのは事実(当初「OCR が止まると誤って言う」と書いたのは誤り)。マシンの劣化(GPU / ANE)で Simulator の描画が崩れたのか、偶然の重なりかは分けていない。再起動後に同じ形が出るかで見る。`swift test` の RegionText 系 14 件の赤は同じ時刻の OCR の停止による。

### OI-127 手元の Emulator の白紙が回帰の終盤に集中した
- 状態: 再現済み
- 確認: コミット未記録(2026-11-02)
- 属性: 低頻度

配信なしのフル回帰(73a31d8b)で、23:06 前後に手元の Emulator 4台が白紙になり `E2EX-RN/android` の1本が赤。`E2EY-Android` も1本が再実行。同じ対象を単独で3周(144 本)回すと白紙0件で再現しない。終了時の手元は `videoEncoder=dead`。原因は未測定。
- 11/4: 配信を止めずに回したフル回帰(22012640)で、手元の Emulator の白紙(テキストの可視性検証が「スクリーンショットのアプリの領域が一色」)が E2E-RN・E2EX-RN の Android で計 9 件。同じシナリオを手元の 8 台へ配ると配信ありで 5/8 赤・**配信を止めると 8/8 緑**(E2EX-RN のチップ)= 手元の配信と Emulator のスクリーンショットの干渉。同じ日の朝の配信ありの回帰は 24/24 緑 = いつも起きるわけではない

### OI-130 回帰で一度だけ赤になった形
- 状態: 再現済み
- 確認: コミット未記録(2026-11-02)
- 属性: 低頻度

73a31d8b と 0316a138 のフル回帰で、Emulator の白紙と E2EY-CMP の「大半まで払うと削除まで走る」が各1回赤。後者は単独の 144 本で再現しない。回帰の負荷でだけ出るかは未測定。

### OI-132 Flutter の iOS で別の欄へ打った後、キーボードの裏へ送られた欄が木から消えて `type` が赤
- 状態: 再現済み
- 確認: コミット未記録(2026-11-02)
- 属性: 低頻度

E2EX-Flutter・xcuitest モード・`type "#field_number" "12"; type "#field_first" "a"; type "#field_number" "1"` が「cannot resolve the locator … tapping (8, 512) above the keyboard did not close it」で赤。修正なしの版で 7/25、欄の読み返しの修正後で 3/24(8 台の --broadcast × 3 周)= 以前からある形。低率の形なので2つの差は判定できない。キーボードを閉じる手(背景のタップ)が閉じなかった回に出る。原因は未調査。

11/2 朝に測定: 手元の 5 台の --broadcast で 1/160(失敗の回は 1 ステップの読みが 3.2 秒 = 高負荷の局面)。押す点は `KeyboardDismissPoint.candidates` の先頭の x=8。Flutter の戻るジェスチャの帯に入る疑いと、負荷でタップが落ちる疑いは未検証。率が低いので効果の判定に数百周が要る。
- 11/3: 背景タップの点で画面の左右の端の1列を後回しにした(`KeyboardDismissPoint`。端の列は戻るジェスチャの帯に入る疑い = 未検証)。率が低いので効果の判定には数百本が要る

### OI-134 launch 直後の最初の replace の type が「nothing has keyboard focus」で赤
- 状態: 再現済み
- 確認: コミット未記録(2026-11-02)
- 属性: 低頻度

E2EX-Flutter・xcuitest モード。`type("#field_number", "12", replace: true)` が launch 直後の最初の手のとき 5 台中 1 台が 422(11/2)。原因は未調査。
11/2 に測り直して 0/96(4 台)。launch が速い回・高負荷では未測定。

### OI-164 E2EX-Flutter の iOS(inapp-boost)で、検索バーへの type の後に候補が出ず `exist("#suggestion_apricot")` が赤
- 状態: 再現済み
- 確認: 45dc496a(2026-11-03)
- 属性: 低頻度

11/3 の回帰(45dc496a)で1件。手元の4台へ配って 24 回中 4 回(45dc496a)・3 回(4605aa35)・2 回(ed451003 = in-app の打鍵の直しより前)で同じ形 = この日の変更より前からある。`tap("#field_search")` → `type(".textField", "ap")` で欄の value は "ap" になるのに、候補の一覧が空のまま 5 秒(失敗時の木に候補の行が1つも無い)。赤の回はどれも type が「fell back to XCUITest」だったが、落ちても緑の回の方が多い(8 回中 4〜7 回が落ちる)。次に見るもの: in-app の打鍵を断った理由(結果 JSON の注記)と、XCUITest の打鍵で Flutter の onChanged が走らない形があるか
- 11/4: 手元の 8 台 × 3 周で 1/24(5b1f16b9)。赤の回は type が XCUITest へ回った回で、XCUITest で打った 13 回中 1 回・in-app で打てた 11 回では 0 回。XCUITest の打鍵の後に Flutter の候補の更新が走らない回がある形(Flutter の入力の受け口の調べが要る)

### OI-165 E2EY-Android の `折りたたみヘッダとタブを扱えること.S0030` で、`flickRightToLeft` の後にタブが切り替わらず `tab=posts` のまま赤
- 状態: 再現済み
- 確認: d5b0434b(2026-11-03)
- 属性: 低頻度

11/3 の回帰(d5b0434b)の E2EY-Android の 42 本中 1 本。`flickRightToLeft` は ✅ で、次の `textIs("#txt_tabhdr_tab", "tab=media")` が「actual "tab=posts"」で赤(ページャが送られていない)。11/4 に M1Max の Emulator 4 台 × 3 周で 12 回中 0 回(845de5a)。この日の変更(焦点を当てるタップ・キーボード・連続失敗の数え方)は横の払いの経路を通らない。次に見るもの: 赤の回の flick の始点と、ページャの吸着(途中で離すと元へ戻る)との関係

## 環境側

### OI-139 M4Max(macOS 26.7.2)の Vision の OCR が `@alice` を `dalice` と読み、文中のリンクの OCR の位置決めが失敗する
- 状態: 再現済み
- 確認: 16447ca9(2026-11-02)
- 属性: 環境側・着手可

E2EY-iOS の「文中のリンクを押せること」S0020 が M4Max で 6/6 赤(`OCR read: "dalice dh t1https :|/example.com/a"`)。他のマシンは macOS 27.2(26B123)で、M4Max だけ 26.7.2(25G332)。同じシナリオは M1Ultra で 10/12 緑(赤の2本は別の形)。手は2つ: M4Max の macOS を他とそろえる(回帰に参加するマシンの前提として docs/verification/operations.md へ足す)か、リンクの文字列の照合で `@` の読み誤りを許すか(別のリンクを押す危険があるので、許すなら同じ行の他の候補と区別できるときだけ)
- 11/4: 12周目の探索(im4 F3)で同じ機械の OCR が E2E-iOS のキーボードの覆い画面の "up" を "dn" と読み、OCR だけの判定で「not visually visible」の誤った赤(13/13。画面には "up" がはっきり描かれている)

## 据え置き

### OI-170 塗り順の無い iOS の木で、覆われた・描かれていない要素を in-app が押す
- 状態: 再現済み
- 確認: b41c86f0(2026-11-04)
- 属性: 据え置き・木に材料なし

SwiftUI・CMP・Flutter の iOS の in-app の木は塗り順 `z` を持たない(FD-1.4)。シートの裏の行・隠れたバーのボタン・縮んだヘッダの中身を、in-app が直接動かして ok になる(12周目 ilocal F18: CMP 11/11・Flutter 4/4 / iultra F1・F2・F6・F8: 全開・半分のシートの裏の行への tap・doubleTap・hold が SwiftUI・Flutter・CMP で ok かキューの行に当たる)。RN と UIKit は `z` で断る。前の周の同じ形: CMP の iOS の隠れるバーへの `hold(scroll: .up)` が何も押さずに ✅(9周目 iultra F4・2/7、手元で 2/10。隠れた間の in-app の木は容器 `#bar_top_hiding` を落とすのに中の「受信トレイ」と `#btn_top_action` を固定領域の下に残す。固定領域の不透明な背景は木に無い。tap は in-app が描かれていないノードを直接動かすので効き、hold は本物のタッチなので固定領域に当たる)/ CMP の iOS の縮み切ったヘッダの `#btn_follow`・隠れたバーの `#btn_top_action` への scroll の無い触る操作が ✅(10周目 iultra F2)。XCUITest の木(MCP の ft_batch・ft_tap・DSL の xcuitest モード)でも覆いが手前と読めず断らない(10周目 ilocal F4。xcuitest は `scroll: .up` を書いても何も押さない)。9〜11周目に木の順の推測を足すたびに別の縁で誤った赤が出たので、推測は足さない(ユーザー決定 2026-11-04)。既知の制約として FD-2.1 と user-docs「覆われた要素を押した後は結果を確かめる」に書いた。探索ではこの形を新しい所見に数えない。見直すのは、自前描画・SwiftUI で塗り順か当たり判定をブリッジが申告できるようになったとき
- 11/5: XCUITest の `isHittable`(`GET /hittable`)を材料にできるか測った(手元の -01・E2EY・各1回)。**false は全部正しかった**(半分のシートの裏の行 = CMP・Flutter・RN / 隠れたバーのボタン = CMP・SwiftUI / 縮んだヘッダの裏の行 = CMP・SwiftUI)。**true は誤ることがある**: SwiftUI の半分のシートの裏の行(全部 true)・CMP の縮んだヘッダでナビゲーションバーの裏に隠れた `btn_follow`(true・絵で隠れていると確認)。= true では「押せる」と言えないので、推測の断りを照会で外すことはできない。使えるのは「false なら撃たない」側だけ
- 11/5 の直し: 塗り順の無い iOS の木で、撃つ点に別のスクロール容器の押せる要素が重なるときだけ `isHittable` を聞き、`false` なら撃たずに断る(`TapTargetGeometry.otherLayerCoverSuspect`・DSL の `coveredTouchPlan`・MCP の ref 経路。iOS v269)。**拾う形**: 半分のシートの裏の行(CMP・Flutter・RN)・隠れたバーのボタンと縮んだヘッダの裏の行(CMP・SwiftUI)。**残る形**: `true` が誤る SwiftUI の半分のシートの裏の行・CMP の縮んだヘッダでナビゲーションバーの裏の `#btn_follow`(押した後の確認が要る)

### OI-140 存在しない `--scenario` 名でも、先に全台のブリッジの供給が走ってから「scenario not found」になる
- 状態: 再現済み
- 確認: dea279d5(2026-11-02)
- 属性: 据え置き

11/2 の探索(1/1)。打ち間違えた名前で -04〜-08 のブリッジの起こし直しと再インストールが走り、他の作業の端末を巻き込んだ。シナリオ一覧はビルドと並行に解決する作り(CLAUDE.md「確定している `--scenario` だけで判断する」)なので、名前の照合を供給の前へ出すには一覧の解決を待つ必要がある。ビルドの要らない回(一覧が既にある回)だけ先に照合する形が候補
- 11/2: ビルドが要らない回は既に供給の前に断る(`ScenarioPreflight.rejectUnknownScenarios`。順序をテストで縛った)。台帳の形はビルドが要る回 = 一覧が無いまま供給を起こす作りで、前回の一覧は新しく足したシナリオを誤って弾くので使えない。ソースの文字列での照合は誤って弾く恐れがあり入れていない
- 11/3: 判断: このまま(ビルドが要る回は一覧が無いまま供給を起こす作り。前回の一覧で照合すると新しく足したシナリオを誤って弾く)

### OI-58 横向きで低い縦の一覧の枠なしの払いが一覧に当たらない
- 状態: 据え置き
- 確認: コミット未記録(2026-11-02)
- 属性: 据え置き
- 経緯: 発見: 10-30 の探索的テスト

- 「nothing moved at all」の経路でだけ、唯一のスクロール容器の中で払い直すようにした(E2EY-Flutter の横向きの `#list_chat` で 0/3)。修正を外した版で 3/3 が赤・修正ありで 0/3(同じ Emulator・`oi58-scrollto-low-list-landscape`)
- 容器が2つ以上の画面(E2E-Android のスクロール画面 = 高さ 94px の一覧とカルーセル)は払い直さず `scrollFrame` を勧めるだけで、枠なしの `scrollTo` は赤のまま。複数容器の画面でどの容器へ払い直すかの選択は判断待ち
- 11/4: 判断: 払い直し先は払う軸で絞った上で一意のときだけ(`ContainerGeometry.uniqueScrollContainer`)。それでも複数残る画面は木に区別の材料が無く、当てずっぽうに選ぶと別の一覧を動かすので、赤 + `scrollFrame` の案内のまま据え置く

