# 残件(未解決の不具合の候補)

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 台帳 | 未解決の不具合の候補(探索・回帰・負荷テスト・仕様監査で見つかり、まだ直していないもの) | 未解決の不具合の候補を探す/足す/直したら消すとき | 直した項目の経緯(→ コミット)・設計判断の根拠(→ [maintainer-notes/](maintainer-notes/README.md))・仕様監査で「欠陥ではなかった」と確かめた項目(→ MN-106) |

未解決の項目だけを置く。いまの項目の多くは探索の周回(20分・10/29 から。経緯は MN-107)と回帰で観測したもので、各項目に観測した日付・範囲・回数を書く。「状態」の「推測」は、症状の経路をコードから推して特定したもの(デバイスで再現していない)。

直したら項目を消す(経緯はコミットに残す)。検証・再現を試したら本文に `- 検証の所要(<日付>): <何をして>・<時間>` を書き、次の見積もりに使う(消す項目の所要は docs/verification/judgment.md の目安の表へ)。新しい残件は同じ形(見出しの ID と題・状態・確認・属性・運用・優先度の5行・本文)で足し、属性の節へ置く。
各項目は属性の次に `- 運用:` を置き、直らないまま運用で回避できるかを書く(**回避可** = 書き方・環境で避けられる / **再実行で吸収** = 低率の赤 / **要注意** = 誤った緑。押した後に結果を確かめるシナリオなら赤にできる / **回避不可** = 運用では避けられない / **合否に響かない** = 文言・注記・表示・時間の損だけ)。小項目ごとに違うときは番号ごとに書く。その次に `- 優先度:` を置く(**高** = 黙って合否を誤るか、普通の書き方で避けられない赤 / **中** = 誤った緑だが後続で赤になるか、避けるのに知識が要る / **低** = 回避可・再実行で吸収・合否に響かない・MCP や特定の機械だけ)。

## 目次

- 属性ごとの一覧
- 着手可
- 要測定
- 要判断
- 木に材料なし
- 低頻度
- 環境側
- 据え置き

## 属性ごとの一覧

各項目に当てはまる属性を**全部**付ける(`- 属性:` の行に `・` 区切り)。**先頭は次の一手を決める属性**で、項目はその節に置く。下の表には属性ごとに該当する項目を全部載せる(同じ項目が複数の行に出る)。

| 属性 | 意味 | 件数 | 項目 |
|---|---|---|---|
| 着手可 | 原因を観測していて(MN-108)、次の手が決まっているもの | 0 |  |
| 要測定 | 症状は観測したが原因は推測のもの。次の一手は原因を測ること(推測のまま直さない = MN-108) | 2 | OI-366・OI-378 |
| 要判断 | 直し方の選択をユーザーが決めるもの | 0 |  |
| 木に材料なし | 木(スナップショット)に判定の材料が無く、ブリッジの申告など別の材料が要るもの | 14 | OI-156・OI-161・OI-163・OI-170・OI-200・OI-205・OI-211・OI-216・OI-238・OI-245・OI-279・OI-327・OI-386・OI-387 |
| 低頻度 | たまにしか出ない(数十〜数百回に1回)か、しばらく再現していないもの。効果の判定や再現に多くの周回が要る | 35 | OI-127・OI-137・OI-138・OI-146・OI-161・OI-163・OI-173・OI-177・OI-190・OI-196・OI-198・OI-214・OI-220・OI-221・OI-226・OI-228・OI-229・OI-231・OI-233・OI-234・OI-236・OI-250・OI-269・OI-289・OI-292・OI-297・OI-314・OI-320・OI-321・OI-325・OI-346・OI-359・OI-366・OI-378・OI-385 |
| 環境側 | OS・Simulator・GPU・マシンの側が原因と測定で分かった部分があるもの。ツールは検知と回復まで | 11 | OI-184・OI-198・OI-214・OI-221・OI-228・OI-231・OI-233・OI-234・OI-235・OI-315・OI-385 |
| 据え置き | 直さないと決めたもの。症状が出たら見直す | 47 | OI-58・OI-140・OI-155・OI-161・OI-168・OI-170・OI-172・OI-173・OI-181・OI-182・OI-186・OI-192・OI-193・OI-194・OI-195・OI-197・OI-200・OI-201・OI-202・OI-204・OI-205・OI-206・OI-207・OI-208・OI-209・OI-210・OI-211・OI-216・OI-219・OI-221・OI-224・OI-225・OI-228・OI-233・OI-234・OI-235・OI-236・OI-253・OI-255・OI-256・OI-282・OI-291・OI-298・OI-315・OI-370・OI-379・OI-385 |

低頻度の項目は、手順のシナリオが分かるものを `Scripts/soak.py` で空いた機械に回し続けて出た回を貯める(対象の表は `Scripts/soak-targets.json`・使い方は docs/verification/operations.md)。各ステップの判定の分かれ目は結果 JSON の `trace`(docs/results-json.md)に残る。

## 着手可

## 要測定
### OI-378 Android の Emulator で、入力した欄を ACTION_SET_TEXT の後に見つけ直せず赤(文字は入っている)
- 状態: 再現済み
- 確認: ac3b32b62(2026-11-24)
- 属性: 要測定・低頻度
- 運用: 再実行で吸収 — 手元の同じ OS の Emulator では緑
- 優先度: 低 — 1回・リモートの1台だけ

出典: シナリオ作成の評価 11回目(2026-11-24・`_work/scen-eval-20261124c/`。作成 53 セッション(完了前の `ft_start_run` を初めて許した回)・本番 147 回・延べ 467 本・緑 353。各セッションの所見は `ws/TestProjects/<proj>/EVAL_REPORT.md`・本番のログは `logs/run-*.log`)
- 直しの見込み(未測定): `setTextAppendingAt` / `setTextAppending` は最初の ACTION_SET_TEXT が受理されたノードを控えて以後はそのノードだけを読む・撃つ形にした(二重入力の予防が目的)。控えたノードを固定するので「見つけ直し」自体が要らなくなり、この症状も消える見込み。控えを取り直せない(refresh が false)まま期限が来たときだけ、従来の文言 + refindFacts で赤になる。測ってから消す
- 観測: s_contacts_and(M1Max の Pixel 10 Pro(Android 17) Emulator)の `type ".textField&&placeholder=名||.textField[3]" "タロウ"` が `cannot type into the field that was tapped (the field could not be found again after ACTION_SET_TEXT was accepted, 4000ms waited; read back "", refresh ok, ACTION_SET_TEXT accepted 2 times, the IME window is in front …)` で赤。失敗時の木では名の欄が `value="タロウ" ph="名"`、よみがなの欄にも `value="タロウ"`(入力で画面が変わった)。手元の同じ OS の Emulator は緑。作成者の「入力でプレースホルダが消えて指し直せない」は誤り(入力後の木にも `ph="名"` があり、見つけ直しはセレクタを使わない)
- 材料: 見つけ直しは `AndroidRunner/…/InputInjector.java` の `findEditable(root, shortId, x, y, bounds)`。id の無い欄はタップ座標で追う。どの候補を拾った(拾えなかった)かの記録は無い
- 次の一手: 見つけ直しの候補の数と座標を注記に残す口を足し、次に出たとき「座標が外れたのか・欄が作り直されたのか」を分ける
- 処理(2026-11-24): 次の一手(見つけ直しの候補を注記に残す口)は Android のブリッジの変更なので、次の Android ブリッジの版上げで入れる(147 は要素の出どころの申告 = DR-230 だけで上げ、同乗させていない)
- 処理(2026-11-25・Android ブリッジ 148): 欄を1つも引けなかった周回にも、見つけ直しの候補の事実(findEditable が拾うもの)を失敗文に載せるようにした。次に出たら失敗文で「座標が外れたのか・欄が作り直されたのか」を分ける
- 照合(2026-11-25 夜・`fleetest/TestProjects` と `_work` の 11/24 以降の結果・ログを全数): 同じ文言は 11/24 の元の1回だけ(新しい発生なし)。Android ブリッジ 148 の材料(見つけ直しの候補の事実)は出たときに読む
- 2026-11-26(測る余地の見直し): 測る口は Android ブリッジ 148 で入っている。発生はリモートの1台で1回だけで、手元の同じ OS の Emulator は緑 = 出るのを待つ
- 検証の所要(11/26): 台帳の読み 約3分

## 要判断

## 木に材料なし
### OI-386 iPhone SE3(実機)で、キーボードで窓が縮んだ画面の複数行の欄への焦点タップが1つ上の欄に当たる(E2E-CMP S0060・決定的・両モード)
- 状態: 再現済み
- 確認: e5c085382(2026-11-25)
- 属性: 木に材料なし
- 運用: 回避の手は未確認(読み返しの検知が正しく赤にする = 誤った緑にはならない。"x" は別の欄に入る)
- 優先度: 低 — SE3(375x667 の小画面)だけ。iPhone 13・Simulator では出ていない

出典: 実機の関門(2026-11-24・供給の実機の門の修正の陽性対照の run)
- 観測: `テキスト入力が正しくechoされること.S0060` の `type "#field_multiline" "x"`(直前の type でキーボードが出て窓が 399 まで縮んだ状態)が、`#field_single` に "x" を入れて `TypedInputVerdict` の「別の欄が変わった・送り直さない」で赤。2回とも同じステップ・同じ文言。失敗時の木: `#field_single (16,276 343x27)`・`#field_multiline (16,303 343x40)` = 27pt 上の欄に当たっている
- 対照(2026-11-24): 変更一式より前(601bdaf49)を worktree に出し、同一の .app・同一端末で同じ run → S0060 だけ同じ形で赤。= 今回の変更の退行ではない
- inapp-boost でも同じステップ・同じ文言で赤(2026-11-24 の2本)= 撃ち手(XCUITest の合成 / in-app)に依らない
- 同族の疑い: 木の座標と描かれた位置のずれ(OI-163 ④「送った後の木では行がタブから外れて見えるのに撃つとタブに当たる」・OI-279)。ただしこちらはキーボードで窓が縮んだ直後の形で、両モードで出る点が OI-163 ④(xcuitest だけ)と違う
- 測定(2026-11-25・SE3・xcuitest・E2E-CMP を作り直した実機用ビルド): 同じ形で再現。失敗する手の直前の木は `#field_single (16,276 343x27)`・`#field_multiline (16,303 343x40)`、スクリーンショットでは単一行の欄が y≈276〜326(高さ約 50)に描かれ、複数行の欄はタブ(343〜)の下に隠れて見えない。複数行の欄の中心(y≈323)には単一行の欄が描かれている = **木の枠が描画と違う**(撃ち手の側ではない)。数分おいて読み直しても同じ枠 = 遅れではない。木の中の枠どうしは重ならず、焦点のある複数行の欄が木の先頭に並ぶ以外に目立つ形が無い。キーボードが閉じると木と描画は一致する(単一行 343x57・複数行 (16,493 343x101))
- 木に材料が無い理由: 枠どうしが整合しているので、「この枠は描かれていない」を木から言えない。焦点のある欄が木の先頭に並ぶ形は CMP の iOS の並べ方で、判定に使うなら反例(焦点のある欄が正しい位置の画面)と見分けられるかを既存の SUT で先に確かめる必要がある(MN-108)
- XCUITest の当たり判定も材料にならない(同日測定): 複数行の欄に打っただけで同じ食い違いが出た状態で、ランナーの `/hittable` は見えていない `#field_multiline` にも `#field_single` にも `true` を返した(木と同じアクセシビリティの情報から答える)
- 次の一手: 木の外の材料(撃つ点の描画 = スクリーンショットの画素と、木の枠の中に描かれた文字の突き合わせ)で見分けられるかを、反例(キーボードの無い同じ画面・背の高い画面)と合わせて測る。見分けられなければ据え置く(赤で止まる = 誤った緑にはならない)
- 棚卸し(2026-11-25 夜): 新しい材料なし(木の枠どうしは重ならないので、重なりの画素の読み = OI-387 の検知は当たらない。撃つ点の描画と木の枠の文字の突き合わせは未測定)
- 材料の見直し(2026-11-26・コードと API の読み、デバイス未測定): SE3 で、キーボードで縮んだ後の in-app の生の枠(`accessibilityFrame`)と CMP の根の view の大きさを記録すれば、古い窓の枠から来ているかを分けられる(実機が要る)
- 測定(2026-11-26・SE3・inapp-boost・in-app に一時的な診断の口): 同じ形で再現。失敗した状態で CMP の view(ComposeContainerView・SurfaceMetalView・OverlayInputView)は全部 375x667 = **窓・view は縮んでいない**(「古い窓の枠」ではない)。アクセシビリティの枠は、見えている範囲(タブの上端 343 まで)に押し込まれている: `#field_single` (16,276 343x27)(描画は高さ約50)・`#field_multiline` (16,303 343x40)(描画はタブの下)・その下の `#field_password`・`#btn_input_submit`・`#btn_input_clear`・`#txt_echo_multiline` は y 327 に高さ 0 で積み重なる = Compose(iOS)の画面外の枠のクランプ(FD の表の既知の性質)がキーボード表示中に起きた形。言えるのは「この画面の枠は押し込まれている」までで、対象の欄の枠が本物かは木から言えない = 判定に使うなら反例の画面で見分けられるかを先に確かめる(MN-108)。赤で止まる(安全側)ので据え置き
- 検証の所要(11/26): 実機用 dylib の作り直しと1本の run・枠の読み 約15分

### OI-387 Android の Flutter で、木に残る覆い(非モーダルの常駐シート)の裏の行への検証が注記なしの ✅
- 状態: 再現済み
- 確認: c38ddf4f1(2026-11-26)
- 属性: 木に材料なし
- 運用: 要注意 — 覆いを開いたまま裏の行を検証しない(先に閉じる)
- 優先度: 中 — 既定の経路の誤った成功(注記なし)

出典: 探索的テスト(2026-11-25・3周×7担当・`_work/explore-20261125/findings-r<周>-<担当>.md`)
- 観測: E2EY-Flutter の Android「引き伸ばせるシート」(sheet=half)で、裏の `#row_main_10` への `tap` がシートの行 `#queue_row_01` に当たって ✅(DSL 1/1・MCP 2/2×3担当)。注記は `occluder-naming-suppressed` だけで覆いの警告は無い。同じ画面の View・RN は「was not touched: its centre is covered by #queue_row_01」で断る。裏の行への `exist` / `textIs` も 12/12 注記なしの ✅(RN は `covered-by-front-element` 付き・View は赤)
- 原因(観測済み): 画面の 30 要素は全部 `renderer=virtual`・`renderHost=3`・`inOverlayWindow` なし。`OccluderNaming.mayName` の申告の枝(両方 virtual・同じ土台)で名指しを抑えた(DR-230)。**この画面では葉の行どうしの z の向きが実際の塗り順と一致していた**(対象 z=45 < シートの行 z=57)が、E2EX-Flutter の FAB の画面(DR-230 の元になった誤りの名指し)では逆だった = Flutter の木の z は画面によって合う・合わないがあり、木からは見分けられない。検証の注記の段(`stageCoveredByFront`)は `paintOrderIsReal` が前提で、Android の Flutter では素通り(DR-230 より前から)。Flutter のダイアログ・メニュー・ボトムシートは裏を木から外すので、この形は木に残る常駐シートだけ
- 処理(2026-11-25・要判断をおすすめの案で): tap の側は、名指しを止めた出口でも相手を名指さない注意を出すようにした(DR-230。DSL の緑の tap の注記 `TapTargetGeometry.unnamedCoverCaution`・失敗後の案内・MCP の注記)。残るのは検証の側: `stageCoveredByFront` は塗り順のある木が前提で、Android の Flutter の木は塗り順かどうかを見分けられない(木に材料なし)
- 測定(2026-11-25 夜・手元 Emu -01・E2EY-Flutter の Android・半分のシート): 裏の `#row_main_10` への `exist` は可視性検証の所要が 0ms(ボタンは V9 の足切りで画素を読まない = 検証の段に材料が届いていなかった)。**木の外の材料(画素)で手前を決められる**: 端末のスクリーンショットの `#row_main_10` の枠(1280×168)を OCR で読むと「キュー02」(重なるシートの行 `#queue_row_02` のラベル)、覆われていない `#row_main_06` の枠は「本文 06」(自分のラベル)
- 処理(2026-11-25 夜): 塗り順の分からない木では、検証の V3 で「対象の中心に重なるラベル付きの別の要素(祖先・子孫は除く)があれば、対象の枠を OCR で1回読み、自分の文字が読めず重なる要素のラベルが読めたら注記 `covered-by-front-element-read-on-screen`」を足した(**新しい検知なので警告から** = 合否は変えない。OCR の段が無効なら撃たない。どちらのラベルも読めなければ何も言わない)。同じ画面で注記が付くことを確認(ステップの説明にも文が出る)。**既存の資産の全数での誤検知の確かめは次の回帰で行う**(対象は塗り順の分からない木 = CMP・Flutter・SwiftUI の全 SUT)
- 確かめ(2026-11-26・b1b4e83 + 作業ツリー・手元 Emu -01): 同じ手順(半分のシート → 裏の `#row_main_10` へ `exist` と `tap`)を `fleetest run-file` で1本回し、`exist` に「描かれている文字は重なる別の要素のもの」の注記、`tap` に覆いの注意が出た = 記述どおり。残りは回帰での全数の確かめのまま
- 検証の所要(11/26): 台帳の読み 約5分 + 一時シナリオを書いて `run-file` で1本 約3分(実行 37 秒。`android` のプロファイルは4台の機械にまたがるが、1本なら手元の1台だけで回る)
- 材料の見直し(2026-11-26・コードと API の読み、デバイス未測定): 材料(画素の OCR)は入っている。残りは全体の回帰での誤検知の確かめだけ
- 全体の回帰(2026-11-26 夕・489cb16・4 台・24 対象・1,189 本・全部緑。iOS は inapp-boost と Android): 注記 `covered-by-front-element-read-on-screen` は 0 件 = 塗り順の分からない全 SUT での誤検知の確かめが済んだ。警告を赤へ上げるかはユーザーの決定待ち
- xcuitest モードの全体の回帰(2026-11-26 夕・652aa2c・594 本): 注記は 1 件だけ、緑のシナリオ(E2EX-RN のナビゲーション S0010)で、詳細画面の「次へ」の遷移の直後の `select "#txt_detail_id"` に付いた(次の `textIs` には `stale-frame-text-visible` = 切り替え途中の古い絵を読んだ一時の形)。**赤へ上げるなら、絵が古いかの判定(`StaleFrameDetector`)と組んで、古い絵では言わない形にしてから**(このまま上げるとこの緑が赤になる)
- 処理(2026-11-26 夜・DR-235): Android の Flutter の debug / profile のビルドでは、アプリの VM サービスの塗り順(Android ブリッジ v154 の `POST /semanticsorder`)で手前を決めて、tap の注記と赤の案内が覆いを名指す。同じ手順の陽性対照(`E2EY-Flutter/scenarios/_disabled/91_半分のシートの裏の行の名指し.swift`)で、裏の `#row_main_10` への tap に「covered by #queue_row_02」、後続の赤に同じ名指しが出た(手元 Emu・1本)。MCP の `ft_tap` も同じ画面で「#queue_row_02 is drawn over the center of #row_main_10」と名指す(新しいプロセスで確かめた)。release のビルドは今のまま
- 処理(2026-11-26 夜・DR-235): 検証の側も、Android の debug / profile のビルドでは塗り順の答えで覆いが手前なら注記 `covered-by-front-element-from-semantics`(合否は変えない。ラベルの無い覆いでも言える)。一時シナリオで、裏の `#row_main_10` への `exist` にだけ付き、覆われていない `#row_main_06`・シートの行 `#queue_row_02` には付かないことを確かめた。Flutter の Android の3スイート 135 本で発火 0。残りは release のビルド(OCR の注記だけ)と、警告を赤へ上げるかの判断
- 2026-11-26(ユーザー決定「おすすめで」): 赤へは上げない。xcuitest の回帰の1件は、その回に古い絵の印(`stale-screenshot`)が立っていなかった = 既存の古い絵の判定では消せない形。上げるなら、遷移の途中の絵をその場で古いと言える材料を先に測る

### OI-327 XCUITest の木で容器が全画面に申告され、スクロール容器の下端で切られたボタンへの `tap(scroll: .down)` が払わずに押して飲まれる
- 状態: 再現済み
- 確認: 7521d189b(2026-11-21)
- 属性: 木に材料なし
- 運用: 回避可 — 押す前に `scrollTo` で容器を送る(inapp-boost は押せる)
- 優先度: 中 — 作成時(MCP = XCUITest)の判断を誤らせる。本番の既定(inapp-boost)は押せる

出典: シナリオ作成の評価 5回目(2026-11-21・`_work/scen-eval-20261121/`。作成 80 セッション・406 本・本番 116 回・延べ 633 本・緑 598。一覧は同フォルダの `ISSUES.md`・各セッションの所見は `ws/TestProjects/<proj>/EVAL_REPORT.md`・本番のログは `logs/run-*.log`)
- 観測(本番 9 回): SUT Store iOS の登録直後のアカウント画面で `exist("#btn_logout")` が `text visibility check failed (on screen): present in the tree but not visually visible [notRendered] no legible text is drawn in the element's area`(sutstore_ios 3・r2_sutstore_ios 3・hk_sutstore_ios 3。M1Ultra と手元 Sim -08)。失敗時の木: `other scroll (0,188 402x538)`(下端 726)・`button "ログアウト" id=btn_logout (16,717 370x43)`・`staticText "ログアウト" (166,728 70x24)`。スクリーンショットはカードの上端だけで文字が無い = **検証は真陽性**(文字は容器の枠の外)
- 作成時(XCUITest・検証なし): `exist` は緑。hk_sutstore_ios の住所フォームの `#btn_save`(下の staticText の高さ 4pt)は `tap` が飲まれて次の検証で赤、`tap("#btn_save", scroll: .down)` も効かず `swipe(.up)` で回避(AI の記述「既に画面内と判定され scroll が発火しない」)
- 推測: ①文言が「容器に切られている・送れば出る」を言わないのは、遮蔽の判定が祖先の容器の枠を見ていない ②`scroll:` が「画面内」を画面の枠だけで判定し、祖先の容器の枠で切られた要素を到達済みと扱う
- 次の一手: 同じ画面で ①in-app と XCUITest の木で `#btn_logout` の祖先にその scroll 容器が居るか ②`tap(scroll: .down)` が払うかどうか(ログ)③遮蔽の判定がどの段で notRendered を出したか、を測る
- **測定(11/21 06:5x・手元 Sim -05・SUT Store iOS・`_work/scen-eval-20261121/logs/m327-*.log`)**: 登録直後のアカウント画面の in-app の木(`fleetest snapshot --json`)で、スクロール容器 `other scrollable (0,188 402x538)` は depth 8、`#btn_logout (16,717 370x43)` は depth 10、ラベルの `staticText "ログアウト" (166,728.7 70x24)` は depth 11 = 容器の子孫で、ラベルは容器の下端 726 の完全に外。`tap("#btn_logout", scroll: .down)` は inapp-boost・xcuitest とも払わずに押せてログアウトした(押す側は問題なし)
- 原因(①・観測): 可視性検証の赤は真陽性。赤の文言(`stageFMRed`)は木から言える「容器の枠の外にある」を足さない
- **測定 ②(11/21 07:1x・同じ Sim・住所フォーム・`logs/m327b-*.log`)**: キーボードを閉じた後の `exist("#btn_save")` は両モードとも可視性検証の notRendered で赤(in-app の木: 容器 `other scroll (0,188 402x618)` = 下端 806・`#btn_save (16,789 370x48)` の中心 813 は外・ラベルは高さ 4pt / XCUITest の木: 容器は `scrollView (0,0 402x874)` で全画面・ラベル `staticText "保存" (187,801 28x4)`)。`tap("#btn_save", scroll: .down)` は **xcuitest は払わずに押して ✅、保存されずに次の検証で赤(1/1)**、inapp-boost は保存できた(1/1)
- 原因 ②(観測): XCUITest の木では容器が全画面に申告され、ボタンは画面の中に見える。切られている材料はラベルの高さ(4pt)だけ = `scroll:` は到達済みと判断して中心(容器の外)を押す
- ①(可視性検証の赤が「容器に切られている」を言わない)は直した(赤に「要素の中心が属するスクロール容器の枠の外 = scrollTo で送ってから確かめる」の事実を足した。判定は変えない。11/21 に同じ画面で文言を確認)
- 同じ材料の別の影響(11/22 に測定・Sim -06・E2E-CMP の入力画面で複数行の欄に打った直後): XCUITest の木は CMP の全画面の容器 `scrollView (0,0 402x874)` が下端まで残るので、キーボードで窓が縮んだ判定(`KeyboardOcclusion.windowResizedAboveKeyboard`)も立たない(in-app の木は最下端 538 = キーボードの上端で立つ)。DSL の not found の文言は `KeyboardWait.isShown` で「縮む作りなら消えうる・先に hideKeyboard()」を添えるようにした(判定は変えていない)
- 次の一手(②): XCUITest の木で「ラベルが要素に比べて極端に切られている」を到達の判定に入れるかは、既存の SUT と実アプリのコーパスで反例を見分けられるか確かめてから(MN-108)
- 評価 6回目(11/21・`_work/scen-eval-20261121b/`): hk_sutstore_ios の本番 M1Ultra 0/4(登録直後の `exist "#btn_logout"`・赤の文言は「容器の外」を言う = ①の直しが効いた)・作成時の `#btn_save` の飲まれ(hk_sutstore_ios・r8_order_ios)。e2ey_rn_ios で入れ子のリストの下端のカードへの `tap(scroll: .down)` も同じ形で飲まれた
- 評価 7回目(11/22・`_work/scen-eval-20261122/`): hk_sutstore_ios の本番 M1Ultra 1 本(赤の文言は「容器の枠の外」を名指し = 正しい赤)・作成時の `#btn_save` の飲まれ 2 セッション
- 測定(2026-11-25・手元 Sim・E2E-CMP の入力画面を xcuitest モードで1本・XCUITest ランナーに一時的な記録を足して測った): XCTest のスナップショットの `visibleFrame` は取れるが、CMP の全画面の容器 `scrollView (0,0 402x874)` には枠と同じ全画面を返す(217/217)。枠と違ったのはキーボードの窓の中・画面の縁で切れたノードだけ = 容器の窓を言う材料にならない
- 材料の候補の測定(2026-11-25 夜・固定の実アプリのコーパス 55 画面): 押せる要素(button・link・cell・clickable。高さ 20 以上)の中に収まる文字の子で、高さが床(`TapTargetGeometry.minimumVisibleTapExtent` = 8 pt × 密度。DR-231 と同じ床)未満のものは **0 件** = 「子の文字の枠だけが床より細く切られている」は実アプリの普通の画面では出ない(反例なし)。正例(縁で切れたボタン = SUT Store の住所の保存・高さ 4pt)もコーパスには無い。次の一手: この形を `tap(scroll:)` の到達の判定(XCUITest の木)に足す前に、正例が出る SUT の画面(xcuitest モード)と、文字の小さいボタンの反例を同じ材料で見分けられるかをデバイスで確かめる
- 正例を探した(2026-11-26・手元 Sim -08・XCUITest の木): E2EY-RN の入れ子の一覧の下端のカード(評価で `tap(scroll: .down)` が吸われた形)は、XCUITest の木でも容器 `list_nested` の枠が正しく(下端 858)、カード(下端 921)が容器の外へはみ出すと木から言える = 「子の文字の枠だけが細い」形ではない。E2EY-CMP の同じ画面は容器の枠が正しく、外のカードは木から落ちる。自前の SUT(E2E・E2EX・E2EY の CMP)に、全画面の容器の下端でボタンが半分切れる画面は無い = 正例は外部の SUT Store の住所のフォームだけ。判定に足すのは、正例の画面を自前の SUT に足すか、SUT Store で測ってから
- 再現(2026-11-26・b1b4e83 + 作業ツリー・手元 Sim・xcuitest モード): 登録 → 住所を入れて閉じる → `tap("#btn_save", scroll: .down)` を `fleetest run-file` で回し、同じ形(容器 `scrollView (0,0 402x874)`・`button "保存" (16,789 370x48)`・中の `staticText "保存" (187,801 28x4)`)で注記なしの ✅・保存されず次の検証で赤 = 記述どおり
- 処理(2026-11-26・**警告から**): 中の文字の子だけが床(`minimumVisibleTapExtent`)より薄い押せる要素に、容器の縁が木に無いまま切られている疑いの警告を足した(`TapTargetGeometry.collapsedLabelInside` → 警告の連鎖の `collapsedLabel`。DSL と MCP が共有・Android は「たぶん押せている」の弱い文言)。実アプリのコーパスの発火は1件(Android の画面の最下端で切れた行 = 真陽性)。同じ画面で tap の ✅ に警告が出ることを確認。**払う・寄せる(合否や動きを変える)のはまだ** —— 回帰と作成の評価で誤検知が出ないことを見てから
- 検証の所要(11/26): 一時シナリオを書いて `run-file` で4回(書き方の誤りの直しを含む)約25分 + 警告の実装・コーパス・変異 約30分 + デバイスでの確認 約5分。`run-file` は `--scenario` を付けないとプロファイルの全台を起動する(本数が分からないので絞らない。今回は5台)
- 材料の見直し(2026-11-26・コードと API の読み、デバイス未測定): 材料(中の文字の子だけが薄い)は 11/26 に警告として入れた。送ってから押す動きに上げる前に、送った後に文字の枠が伸びるか(画面の反応)で確かめる形が候補
- 全体の回帰(2026-11-26 夕・489cb16・4 台・24 対象・1,189 本・全部緑。iOS は inapp-boost と Android): 11/26 に足した中の文字が潰れた警告は1件だけ = E2EX-CMP の Android の貼り付く見出しの下で本当に切られた行(高さ 50px・ふだん 168px・文字の子 2px)で、Android の弱い文言どおりタップは効いた(真陽性)

### OI-279 CMP の iOS で、要素の中心への XCUITest のタップが効かず、作成時に誤った欠陥の起票・座標のシナリオを生む
- 状態: 再現済み
- 確認: 657e032d1(2026-11-19)
- 属性: 木に材料なし
- 運用: 回避可 — 本番(inapp-boost)では効く。作成時は ft_start_run で確かめる(DR-196)
- 優先度: 中 — 作成ループで誤った判断を招く

出典: シナリオ作成の評価 2回目(2026-11-18・`_work/scen-eval-20261118b/`。一覧は同フォルダの `ISSUES.md`・各セッションの所見は `ws/TestProjects/<proj>/EVAL_REPORT.md`)
- 観測: ①spec_ios のホームの検索バー(textView「商品を検索」)を XCUITest で押しても遷移しない(セレクタ2回・座標1回)→ AI は仕様違反 D-01 を起票して赤のまま残した → 本番(inapp-boost)では S0013 を含む 6/6 緑 ②r2_sutstore_ios の住所フォームの「保存」`#btn_save`(木では (16,789 370x48)・整定済み)へのセレクタの tap(中心)が3回とも無反応、上端寄りの座標 `tap(x:201, y:795)` なら保存できた → AI は座標で書いた。staticText「保存」の高さが 4pt
- 対照: 同じ評価で XCUITest のカートの数量±の起票(r4_spec_ios)は本番でも再現 = アプリ側
- 測定(11/18 23:1x・Sim -05・MCP = XCUITest): SUT Store のホームの検索バー(`textView "商品を検索" (16,112 370x56)`)へ ①セレクタの tap(中心)②座標 (201,117)(上端寄り)③0.3 秒の長押し、のどれも遷移しない(木は操作の前と同じ)。同じ画面の本番(inapp-boost)は遷移する = XCUITest の合成の入力が、押す位置・時間によらずこの CMP の欄に効かない。保存ボタンで上端なら効いた形とは別
- 測定(11/19 1:0x・Sim -05・ランナーの /hittable を直接): 検索バーの `textView "商品を検索"` は `hittable: true`(label で引き当て)。それでも要素の tap・座標の tap・0.3 秒の長押しのどれも効かない = 届かない理由は木にもヒットテストの答えにも出ない
- 3回目の評価(11/19・`_work/scen-eval-20261119/`): ①spec_ios で同じ検索バーに同じ仕様違反 D-01 が起票され、本番(inapp-boost)では同じシナリオが緑(3回目)②の保存ボタンを 3 つの AI が踏んだ: r2_sutstore_ios は失敗時の木で文字が `staticText "保存" (187,801 28x4)` = **高さ 4pt に切り詰め**・スクリーンショットでも最下端で見切れ(scrollToBottom → pressEnter → tap の回り道で緑)、r6_sutstore_ios は断念、r7_sutstore_ios は XCUITest で 4 回以上無反応のまま赤で残した。**同じ r7 のシナリオを本番(inapp-boost・M1Ultra)で回すと `tap("#btn_save")` が「nudged the element fully inside its container before touching it」で保存できた** = ②は「容器の縁で切れた要素の中心を押す」形で、inapp-boost の DSL は容器の内側へ寄せてから押すが、XCUITest の作成ループ(MCP・ft_run_scenario)では寄せが働いていない
- 測定(11/19・評価のセッションのログ = MCP の XCUITest の木): 住所フォームの木は `scrollView scroll (0,0 402x874)`(画面全体)と `button "保存" id=btn_save (16,797 370x48)` = **XCUITest の木では保存ボタンが容器の中に収まって見え、「縁にまたがる」の判定(寄せ)の材料が無い**。切られている痕跡は子の文字の枠(`staticText "保存" (187,801 28x4)`)の高さだけ。inapp-boost の木は縁をまたいで見えるので寄せてから押せた
- 次の一手: ②は子の文字の枠が親より大きく切られている形を「見えている部分」の材料にできるか(反例 = 文字が小さいだけのボタン を同じ材料で見分けられるか)を固定コーパスで確かめる。①は材料が出るまで据え置き(XCUITest の合成のタッチを CMP の欄が受け取らない理由をブリッジの側で測る口が要る)
- 4回目の評価(11/19・`_work/scen-eval-20261119b/`): r8_order_ios・r7_sutstore_ios の住所の保存 `tap("#btn_save")` が XCUITest の作成ループで効かず(ボタン `(16,789 370x48)`・子の文字 `staticText "保存" (187,801 28x4)` = 高さ 4pt に切り詰め = 同じ材料)、AI は「サーバーの不具合」と誤って帰属させた(根拠の health 確認は実行されていない)。本番(inapp-boost)では同じ 3 本が 3 回とも緑
- 材料の候補の測定(2026-11-25 夜・固定の実アプリのコーパス 55 画面): 押せる要素(button・link・cell・clickable。高さ 20 以上)の中に収まる文字の子で、高さが床(`TapTargetGeometry.minimumVisibleTapExtent` = 8 pt × 密度。DR-231 と同じ床)未満のものは **0 件** = 「子の文字の枠だけが床より細く切られている」は実アプリの普通の画面では出ない(反例なし)。正例(縁で切れたボタン = SUT Store の住所の保存・高さ 4pt)もコーパスには無い。次の一手: この形を 中心を押す前の寄せ(XCUITest の木の「縁にまたがる」の判定)に足す前に、正例が出る SUT の画面(xcuitest モード)と、文字の小さいボタンの反例を同じ材料で見分けられるかをデバイスで確かめる
- 正例を探した(2026-11-26・手元 Sim -08・XCUITest の木): E2EY-RN の入れ子の一覧の下端のカード(評価で `tap(scroll: .down)` が吸われた形)は、XCUITest の木でも容器 `list_nested` の枠が正しく(下端 858)、カード(下端 921)が容器の外へはみ出すと木から言える = 「子の文字の枠だけが細い」形ではない。E2EY-CMP の同じ画面は容器の枠が正しく、外のカードは木から落ちる。自前の SUT(E2E・E2EX・E2EY の CMP)に、全画面の容器の下端でボタンが半分切れる画面は無い = 正例は外部の SUT Store の住所のフォームだけ。判定に足すのは、正例の画面を自前の SUT に足すか、SUT Store で測ってから
- 2026-11-26: ②は OI-327 と同じ材料で、タップに警告が付くようにした(`collapsedLabel`。動きは変えない)。①(検索バー)は材料なしのまま
- 検証の所要(11/26): OI-327 と同じ回(②の再現と警告の確認)。①は試していない
- 材料の見直し(2026-11-26・コードと API の読み、デバイス未測定): ②は OI-327 と同じ材料で警告を足した(11/26)。①は in-app ブリッジで UIEvent の届き先を記録する計測の部品を足せば、XCUITest の合成タッチがどこで落ちるかを測れる(未着手)

### OI-238 Flutter の iOS で、back() の縁の払いが戻らないのに、注記付きの ✅ を返す(どの画面でも。inapp-boost 42/42・xcuitest 12/12)
- 状態: 再現済み
- 確認: 57周目(2026-11-16)
- 属性: 木に材料なし
- 運用: 回避可 — `tap("#btn_back")` で戻る(既存の 01_ナビゲーション の書き方)
- 優先度: 低 — 注記が「効かなかったかもしれない」と言い、後続の検証で赤になる

出典: 56周目 iultra F2(E2EY-Flutter の入れ子スクロール)。57周目 iultra が測った(M1Ultra の iPhone 18 Pro 6台)
- 観測: 入れ子スクロールの画面に限らない。送らずに back()・カードを押してから・縦に送ってから・横の棚の無い反転チャットの4条件がどれも 0/6、E2EX-Flutter のページャも 0/6、xcuitest モードも 0/12。in-app ブリッジは back() を持たないので、どちらのモードも XCUITest ブリッジの縁の払い(左端 +1pt から画面幅の 65% まで・0.05 秒押して 0.25 秒で引く。BridgeClient.swift の back の drag)に落ちる。対照: 同じ6台の E2EY-iOS(SwiftUI)は同じ4条件で 24/24 戻る・Flutter でも `tap("#btn_back")` は 6/6 戻る・押さずに速く払う `flickLeftToRight(startMarginRatio: 0.0)` は Flutter 0/6・SwiftUI 5/6。= 左端からの合成の払いを Flutter の iOS が戻る払いとして受け取らない。E2EX-Flutter の 01_ナビゲーション のコメントにも同じ記録(始点 x=1〜19・0.25〜0.8 秒のどれでも戻らない)
- 材料不足: Flutter 側が合成の払いを受け取らない理由(始点・速度・認識器)。✅ を赤にする直しは取らない —— 「木が同じ = 効かなかった」の読みは Compose の Android で a11y のキャッシュが前の画面の木を返して外れていた(11/16 に直した)。外れうる読みを根拠に赤にすると誤った赤を作る
- 測った(11/16・失敗時の木と実アプリ固定コーパスの全数): back() が押すのは木の `id == "BackButton"` のボタンだけで、それが無い Flutter・CMP・RN(JS の stack)・E2E-iOS の戻るボタンは縁の払いに落ちる。Flutter の iOS の戻るボタンを木で見分ける材料はラベルの語(アプリの tooltip「戻る」・Material の既定の「Back」)とアプリが付けた id だけで、木の要素に特性(traits)の欄は無い。型・寸法・位置は左上の「閉じる」「共有」のアイコンボタン(コーパスの地図の `CardButtonTypeClose`・E2EX-Flutter の全画面ダイアログの leading の閉じる)と同じ形 = 語の一致で拾うと取り違える(DR-3)。57周目の対照「E2EY-iOS は 24/24 戻る」は `BackButton` を押す経路で、縁の払い同士の対照ではなかった
- 測った(2026-11-25・手元 Sim・xcuitest モード・XCUITest ランナーに一時的な記録を足して特性(traits)を記録): SwiftUI の本物の戻るボタン(`UIAccessibilityBackButtonElement`)は `8724152321`、E2EY-Flutter の `#btn_back`(`FlutterSemanticsObject`)と E2EY-CMP の `#btn_back` は `8589934593` = 差の `1<<27` が戻るの特性で、**Flutter(と CMP)の戻るボタンはそれを立てない**。XCUITest ランナーが特性を申告しても Flutter の戻るボタンは見分けられない
- 次の一手: 直さない(木にも特性にも材料が無い)。Flutter が戻るの特性を立てるようになったら見直す
- 測った(2026-11-25・M1Ultra の Sim・inapp-boost・E2EY-Flutter に足した左端の帯で始まるポインタ列の記録 `#txt_touch_trace`・2回とも同じ値): `back()` の縁の払いは Flutter に届いている —— `trace=d1.0,437.0 m14 f100 l261.3,437.0 u316 g0`(DOWN x=1.0・MOVE 14本・最初の MOVE は DOWN の 100ms 後・最後 x=261.3・UP 316ms・その間と UP の 400ms 後まで Navigator の `userGestureInProgress` は一度も立たない)。= ポインタが届かないのではなく、戻るのジェスチャが始まらない。始まらない理由(その画面の遷移が縁の払いで戻る形か・押さえの 100ms か)は未測定。記録は SUT に残してある(後に木から外し、端末の統合ログの `ft-touch-trace:` へ出す形にした = 木の文字が変わると back() が効いたかの判定が「効いた」に倒れるため。E2EYAppCMP/docs/ui-contract.md)
- 棚卸し(2026-11-25 夜): 新しい材料なし(SUT の自己申告で、縁の払いは Flutter に届いているのに戻るのジェスチャが始まらないことまでは測ってある。直さない)
- 材料の見直し(2026-11-26・コードと API の読み、デバイス未測定): SUT の記録(`ft-touch-trace`)に戻る操作の可否(Flutter の ModalRoute.popGestureEnabled)と遷移の作りを足して測れば、戻らない理由が分かる。戻ったかの確かめは木だけでなく画面の絵の差で見る案(M1Ultra での測定が要る)

### OI-245 iOS の hideKeyboard が背景のタップで閉じられない複数行の欄では、続けて送る Enter が欄に改行を入れて値を変え、それでも閉じずに赤(E2EY-CMP の iOS の `#field_title`・6/6)
- 状態: 再現済み
- 確認: 2026-11-16
- 属性: 木に材料なし
- 運用: 要注意 — 欄の値が変わる(hideKeyboard を繰り返すたびに改行が増える)。失敗文は「Enter の後に欄の値が変わった」と事実を言う。複数行の欄では hideKeyboard を使わず、アプリの閉じるボタンを押す
- 優先度: 中 — 赤になるが、テスト対象の画面の状態を変えてしまう

出典: 59周目 iultra F1(M1Ultra の iPhone 18 Pro 6台・inapp-boost)。同じ画面の SwiftUI と Flutter の単一行の欄は背景のタップで閉じず Enter で閉じて ✅
- 経緯: 「焦点の欄の型が `textView` なら Enter を送らない」で直した(DR-185・0.22.1)が、iOS の Compose Multiplatform は1行の欄も `textView` で出すため、背景のタップで閉じず Enter で閉じる1行の欄(sut-ec-mobile の住所フォーム)で hideKeyboard が失敗する退行になり、取り消した
- 材料が無いこと: 木の型では1行と複数行を見分けられない(E2E-CMP の iOS の `#field_single`(singleLine)も `textView`)。枠の高さ・ラベルで決める形は推測になるので取らない
- 測った(11/16・E2E-CMP の iOS の `#field_single`・`#field_password`・`#field_multiline`): 型は XCUITest の木(MCP)でも in-app の木でも3つとも `textView`。焦点を持つ実体は3つとも Compose の `OverlayInputView` で、入力の特性(`UITextInputTraits` = リターンキーの種類・キーボードの種類)を持たない(in-app ブリッジに一時的に足した診断で確認)。打った文字を受ける UIKit の部品も無い = UIKit の側からは1行か複数行かを読めない
- 測った(2026-11-25・手元 Sim・xcuitest モード・XCUITest ランナーに一時的な記録を足して、木の要素の本当のクラス名・基の型・特性(traits)・追加の属性の全部を記録): E2E-CMP の `#field_single`・`#field_password`・`#field_multiline` と E2EY-CMP の `#field_title` は全部 `AccessibilityElement`(基は `UIAccessibilityElement`)で、特性の値も同じ(焦点の有無で2つの値を行き来するだけ)。E2E-Flutter の `#field_single`・`#field_multiline` も同じく `TextInputSemanticsObject`・同じ特性の値(パスワードだけ型 50)。追加の属性は 5004 のクラス名だけ = XCUITest の側にも1行か複数行かの材料は無い
- 次の一手: 直さない(in-app・XCUITest のどちらの側にも材料が無い)。Compose / Flutter が1行か複数行かを申告するようになったら見直す
- 探索 2026-11-25(`_work/explore-20261125/findings-r1-im4.md`・`findings-r2-im4.md`): 同じ形が他の SUT の複数行の欄にもある(E2E-iOS・E2E-Flutter・E2EX-iOS・E2EX-Flutter の `#field_multiline`。E2E-Flutter は 5/5)。E2EX-CMP の数字・パスワードの欄の赤は、SUT がこの2欄に `singleLine = true` を付けていない = Compose では複数行の欄(Enter が改行を入れる)で、欄の種類のせいではない(SUT 側。ui-contract-wave2.md:87-89 は複数行と書いていない)。E2E-CMP が緑なのは InputScreen.kt:54 が背景のタップで `clearFocus` するため。手の順は `executeIOSHideKeyboard`(StepExecutor+DirectActions.swift:966)・`closeKeyboardByTappingOutside`(:1130)で、Done を探して無かったことは文にも結果にも残らない。CMP と Flutter の木は焦点(`focused`)を出さないので、Enter が欄に改行を入れて値が変わっても失敗文に「値が変わった」が付かない(SwiftUI は付く。`focusedValueChanged` :1112)
- 棚卸し(2026-11-25 夜): 新しい材料なし(Compose・Flutter は1行か複数行かを申告しない。直さない)
- 材料の測定(2026-11-26・手元 Sim・xcuitest モード・スクリーンショット): キーボードの改行キーの表示は欄の動作を写すだけ。CMP の `#field_single`(検索の動作)= 🔍、`#field_password`(1行・動作なし)と `#field_multiline` = どちらも ↵。Flutter も `#field_single` = 🔍・`#field_multiline` = ↵(パスワードはキーボードが絵に写らない)。XCUITest ランナーは木からキーボードのキーを外す(`BridgeRouter+Snapshot.swift:173`)。→ 動作の無い1行の欄と複数行の欄を見分けられない = 材料なしのまま
- 検証の所要(11/26): 約6分

### OI-163 キーボードの下の欄への clearInput の時間切れ・タブの下の行への tap・上端の一覧の scroll: が引っ張って更新を走らせるほか
- 状態: 再現済み
- 確認: 4605aa35(2026-11-03)
- 属性: 木に材料なし・低頻度
- 運用: ①再実行で吸収 — 残るのは撃たずに断り続けて時間切れの赤(xcuitest 経路で 8 回中 1〜2 回・壊さない)。先に `hideKeyboard()` で閉じれば出ない ④回避可 — 既定の inapp-boost モードの DSL では出ない(xcuitest モードと MCP だけ) ⑥要注意 — 押されずに ok・後続で赤 ⑩回避可 — 上端に居ると分かっている一覧への読むだけの `select` / `notExist` には `scroll:` を書かない(書くと端の確かめの払いで更新が走り、続く検証が赤) ⑫再実行で吸収(run の制御) ⑯⑱合否に響かない(文言)
- 優先度: 中 — ⑥押されずに ok(後続で赤。11/7 は 0/6)

出典: `_work/explore-20261103c/findings-*.md`(8周目・11/3)。**重いもの**: ①iOS の CMP で、キーボードの下に隠れた欄への clearInput が、焦点のある別の欄を書き換える形(kbd F3)は 11/3 の直しで 16 回中 0 回。残るのは撃たずに断り続けて時間切れの赤(xcuitest 経路で 8 回中 1〜2 回・壊さない。11/7 は 0/12)④iOS の CMP の xcuitest モードと MCP で、タブの下に潜った行への tap がメディアのタブを押す(cover F4。試して取り消した直し: 「木の順で奥の操作できる要素が中心を含み、ヒットテストが当たらないと断言したら覆いとして送る」= E2EY-CMP の xcuitest で 8/8 赤のまま。送った後の木では行がタブから外れて見えるのに撃つとタブに当たる = 木の行の位置が描かれた位置とずれている疑い)。**その他**: ⑥Android の RN でタブの下の行を送って外してから押す tap が飲まれて ok(cover F3・慣性の疑い。11/7 は 0/6)⑩Android で上端に居る一覧への `select` / `notExist` の `scroll: .up` が、端を確かめる払いで「引っ張って更新」を走らせる(scroll F1・Android の 4 SUT で 14/14。続く `textIs` が `refresh=2` で赤)⑫決定的に赤のシナリオだけで健全な端末が離脱する(run F1。別のデバイスでも落ちたシナリオの赤は数えない = `ScenarioFailureWitnesses`。各シナリオを1回ずつ回す初回の run で赤が多いと離脱する形が残る = 区別の材料が無い)⑯アプリが欄を空にした後の type に「the field already held」の事実と違う注記(kbd F4。11/7 は 0/7)⑱Flutter の iOS の secure 欄の後の hideKeyboard が「still shown」(land F4。11/7 は 0/10)
- ③は OI-170 へ(塗り順の無い木では中心を撃ち、後続の赤の文で直し方を言う = 11/5 の決定)
- 11/7: ④の XCUITest の木のタブの枠の高さの揺れ(24/42/48)は送った位置で決まる(同じ静止画面は同じ高さ)。タブの下端は最初の行の上端と一致し、描かれたタブは 48pt = 木に材料なし
- 11/7: ⑩上端の一覧(4 SUT)は子の行の preorder が y 昇順。RN の反転チャットは y 降順で申告が上下鏡映、CMP の reverseLayout も y 降順だが申告は正しい = 木の材料で鏡映と正しいを分けられない。試して取り消した直し: 申告だけで端と確定する(E2EY-RN の Android で過去の行を1本も払わずに赤 2/2)
- 棚卸し(2026-11-25 夜): 新しい材料なし(小項目ごとの材料は従来の記載のとおり)
- 材料の見直し(2026-11-26・コードと API の読み、デバイス未測定): ④(CMP の xcuitest の木の行の位置のずれ)は重なりの無い所でも対象の枠を OCR で読むしかなく、押す前の OCR を絞った決定(11/10・DR-233)を変えることになる。⑩は Android のブリッジが別プロセスで `canScrollVertically` を呼べない = 材料なし

### OI-161 横向きの低い一覧で maxSwipes が足りない・Flutter のはみ出した欄の帯を押しても当たらない・覆いが押せない型のときの警告
- 状態: 再現済み
- 確認: コミット未記録(2026-11-03)
- 属性: 木に材料なし・低頻度・据え置き
- 運用: ①回避可 — `maxSwipes:` を上げる ⑧要注意 — 何も起きずに ok・後続で赤 ⑪合否に響かない(警告だけ)
- 優先度: 中 — ⑧何も起きずに ok・他は回避可か文言

出典: `_work/explore-20261103b/findings-*.md`(7周目・11/3)。①横向きの低い一覧で1回の送りが行の高さを下回り既定の maxSwipes で届かない(ascroll F1)⑧Flutter の横向きで Column からはみ出した欄の、木の上では覆われていない帯(タブの上の 32px)を押しても何にも当たらない(親の箱の外の子へ Flutter のヒットテストが届かない)= 覆われた対象の見えている部分を押す tap は注記付きの ok のまま何も起きない⑪覆いの最前面がタブの中の文字(押せない型)のときは、見えている部分を押す扱いに入らず従来どおり警告して中心を撃つ(押せる祖先へ持ち上げる案は、祖先の復元が preorder+depth で行・包む祖先・無関係のボタンを拾うので外した)
- 11/4: ①の型の追加の観測: M1Max の Emulator 4 台・横向きで、貼り付く見出し・グリッド・伸縮するヘッダの探索が 12/12 赤(「still moving … raise maxSwipes」。HEAD の対照は無し)
- 11/7: ①払いは容器の高さの 69%(88px)・送り量 ≈ 指の移動 − タッチの遊び 24px・行は 168px で容器より高い = 行が容器より高い低い一覧の形。直すなら払いの長さ
- 11/7: ⑧レンダーツリー(debug ビルドの `debugDumpRenderTree`)で欄は Column の箱の完全に外にあり、a11y の木には出ない(座標で直接撃って 6/6 無反応)
- ③④(払いの始点の形)は OI-58 へ
- 評価 8回目(11/23): 縦向きでも、作成(MCP)では届き本番(inapp-boost)では届かない形が出た。11/23 に `maxSwipes:` を動いた距離で数えるよう直した(容器の長さに満たない払いは動いた割合だけ数える・最大で上限の2倍。`ScrollSearchBudget.weight`)。①の形(1回 88px・容器 218px = 比 0.4 → 0.5 本と数える)では届く距離が2倍になるだけで、60 行の一覧の端には既定の回数で届かない(所見の `maxSwipes: 150` が 75 相当になる見積もり・デバイスでは未確認)= ①は残る
- 棚卸し(2026-11-25 夜): 新しい材料なし
- 材料の見直し(2026-11-26・コードと API の読み、デバイス未測定): ⑪は両ブリッジが本当の親(kept parent)を持っているのに `keptDepth` だけ送っている(`BridgeSnapshotThinning.swift` の keptParents)= 親の ref を送れば材料になる(ワイヤの変更・版上げ)。⑧(Flutter の Column の外の欄)は外から当たり判定を聞く手が無く、押した後に焦点・キーボードが出たかで見るのが材料

### OI-156 iOS のテキストの可視性検証が、SwiftUI・CMP・Flutter のボタンは縁で切れていてもタブバーの下でも読まずに緑にする
- 状態: 再現済み
- 確認: 0a67f89b(2026-11-04)
- 属性: 木に材料なし
- 運用: 回避不可(見逃し) — SwiftUI・CMP・Flutter のボタンがタブバーの下・縁で切れていても、テキストの可視性検証は緑にする。押した後の結果を確かめれば、押せないことは赤にできる
- 優先度: 中 — ボタンの見えにくさの見逃し(回避不可)。押した後の確かめで補える

11/3 の7周目の探索(vis F2・F3)。Android と iOS の行(セル)は直した(`OcclusionEligibility.sameLabelTextDescendant` / `isLabelledRowWithoutText`)。UIKit と RN のボタンは、in-app ブリッジがタイトルとして描いている文字を申告する(`ElementInfo.drawnTitle`・iOS v308)ようにして直した(`OcclusionEligibility.drawsOwnTitle`)
- 残り: SwiftUI・CMP・Flutter のボタンは、描かれない説明文をラベルに持つアイコンのボタンと文字のボタンを木で見分ける材料が無い(描かれた文字を申告できない)
- 関連(2026-11-25 夜): 塗り順の分からない木で、対象の中心に重なるラベル付きの別の要素の文字が対象の枠に描かれていれば注記を付ける検知を足した(`covered-by-front-element-read-on-screen`・OI-387)。タブバーの項目が対象の中心に重なる形はこれで注記が付く見込み(未確認)。縁で切れた形は、文字のボタンかアイコンのボタンかを木からも画素からも決められない(据え置き)
- 材料の見直し(2026-11-26・コードと API の読み、デバイス未測定): SwiftUI・Flutter はボタンの文字が絵として描かれているかを分ける材料が無い。CMP は iOS のアクセシビリティ要素が文字の子を分けて持つかを E2EY-CMP のボタンの画面で記録すれば分かる(未測定)
- 2026-11-26(記述の訂正): CMP の文字のボタンは同じ文字の子(`staticText`)を持つので、11/3 の `sameLabelTextDescendant`(V5)で子の枠を読む = 縁で切れた CMP のボタンは赤になる(実例: 11/26 の sut-ec-mobile の `#btn_save`(xcuitest)・11/22 の `#btn_logout`(inapp-boost)が notRendered の赤)。材料が無いのは文字の子を持たないボタン = SwiftUI・Flutter(11/26 の in-app のダンプで Flutter のボタンは子に文字が無くラベルが自分に畳まれる)と CMP のアイコンのボタン(描かれない説明文 = 読まないのが正しい)
- 検証の所要(11/26): コードと既存の観測の突き合わせ 約5分

## 低頻度

### OI-173 SwiftUI の FAB を容器の外と読む(M1Ultra の負荷の下だけ)
- 状態: 再現済み
- 確認: コミット未記録(2026-11-05)
- 属性: 低頻度・据え置き
- 運用: ③再実行で吸収 — M1Ultra の負荷の下でだけ出ている(①は Android ブリッジ 153 で直した)
- 優先度: 低 — 再実行で吸収

出典: `_work/explore-20261105b/findings-*.md`(14周目・11/5)。①E2EY-RN の Android の A9 で、半分のシートの見出しの帯の下の行への `tap` が ✅ を返すが何も押していない(amax F1・16/16。送りの形「scrolled the container to bring the target out from under #queue_row_00」が 4・送り無しで注記も無い形が 12)。後続の赤は「may have been swallowed」だけで覆いを名指さない。キューの行が覆いのときは撃たずに断る(8/8)。撃った中心を覆うノードは木に無く、シートの面(見出しの帯)が木に載っていない = **木に材料なし**(面が木に無い理由は材料不足)③SwiftUI の iOS で、開いた直後に見えている FAB への素の `tap("#fab_hiding")` を容器の外と扱って一覧を送り、バーと FAB を隠して何も押さずに赤(iultra F2・12回中6回。CMP・Flutter は 6/6 緑)。FAB をどの容器の子と数えたか・台で分かれた理由は材料不足(手元の8台×2周では 16/16 緑 = M1Ultra の負荷の下でだけ出ている)。候補の仕組み: E2EX-iOS の FAB の画面で、開いた直後の `tap("#fab_add")` が push の遷移の途中で滑っている前の画面の一覧 `(-121,0 402x874)` を容器に選んで「容器の外」と読み、救済の遅いドラッグを1本撃つ形を観測(緑・1/1)。外側の一覧の判定(`clippedByOuterScroller`)は画面からはみ出た枠を除くが、容器の外の判定(`isOutsideContainer`)は除かない。赤の回が同じ仕組みかは、M1Ultra で出たときの救済の記録(`[rescue: …]` に容器の枠が出る)で確かめる(直すなら容器推定を触るので 5 SUT のフル E2E と xcuitest)。
- 2026-11-25(③の再確認): M1Ultra の6台へ開いた直後の `tap("#fab_hiding")` → `textIs("hide=fab")` を 3 周(負荷の無い時間)= 18/18 緑。負荷の下でだけ出る形なので消えたとは言えない(11/18 の keptDepth の門 c516bddf6 で容器の外と読まなくなった見込み = 推測)。回帰の負荷の下で出たら救済の記録を見る11/8 の HEAD では M1Ultra の6台×2周で 0/12(救済の経路にも入らない)= 低頻度
- 測る口(2026-11-25): 判定の足跡(`trace`)を足した。①の送りは `keyboard-cover-lift`、③の容器の外の判定は `container-outside`(対象・選んだ容器の枠・外と読んだか・容器が画面からはみ出ていたか)に残る
- 棚卸し(2026-11-25 夜): 判定の足跡(覆いを避ける送り・容器の外の判定)が入った後に M1Ultra の負荷の下の発生が無い = 新しい材料なし
- 材料の見直し(2026-11-26・コードと API の読み、デバイス未測定): ①(RN の Android の半分のシートの帯)は、ブリッジが絞り込む前の生の木(`uiautomator dump`)に描画順つきで帯の面があるかを測れば、残すだけの小さな変更で材料になる(未測定・Emulator が要る)
- ①を直した(2026-11-26・Android ブリッジ 153): ブリッジを止めて採った生の木(`uiautomator dump`)に、RN のボトムシートの面が SeekBar「Bottom Sheet」[0,1638][1280,2784] として載っていた。ブリッジの絞り込み(`SnapshotBuilder.shouldInclude`)が id の無い Slider を落としていた = 名前のある Slider は残すようにした。手元 Emu で、帯の下の `#row_main_08` への tap は「its centre is covered by slider "Bottom Sheet" … close or collapse it first」で撃たずに断り(前は ✅ で何も押さない)、帯の上の `#row_main_05`(反例)は押せて緑。スライダー・ボトムシートを使う Android の 22 本(E2E-RN・E2EX の RN/Android/CMP/Flutter・E2EY-RN)は緑。残りは③(M1Ultra の負荷の下だけ)
- 検証の所要(11/26): 生の木の採取(ブリッジを止める必要があった)約8分 + 直し・APK・テスト 約5分 + 確かめ(一時シナリオ・22 本)約8分

### OI-366 `ft_swipe` の「nothing on the screen moved」が、横の容器で中身が1枚ずれていても出る
- 状態: 再現済み
- 確認: 07d7fc00a(2026-11-23。評価で1回観測・再現の試み 6 回は出ず)
- 属性: 低頻度・要測定
- 運用: 合否に響かない — MCP の注記だけ。端に着いたと読ませる
- 優先度: 低 — 注記・文言だけ

出典: シナリオ作成の評価 9回目(2026-11-23 17:05〜20:30・`_work/scen-eval-20261123b/`。版 07d7fc00a = 0.24.0。作成 86 セッション・本番は手元・M1Max・M1Ultra・M4Max・iPad・Duo・SE3。一覧は同フォルダの `ISSUES.md`・作成の所見の要約は `digest-aa〜ae.md`・観測メモは `findings.md`)
- 観測: e2ey_cmp_3a。`swipe left sent inside id=shelf_5. (nothing on the screen moved after the swipe(s) — the list may already be at its end in this direction)` の同じ応答の木で `card_5_00/01/02` → `card_5_01/02/03/04`
- 測定(11/23 夜): 判定は `scrollFrame:` を書いた払いなら枠の中だけを比べる(`StepExecutor+DirectActions.swift` の `sameContentInSearchRegion`)。Emulator(Pixel 10 Pro・Android 17)の E2EY-CMP の同じ画面で、`#shelf_1` を4回・下端にかかった `#shelf_4` を1回払い、5回とも注記は出なかった(中身は正しく1枚ずつずれた)= この台では再現しない
- 測定(11/23 夜・Pixel 3a の実機): 報告の台で `#list_nested` を送って `#shelf_5` を出し、`ft_swipe finger: left scrollFrame: #shelf_5` → 注記なし(中身は1枚ずれた)。Emulator の5回と合わせて6回とも再現しない → 低頻度へ移す。出たら、払う前後の枠の中の木を残す
- 評価 11回目(2026-11-24): 作成 53 セッションのログに `nothing on the screen moved` は 0 回(材料なし)
- 照合(2026-11-25 夜・11/24 以降の `_work` のログを全数): 文言は 11/25 未明の探索(phys の a6・a7・ios1)に出たが、どれも容器でない枠をわざと指定した回(`scrollFrame is not scrollable`)か、縦の一覧で枠を指定せず横へ払った回 = 中身がずれていたのに出た元の形(MCP の横の容器)ではない。新しい材料なし
- 2026-11-26(測る余地の見直し): 測るには払う前後の枠の中の木が要るが、MCP の応答は保存されない(作成者の記録にだけ残る)。注記に比べた id を足すと MCP の注記の量が増えるので、出たときに `ft_snapshot` で採る扱いのまま
- 検証の所要(11/26): 台帳とコードの読み 約5分

### OI-359 Flutter の iOS(inapp-boost)で `clearAppData` が「could not delete 1 item(s) in the data container … : Library」の 500 で赤
- 状態: 再現済み
- 確認: 7b57ed9b5 + 作業ツリー(2026-11-23)
- 属性: 低頻度
- 運用: 再実行で吸収 — 赤になる(誤った緑ではない)
- 優先度: 低 — 1回・単独の再実行は緑

出典: 11/23 の全マシンの回帰(`_work/regress-20261123/regress.log`・`.fleetest/regress/20261123-070214`)。E2E-Flutter の ios-inapp-boost「ライフサイクルとプラットフォーム分岐が正しく働くこと」S0040 の 10 本目 `clearAppData com.ftester.e2e.flutter` が `The driver returned an error (500): could not delete 1 item(s) in the data container of com.ftester.e2e.flutter: Library`、続けて `The app process is not running — it may have crashed`。手元の iPhone 18 Pro -06
- 同じシナリオを手元で単独に回し直すと緑(1/1)
- 次の一手: 出たら、そのときの Library の中で消せなかった項目の名前とエラー(権限・使用中)を残す

### OI-346 MCP の `tap(linkText:)` の OCR が `fmAndVision: true` でも空を返す
- 状態: 再現済み
- 確認: 72aa89cbf(2026-11-22)
- 属性: 低頻度
- 運用: 回避可 — 文中リンクは本番(`fleetest run`)で確かめる
- 優先度: 低 — MCP だけ

出典: シナリオ作成の評価 7回目(2026-11-22・`_work/scen-eval-20261122/`。作成 76 セッション・@Test 358 本・本番 118 回・延べ 571 本・緑 538。一覧は同フォルダの `ISSUES.md`・本番の赤の分析は `logs/red-analysis.md`)
- 観測: 作成の 3 セッションが、MCP で文中リンクを押す `tap(linkText:)` の OCR が空(リンクの文字を見つけられない)と書き、文中リンクの検証を見送った。`fmAndVision: true` を渡しても同じ(セッションの記述・応答の文言は digest.md)
- 次の一手: 同じ画面で MCP の `ft_tap(linkText:)` と DSL の `tap(linkText:)` を撃ち、OCR に渡る絵と読みを比べる
- **測定(2026-11-23・評価 8回目の後の処理)**: 負荷の無い手元 Emu -05 の E2EY-Android で `ft_tap(selector: "#txt_terms", linkText: "利用規約", fmAndVision: true)` が `located by ocr inside #txt_terms; done`(初回 25.6 秒 = OCR の準備込み)。iPhone の SwiftUI は木で解決して OCR を使わない。再現しない = 作成時の空の読みは 13 セッション並行の負荷の下の回 → 低頻度へ

### OI-321 実機 SE3 の CMP のリストで、境界で薄く切られた行への `scrollTo("#row_15")` が「reached its end」で赤
- 状態: 再現済み
- 確認: 667a5a9 + 作業ツリー(2026-11-20)
- 属性: 低頻度
- 運用: 回避可 — 行を名指しせず端まで送る
- 優先度: 低 — 赤になる側(誤った緑ではない)

出典: シナリオ作成の評価 2026-11-20 夜(`_work/scen-eval-20261120d/`・本日改修した機能 = run メモ・@RunHooks・withRunLock・配置の属性。作成 10 セッション・本番 16 回)
- 観測: se3_cmp の作成時。失敗時の木に `#row_15` が 31pt で出ていた。`round 2: (16,197 343x56) ... the settle wait was cut off and the re-read did not show it touchable`
- 測定(2026-11-20 23:50 頃・SE3・単独): `launchApp → tap(#nav_scroll) → scrollTo(#row_15, maxSwipes: 12)` を inapp-boost 2 回・xcuitest 1 回 = 3/3 緑。
  観測した1回は作成中の MCP(XCUITest)で、直前の手順が違う。単独では再現しない
- 次の一手: 作成セッションの直前の手順(同じ画面での前の操作)を再生して再現を探す
- 測定(11/21 06:4x・SE3・`_work/scen-eval-20261121/logs/m321-*.log`): 作成セッションの直前の手順(入力画面で打って送る → 起動し直してリストの `scrollTo("#row_15")`)を 1 run に並べ、xcuitest モード・inapp-boost を 3 回ずつ = 6/6 緑。再現しない
- 評価 5回目: se3_cmp の作成・本番(4/4)とも出ず
- 評価 6回目(11/21): se3_cmp は週の利用上限で作成が始まらず(SE3 で CMP のリストを扱ったセッションは無し)= 材料なし
- 評価 8回目(2026-11-23・評価 8回目の後の処理): SE3 の作成・本番で 0 回(`reached its end` の赤なし)→ 要測定から外し低頻度へ

### OI-320 Flutter の iOS で `type(sel, text, replace: true)` が「tapping the input field did not give it keyboard focus within 1.5s」で赤
- 状態: 再現済み
- 確認: 667a5a9 + 作業ツリー(2026-11-20)
- 属性: 低頻度
- 運用: 回避可 — 空の欄なら replace を外す
- 優先度: 中 — docs の書き方で赤

出典: シナリオ作成の評価 2026-11-20 夜(`_work/scen-eval-20261120d/`・本日改修した機能 = run メモ・@RunHooks・withRunLock・配置の属性。作成 10 セッション・本番 16 回)
- 観測: once_flutter_ios(Simulator・MCP の ft_run_scenario = XCUITest)。素の type(追記)は同じ欄で通る
- 測定(2026-11-20 23:45 頃・Simulator -05・単独): `launchApp → tap(#nav_input) → type(#field_single, replace: true)` を xcuitest モード 3 回・inapp-boost 3 回 = 6/6 緑。
  観測した1回は6セッションが同じ Mac で並行していた(負荷の下)。単独では再現しない
- 次の一手: 負荷の下(同じ Mac で並行の run)で反復し、出たときの焦点待ちの所要を採る
- 評価 5回目(11/21・`_work/scen-eval-20261121/`): Flutter の iOS で replace 付きの type を書いたセッションはあったが出なかった
- 評価 6回目(11/21・`_work/scen-eval-20261121b/`): CMP の iOS で replace なしの type が同じ「did not give it keyboard focus within 1.5s」の 422(lk_e2e_cmp・duo_memo_cmp の作成時。どちらも同じ Mac で 11 セッションが並行)
- 測定(11/22 01:2x〜01:5x・Sim -06・`_work/scen-eval-20261121b/logs/m320-*`): CMP の iOS の入力画面で replace なしの type を4回(単一行・パスワード・単一行・複数行)× xcuitest モード 6 run・inapp-boost 6 run を、CPU を `yes` 22 本で埋めて回した = 48/48 の type が緑(1 run 約3分)。再現しない。観測した2回はどちらも同じ Mac で 11 の作成セッション(claude -p)と Simulator・Emulator が並行していた = CPU だけの負荷では作れない形
- 測定(11/21 07:2x・Simulator -05・`_work/scen-eval-20261121/logs/m320b-*.log`): 同じ Mac で run は1本ずつしか走らないので、前回の「6 セッションが並行」の代わりに CPU を `yes` 22 本で埋め、`launchApp → tap(#nav_input) → type(#field_single, …, replace: true)` × 4 を 6 run = 24/24 緑(inapp-boost から XCUITest へ回る経路)。再現しない
- 評価 7回目(11/22・`_work/scen-eval-20261122/`): 作成時の MCP で 4 セッション(CMP・Flutter の iOS)。本番では出ず
- 評価 8回目(2026-11-23・評価 8回目の後の処理): 作成 80 セッション・本番 147 回で 0 回 → 要測定から外し低頻度へ(出たら焦点待ちの所要を採る)

### OI-325 E2EY-RN の iOS(inapp-boost)で、行の長押し(`tap(hold: 1)` を XCUITest へ回した)が選択モードに入らないまま ✅(回帰の負荷の下で1回・単独では 3/3 緑)
- 状態: 再現済み
- 確認: 667a5a9 + 作業ツリー(2026-11-21)
- 属性: 低頻度
- 運用: 要注意 — 長押しの ✅ が効いていない。後の検証で赤になる
- 優先度: 中 — 誤った緑だが後続の検証で赤になる

出典: 回帰(`_work/regress-20261121/`・手元の Simulator -07)
- 観測: `選択モードで行を選んで削除できること.S0020` の `tap "#sel_row_05" (hold 1s)(fell back to XCUITest)` が ✅、続く `textIs "#txt_select_mode" == "mode=select"` が `actual "mode=normal"`。同じシナリオを単独で 3 回回すと緑。11/20 の回帰では緑
- 関係: OI-221(XCUITest へ回した長押しからのドラッグが ✅ なのに効かない・負荷の下)と同じ系統の可能性(推測)
- 次の一手: 回帰と同じ負荷の下(`--broadcast` で手元の全台)で反復し、出たときの XCUITest の press の所要と、アプリが受けた長押しの長さを採る

### OI-314 行き過ぎて引き返した探索が、行を貼り付く見出しの下で止め、タップが見出しに吸われた(Flutter・xcuitest モード・回帰の負荷の下で1回)
- 状態: 再現済み
- 確認: 作業ツリー(RR-8.3 の実装 + 11/19 夜の直し。2026-11-19)
- 属性: 低頻度
- 運用: 合否に響く(赤)・回し直しで通る
- 優先度: 低 — 8 回の回し直し(手元 5・M1Max/M4Max 3)で再現しない

出典: 最終の回帰(2026-11-19 22:10・`_work/rr83-impl/regress4.log`。E2EX-Flutter/ios-xcuitest・手元)
- `貼り付く見出しのリストを扱えること.S0010` の `tap("#row_s_F3", scroll: .down)` が「found by sweeping back after overshooting it」で 20.64s かかり、撃った時点で `#hdr_F`(16,180 83x20 = 文字の幅だけの Flutter の見出し)が行の中心を覆っていた。結果は `sticky=none`(タップが見出しに当たった)。撃つ前の送り(`liftCoveredTarget`)が効かなかった理由は記録から言えない(見出しの帯の推定 `inferredPinnedBand` に入ったか・送った後の木で再判定したかの記録が無い)
- 次の一手: 再び出たら、送りの判定(覆いの有無・送った量)を注記に残しているかを見て、無ければ測る口を足す
- 反復(2026-11-25): M1Ultra・M4Max の Simulator(xcuitest)で S0010 を 170 回(`--broadcast`)回して 0 回。材料は採れていない
- 測る口(2026-11-25): 結果 JSON の各ステップに判定の足跡(`trace`・docs/results-json.md)を足した。撃つ前の送り(`liftCoveredTarget`)は覆いと見た回ごとに `keyboard-cover-lift`(覆いの種類・枠・送った量・撮り直した木で再判定したか・まだ覆われているか)、探索は `scroll-search-end`(止まった理由・本数・最後の1本の種類・見つけた要素の枠)。次に出たら timeline の `trace` を見る

### OI-269 M1Max の iPhone 17e で SpringBoard が落ちてランナーを起動できず、再実行でも同じ失敗(自分では起こし直さない)
- 状態: 再現済み
- 確認: 0b9a7aeb6 + 作業ツリー(2026-11-18)
- 属性: 低頻度
- 運用: 再実行では吸収できない — 手で起こし直す
- 優先度: 低 — 特定の機械だけ

出典: シナリオ作成の評価(2026-11-18・`_work/scen-eval-20261118/`。AI のセッション 26 本が作った 215 本を、作成と別の端末で本番の経路 = `fleetest run`・inapp-boost・テキストの可視性検証ありで回した。一覧は同フォルダの `ISSUES.md`・各セッションの所見は `ws/TestProjects/<proj>/EVAL_REPORT.md`・実行ログは `logs/run-*.log`)
- 測定(11/18・M1Max のランナーの `bridge-8130.prev.log`): `Simulator device failed to launch com.example.ftrunner.uitests.xctrunner.` / `Host is down` / `Failure Reason: The system shell probably crashed.`。11/18 の処理の時点では SpringBoard は動いていた(終了状態 -6 = 一度落ちて起動し直された跡)ので、起こし直しで直るかは測れなかった
- 直した(11/18): 外部構成のディスパッチのレポートのパス・可視性検証の切り抜きの置き場。Simulator でランナーを起動できなかったとき、xcodebuild のログの理由(`Finished with error` と `Failure Reason`)を初回の文言に出す(`BridgeLauncher.simulatorLaunchFailureReason`)
- 材料不足: SpringBoard が止まった状態で、shutdown → boot で直るか
- 観測(11/18・2回目のシナリオ作成の評価): M1Max の iPhone 17e を2回(e2e_ios_sim・e2ey_cmp_ios の本番の経路)使い、どちらも起動できた(SpringBoard の落ちは出ず)= 低頻度のまま
- 次の一手: 次に起きたとき、手で起こし直して直ることを測る。直るなら、供給で1回だけ起こし直して効いたかを測る形(`RunnerRestartFutility` と同じ規律)を入れる
- 測る口(2026-11-25): ランナーの起動の時間切れとワーカーの蘇生の前に、SpringBoard の launchd の状態と直前の統合ログを保存する(OI-196 の同じ日の行)。次に出たら `diagnostics/` の採取で SpringBoard が止まった時刻と終わり方を見る

### OI-250 全体の単体テストで `ScenarioHostIdleWatchTests.testSilentChildIsKilledWhenOutputStops` が「最初の出力から 6 秒以内に返る」を 9.6 秒で外して赤(1回・単独では緑)
- 状態: 再現済み
- 確認: 2026-11-16
- 属性: 低頻度
- 運用: 再実行で吸収 — 単独の `swift test --filter ScenarioHostIdleWatchTests` は緑
- 優先度: 低 — テストの赤だけ(製品の打ち切りは効いている)

出典: 11/16 の `FT_FULL_TEST=1 Scripts/unit-tests.py`(22 並列)。時刻の記録は hello 2.95 秒・打ち切りの文 11.15 秒で、文は「no output for 2.0s」と言う = 打ち切りの側が無出力を数え始めたのが hello の到着より約 6 秒遅い
- 材料不足: 遅れたのが子の出力の配送(パイプの読み)か、打ち切りの側の起き上がりか
- 観測(11/26): 48 本の CPU 負荷(`yes`)の下で `ScenarioHostIdleWatchTests` を 10 回回して 0/10(再現せず)
- 検証の所要(11/26): 負荷の下の 10 回(OI-297 の FMServeAlignmentTests と同じ回にまとめて)・約30分
- 次の一手: 次に出たら、打ち切りの側が hello を受けた時刻を記録に足して(測る口)どちらが遅れたかを分ける

### OI-229 E2EY-iOS の入れ子スクロールで、`scrollTo("#txt_shelf_7")` の後の `exist("#shelf_7")` が「中心が画面の外」で赤(xcuitest・24 回中 2 回)
- 状態: 再現済み
- 確認: 0824ec553(2026-11-13)
- 属性: 低頻度
- 運用: 再実行で吸収(赤になる・誤った緑ではない)
- 優先度: 低 — 判定は画面と合っている(見出しの下の棚が画面の下端の外)

出典: `_work/oi227`(11/13・scrollFrame の横の探索の見切れの寄せの直しの確かめ)。手元の 8 台へ broadcast で xcuitest の S0010 を 3 周。直しの版で 24 回中 2 回、`scrollTo("#txt_shelf_7")` ✅ の直後の `exist("#shelf_7")` が「centre (201, 889) is outside the screen」。この scrollTo は scrollFrame もキーボードも無い = 送る道(path)が作られず、見切れの寄せは直しの前から遅いドラッグ(`StepExecutor+ScrollFrame.swift` の `scrollContainer` が nil)= 直しの変えた経路を通らない。HEAD での対照 24 回と、それ以前の xcuitest の手元の結果 50 回では 0 回。探索が見出しを出した所で止まり、その下の棚(高さ 120)が下端に残る位置で止まったかどうかは探索の記録が報告に残らないので材料不足
- 次の一手: 次に出たら、scrollTo の止まった位置(見出しの y)と、最後の1本が払いか寄せかを採る
- 反復(2026-11-25): M4Max・M1Max の Simulator(xcuitest)で S0010 を 240 回回して 0 回。材料は採れていない
- 測る口(2026-11-25): scrollTo の止まり方を判定の足跡 `scroll-search-end`(`lastSend` = 最後の1本が払いか寄せか・`elementFrame` = 止まった時点の枠)に残す。次に出たら直前の scrollTo のステップの `trace` を見る

### OI-226 E2EX-Flutter の Android の時刻ピッカー(入力モード)で、`type(".textField[1]", "14")` が「target node not found」の 500 で赤(17 回中 1 回)
- 状態: 再現済み
- 確認: d4659bd0e(2026-11-13)
- 属性: 低頻度
- 運用: 再実行で吸収(赤になる・誤った緑ではない)
- 優先度: 低 — 1/17・11/13 に足したばかりのシナリオ

出典: `_work/regress-20261113b`(11/13 の全マシンの回帰)。M1Max の Pixel 10 Pro(Android 17)-03 で「時刻ピッカーで時刻を確定できること」S0030(6fbb90732 で足した文字盤を入力モードに切り替えて打つ形)の `tap("Switch to text input mode")` ✅ の直後の `type(".textField[1]", "14")` が「cannot type into the field that was tapped (target node not found, 4000ms waited; nothing was read back, refresh failed, ACTION_SET_TEXT accepted 0 times …)」。直後に手元の8台と M1Max の4台×2回で 16/16 緑。入力モードへの切り替えの直後に欄のノードがまだ出来ていなかったのかは材料不足(失敗時の木の欄の有無を見ていない)
- 次の一手: 次に出たら、失敗時の木に `.textField` が2つ並んでいるか(切り替えが済んでいたか)を見る
- 回帰 11/21 08:01(`_work/regress-20261121/regress.log`・24 対象・全マシン): M1Max の Emulator -01 で再出。`type ".textField[1]" "14" (replace)` が `(500): cannot type into the field that was tapped (target node not found, 4000ms waited; … ACTION_SET_TEXT accepted 0 times …)`
- 反復(2026-11-25): M1Max・M1Ultra の Emulator で S0030 を 300 回回して 0 回。材料は採れていない

### OI-220 iOS の MCP: 閉じかけのシートの一覧で ft_scroll_to が 202 秒かかり、シートを広げる前に払いを使い切って届かない(1回)
- 状態: 再現済み
- 確認: e5d7a8a81(2026-11-12)
- 属性: 低頻度
- 運用: 合否に響かない(MCP だけ・時間の損。エージェントは手でシートを広げて読めた)
- 優先度: 低 — 計測の10回中1回

出典: `_work/mcp-verify/new_cur23.jsonl.scroll.txt`(Apple マップの経路の手順・iOS 27 Simulator・11/12)。`ft_scroll_to "*到着*||立川駅" scrollFrame: #TransitDirectionsListView` が「search took 201.7s (10 swipe(s) + 4 slow no-fling drag(s); reading the tree 7.0s, gestures 191.1s …)」で届かずに返った。1回の払いが約19秒で、同じ計測の他の回の操作にも「XCTest did not report the app idle within 6s」が付いていた。探索は「the content was still moving when the last swipe was used」と言い、`.sheetCollapsed` が立たないのでシートを広げる救済に入っていない(同じ画面の他の回は2〜4払いで救済に入り、届いた)
- 次の一手: 同じ形が出たら、払いごとの所要の内訳(XCTest の静止待ちか、払いそのものか)と、中身が動いたと判定した根拠(どの要素が動いたか)を採る

### OI-196 Duo の XCUITest ブリッジの起動の時間切れ・起動を諦めた後に XCUITest ランナーのアプリが残る
- 状態: 再現済み
- 確認: ad54d899c(2026-11-10)
- 属性: 低頻度
- 運用: ④合否に響かない ⑤再実行で吸収(run は別のデバイスで回す・1台だけの run は止まる)
- 優先度: 低 — Duo だけ

出典: `_work/explore-20261107i/findings-*.md`(38周目・11/7)。④Duo で run が起動を諦めた後に XCUITest ランナーのアプリが xcodebuild も台帳も無いまま約 5 分残る(duo F1・1/1)
- 11/8: ④は1回の観測で材料不足(Duo だけ)。次に出たら、ランナーのアプリのプロセスと台帳を記録する
- 11/10(⑤ Duo の -01 の XCUITest ブリッジの起動の時間切れ・材料不足): 11/9 に1本の run と MCP の `ft_run_scenario` が -01 の XCUITest ブリッジの起動の 180 秒の時間切れで止まった(duo 44・45周目 F2 = 2/2)。-01 だけを冷えた状態(Simulator を止めてから)で `bridge up` を3回 = 3回とも準備完了(全体 117 / 61 / 55 秒・xcodebuild の開始から待ち受けまで 52 / 19 / 13 秒。ホストの load1 は 86 と高かった)= 再現せず。手元の台帳のログで Duo の起動を数えると、-01 は 11/6〜11/9 に8回中7回、-02 も 11/6〜11/7 に3回が時間切れ。時間切れの回はどれも xcodebuild の最初の行の後にランナーの `Running tests...` が1行も無いまま `BUILD INTERRUPTED` = ランナーのテストが始まらない段で止まっている(成功の回は約 8 秒後に出る)。`invalidDigitCount(91016)` の行は成功の回にも毎回出る(Duo の版の文字列に対する xcodebuild の警告)ので原因ではない。11/9 以降に起動の経路の変更は無い。なぜランナーのテストが始まらなかったかの材料は無い(当時 -01 の SpringBoard は異常終了の跡 = 状態 -5 を持っていた・関係は不明)。次に出たら、時間切れの時点で Simulator の上のランナーのプロセスの有無を採る

- 11/13(⑤ の材料・53周目 duo F1): -01 の XCUITest ブリッジの起動が 2 run とも 180 秒の時間切れ(文言は「connection refused」だけ)。直後の 11:36〜11:37 に -01 の SpringBoard と InputUI は launchd の状態が -5・PID 無しのまま(7回確かめた。同じ時刻の -02 の SpringBoard は動いていた)= OI-184 の落ちを繰り返した後に起き直さなくなった形。最後の SpringBoard の .ips は 11:20:36。起動を試していた間ずっと止まっていたかは採っていない = 材料不足。次に出たら、起動の時間切れの文言に SpringBoard の生死(`launchctl list` の状態)を添えるかを、起動の最中の状態を採ってから決める
- 11/13(⑤ の原因の観測・54周目 duo): 12:25〜12:27 に両 Duo の SpringBoard と InputUI が同時に止まり(`launchctl list` で `- -5`・PID 無し)、12:37 まで起き直さなかった(約 25 回採取。新しい .ips は出ず、10:44 の .ips の更新時刻だけが 12:27 に変わった)。その間に撃った Duo-02 の XCUITest ブリッジの起動は 180 秒の時間切れ(「connection refused」・xcodebuild は BUILD INTERRUPTED)で、起動の最中の 3 回の採取でも SpringBoard は止まっていた = **起動の時間切れは SpringBoard が止まったままの Simulator で起きる**(53周目の -01 と同じ形)。文言は SpringBoard を名指さない。次の一手: Simulator の XCUITest ブリッジの起動が時間切れになったら、そのデバイスの SpringBoard の生死(`launchctl list` の状態)を文言に添える・止まっていれば Simulator の起動し直しを勧める(起こし直しの自動化は別に判断)
- 11/13(直し): Simulator の XCUITest ブリッジの起動が時間切れになったら、`launchctl list` の SpringBoard の行の PID 列が `-` のときだけ「SpringBoard が動いていない・止まっている間ランナーは上がらなかった・Simulator を止めて起動し直す」を文言に添える(`SimulatorAppProcess.springBoardStopped`・UDID のときだけ聞く)。行の読みは実測の形(`- -5 com.apple.SpringBoard`)で固定。端末で止まったままの SpringBoard を作れなかった(殺しても launchd が数秒で起こし直す)ので、時間切れの文言そのものは次に出たときに確かめる
- 評価 7回目(11/22・`_work/scen-eval-20261122/`): Duo -02 の XCUITest ブリッジが本番の5回とも起動せず、ランナーが起動の見張りで kill された記録(0x8BADF00D)が 06:32:56 と 07:12:56(duo-4 の「TEST EXECUTE FAILED」と同じ時刻)
- 測る口(2026-11-25): Simulator の XCUITest ブリッジの起動の時間切れ・準備前の終了の確定時に、SpringBoard 等の launchd の状態・端末の統合ログの直近 10 分・SpringBoard の .ips の一覧を保存する(`SimulatorDiagnosticsCapture`・理由 `bridge-startup-timeout`。run の中は結果フォルダの `diagnostics/`、外は `.fleetest/diagnostics/`)。デバイスでは未通過
### OI-190 E2E-Flutter の Android で払いの向きが「下」と読まれる(低率)
- 状態: 経路確定
- 確認: 7161b1156(2026-11-11)
- 属性: 低頻度
- 運用: 再実行で吸収 — ブリッジの払い(4方向の `swipe`)は 11/11 に直した(負荷の下 0.4%・全体の回帰で 0 件)。残るのは座標の払い(`swipePointToPoint` 等)で、全体の回帰で 47 本中 1 本
- 優先度: 低 — 低率の赤(沈黙しない)

**観測**: E2E-Flutter の Android の「ジェスチャが正しく検出されること」S0010 で、払いの後の `textIs("#txt_swipe_dir", …)` が向きに関わらず actual `swipe=down` で赤。11/7・11/9 のフル E2E で4方向の `swipe` が 19 回中 3 回、11/11 は座標の払い `swipePointToPoint` が 34 回中 3 回(負荷の下 2/16・負荷なし 1/6)と全体の回帰で 1/47。
- **原因(11/11)**: Flutter の `VelocityTracker` は最後の MOVE を受けてから UP までを**アプリ側の壁時計**で測り、40ms を超えると速度 0 を返す(velocity_tracker.dart の `_assumePointerMoveStoppedMilliseconds`)。SUT の向きの判定は速度 0 で必ず `down`。陽性対照(手元の Emulator・`input motionevent` で UP だけ 200ms 遅らせる)で左・上の払いが `swipe=down`・遅らせない `input swipe` は `swipe=left`。Android ブリッジの払い(`InputInjector.swipe`)は最後の MOVE の後に 16ms 眠ってから UP を撃っていて、負荷の下で眠りが延びる
- **直し(11/11・2832db37a・ブリッジ v136)**: gesture(DSL の `swipe`・flick の払い・MCP の `ft_swipe`)とフリングは最後の MOVE の直後に離す(search の非フリングは View/Compose の飛び越し防止なので変えない)。ブリッジへ直接 `/swipe` を撃つ対照(手元の6台・`yes` ×20 の負荷・v135 と v136 を交互に3ブロック・各 540 回)で 11/540 → 2/540(すべて `down`・片側 Fisher p≈0.011)。残る 0.4% はブリッジが UP をすぐ撃った後の端末側の遅れで、ブリッジには削れる間が無い。負荷なしの4 SUT の Android の払い・スクロール・フリックは 281/282 緑
- **残り(同じ型・直していない)**: 座標の払い(`swipePointToPoint`・`swipeBy` 等、in-app でない Android の `dragWithFallback`)は gRPC のドラッグ(`EmulatorGrpcSession.drag`)で、こちらも最後の MOVE の後に `durationMs/steps` 眠ってから別の呼び出しで UP を送る。この経路は遅いドラッグの寄せ(ac5528ff9)・端送り・フリックと共有。直すなら drag に用途を渡す口を足して(`drag` の実装は 44 ファイル)、座標の払いだけ直後に離す。率を回帰の数回分見てから決める
- 試して取り消した直し(11/11): gRPC のドラッグを一律に最後の MOVE の直後に離す版。座標の払いの誤読は負荷の下 1台で 14/180 → 6/180(片側 Fisher p≈0.053)に減ったが、E2E-Android(View)の `flickBottomToTop` が一覧を送らない赤が負荷なしで 3/24(HEAD は交互に回して 0/18)= 「平常時の間は 40ms 未満なので挙動は変わらない」の前提が外れた(View のフリックは最後の間に依っている。仕組みは未観測)
- 反復(2026-11-25): M1Ultra・M1Max の Emulator で E2E-Flutter の S0010 を 206 回(`--broadcast`)回して 0 回。材料は採れていない

### OI-138 MCP の Android が、同じ serial で入れ替わった Emulator を前の接続のまま読む
- 状態: 経路確定
- 確認: コミット未記録(2026-11-07)
- 属性: 低頻度
- 運用: 回避可 — Emulator を入れ替えたら MCP のプロセスを起こし直す。シナリオの実行には響かない
- 優先度: 低 — MCP の長く動いたプロセスだけ

`serial: emulator-5570` の `ft_batch` の木は E2EX-Flutter の入力画面(`value="xyz"`)だったのに、続く `ft_screenshot` は別の SUT のホーム画面だった(`adb -s emulator-5570 exec-out screencap` は入力画面)。同じ時刻に他の Emulator は E2E-Android のホームを表示していた。MCP のプロセスは約3時間前に起動した古い版で、その間に Emulator 8台を止めて別の8台が同じ serial で起動している。新しい MCP のプロセスで再現するかは未確認(1回)
- 11/7: 元の形(木は正しく絵だけ別)は再現せず。陽性対照で、古い host のポートを別の Emulator の forward に付け替えると `ft_snapshot serial:5562` が 5564 の木を黙って返した = `AndroidBridge.ensureBridge` の `.active` の接続の記録が宛先の入れ替わりに気づかない(経路はこの形で確定。元の形との関係は未確認)
- 検証の所要(11/26): `AndroidBridge.ensureBridge` の読み(`.active` は宛先を確かめずに返す = 経路は記述どおり)・約10分

### OI-146 React Native の iOS の横向きで、寄せが収まりきらなかった回の次の画面の最初のタップが飲まれる
- 状態: 再現済み
- 確認: コミット未記録(2026-11-03)
- 属性: 低頻度
- 運用: 要注意 — 横向きの RN の iOS で遷移直後の最初のタップが飲まれる(注記は出る・後続で赤。4/8)。遷移の後に `exist` を挟んで避けられるかは未確認
- 優先度: 中 — 横向きの RN の iOS で 4/8 飲まれる(注記・後続で赤)

E2E-RN の iOS(inapp-boost モード)を `orientation=landscape` で全台(8台)へ配ると、ホームの `tap("#nav_gesture")` の寄せが「not fully inside」(収まりきらない)になった2台だけで、遷移したジェスチャ画面の最初の `tap("#btn_tap_counter")` が飲まれた(`tap=1` / `tap=2`。どちらも in-app の合成タッチで「the screen looked the same when it settled」の注記付き = 誤った成功ではなく後の確かめで赤)。寄せが収まった6台では 0 件。寄せの払いの慣性・跳ね返りが残ったまま遷移し、最初のタッチが RN の応答者の切り替えに使われた疑い(未確認)。次に見るもの: 寄せの後に整定を待っているか・飲まれた回の木の動き
- 11/4: 手元の 8 台・横向きで 2 周とも 4/8
- 11/7: 再現せず 0/6(寄せが毎回収まった)

### OI-177 openURL で Safari を出した後の tapAppIcon() でアプリが前面へ来ない
- 状態: 再現済み
- 確認: コミット未記録(2026-11-06)
- 属性: 低頻度
- 運用: ①再実行で吸収 — `openURL` で Safari を出した後の `tapAppIcon()` だけ・5/16
- 優先度: 低 — ①は再実行で吸収

出典: `_work/explore-20261106b/findings-*.md`(18周目・11/6)。①inapp-boost で `openURL("https://…")`(Safari が前面)→ `tapAppIcon()` が、正しいアイコンを押したのにアプリが 15 秒で前面へ来ず赤になり「process not running — it may have crashed」の注記が付く(ilocal F2・5/16。その時刻の .ips は無い)= 要測定(アプリが落ちたのか・タップが届かなかったのかを分ける事実が無い。注記が言えるのは「赤の時点でプロセスが居なかった」だけ = `SimulatorAppProcess.failureEvidence`。先に測る口: `tapAppIcon` の押す直前にも生死を1回聞いて notes に残す。report-mcode)
- 11/6(第2回の測定): ①は再現せず(0/8・負荷は元の所見と同程度)
- 11/7: ①は再現せず 0/24

### OI-137 マシンの FM・Vision が止まっていた間に、Simulator の文字消えでレーンが外れた
- 状態: 推測
- 確認: a3135ab2f(2026-11-10)
- 属性: 低頻度
- 運用: 回避可 — 長く動かしたマシンは再起動してから回す
- 優先度: 低 — 長く動かしたマシンだけ・再起動で回避

起動から約 11 時間の M2Ultra で FM が dead・Vision の OCR が空(`Hello 123` の絵も読めない)だった間、E2E-CMP の xcuitest が「none of the N text element(s) … is drawn」で 4/24 赤・レーン離脱。この判定(`RenderCollapse`)は OCR ではなく切り出した領域の輝度のばらつきで見るので、絵に文字が無かったのは事実。マシンの劣化(GPU / ANE)で Simulator の描画が崩れたのか、偶然の重なりかは分けていない。再起動後に同じ形が出るかで見る
- 11/10: 起動から約 17 時間の手元(配信あり・`fmText=alive fmVision=alive`)の全体の回帰(a3135ab2f・`_work/release-20261110d`)で、E2EY-Android の「文中のリンクだけを押せること」S0030 が「OCR read no text in the element; 3 OCR passes」で赤。OCR へ渡した絵(報告の `read_by_link_text_ocr.png`)には「こちら」がはっきり描かれている = 絵は正しく、OCR が空を返した。同じ日の 03 時の単体テスト(`LinkTextLocatorTests` の「OCR read: []」と `FindImageTests` の Vision の縮退)と同じ形。直後に同じ単体テストは 13/13 緑・同じシナリオを Android 18 台で回し直すと 30/30(リモート)・23/24(手元。残る1本は OI-127 の一色)= 機械の状態で出入りする。健全性の表示(`fmVision=alive`)はこの間も alive = 生死の監視では捉えられない
- 11/11: Vision の OCR と特徴量の死活の確かめを入れた(7161b1156・7efdc723f。`api host-metrics --vision-probe` が内蔵の絵で1分ごとに確かめ、死ならモニターに ⚠︎OCR / ⚠︎FP・変わり目を `~/.fleetest/vision-history.ndjson` に時刻付きで残す)。次に出たら、赤の時刻とその機械の履歴を突き合わせる

### OI-127 手元の Emulator の白紙が回帰の終盤に集中した
- 状態: 再現済み
- 確認: コミット未記録(2026-11-10)
- 属性: 低頻度
- 運用: 回避可 — 重い回帰の間は配信を止める(`fleetest monitor pause`。止めると 8/8 緑)
- 優先度: 低 — 配信を止めれば回避

配信なしのフル回帰(73a31d8b)で、23:06 前後に手元の Emulator 4台が白紙になり `E2EX-RN/android` の1本が赤。`E2EY-Android` も1本が再実行。同じ対象を単独で3周(144 本)回すと白紙0件で再現しない。終了時の手元は `videoEncoder=dead`。原因は未測定。
- 11/4: 配信を止めずに回したフル回帰(22012640)で、手元の Emulator の白紙(テキストの可視性検証が「スクリーンショットのアプリの領域が一色」)が E2E-RN・E2EX-RN の Android で計 9 件。同じシナリオを手元の 8 台へ配ると配信ありで 5/8 赤・**配信を止めると 8/8 緑**(E2EX-RN のチップ)= 手元の配信と Emulator のスクリーンショットの干渉。同じ日の朝の配信ありの回帰は 24/24 緑 = いつも起きるわけではない
- 11/7: 配信を張ったまま回した回帰(043600661 の後・`_work/regress-20261107f`)で、E2E-Flutter の Android の S0030 が「app area … is a single colour」で赤。d2dd8d1e4 と HEAD を手元の8台で交互に3周ずつ回すと一色は 3 と 3 = 版の差ではない
- 11/10: 配信を張ったままの全体の回帰の後、E2EY-Android の「文中のリンクだけを押せること」を手元の8台へ配ると、-05 の S0020 が「the app area of 3 of the screenshots given to OCR was a single colour … waited 114.9s for a non-blank screenshot」で赤(1/24)。直後に `adb exec-out screencap` で撮ると正しく描かれている = 端末の画面ではなく撮影の経路が一色を返し続けた

### OI-198 Vision の異常で `existImage` が距離 0.000 の別の行を返す(機械の状態で出る)
- 状態: 再現済み
- 確認: 9d8f94471(2026-11-10)
- 属性: 低頻度・環境側
- 運用: 再実行で吸収 — 主に長く動かしたマシンで出る(再起動の後は 0/96。11/10 に再起動から 6.9 時間でも1件)。誤った行を返すと後続の `idIs` が赤にする
- 優先度: 中 — 見つけた要素を取り違える(後続の検証が赤にする)

E2E-Flutter の Android の「画像で要素を探す」S0040 の `existImage("[Diagnostics Nav]", threshold: 0.03, scroll: .down).idIs("nav_diagnostics")` が、距離 0.000 で木の先頭の行 `nav_selector` を返して `idIs` が赤(043600661 の回帰・手元の8台で回し直して 2/24・4/24)。同じ時期に `existImage("[Checkbox]")` が距離 0.369 で見つからない赤も出た(一色の絵の赤は OI-127)。
- 11/7(対照): 11/6 の版 d2dd8d1e4(ブリッジ v126。古い版は新しいブリッジを自動で引き下げないので `adb uninstall com.example.ftbridge` してから)と HEAD を手元の8台で交互に3周ずつ = `nav_selector` は 3/24 と 9/24(p≈0.1 = 差と言えない)。画像の照合のコードは両版で同一 = 11/7 の変更への帰属は否定
- 11/8: 照合の記述に同じ距離の候補の数と次点の距離を足した(cd6a3f792 = `found (distance …, N candidates at that distance, next …)`)。マシンの再起動の後は手元の8台で4周 96 本すべて緑で、S0040 は 24 本とも特徴量では閾値に届かず分類器で採った(`distance 0.066 > threshold 0.030`)= 健全なら正しい行でも 0.066 で、別の行が 0.000 になるのは候補の特徴量が壊れたときだけ。今の門(白紙との距離・見本の取り直し)は候補の計算の前にしか掛からない。次に赤が出たら記述の同じ距離の候補の数で、全候補が並ぶ縮退か(候補の側にも門を掛ける)を確かめてから直す。長く動かした機械の FM・Vision の停止は OI-137
- 11/10: 配信を張ったままの全体の回帰(9d8f94471・`_work/regress-20261110b`)で再発。手元は再起動から 6.9 時間 = 「長く動かした機械」だけではない。記述は `found (distance 0.000, next 0.066) / 11 compared` = 同じ距離の候補は1つだけ(全候補が並ぶ縮退ではない)・次点 0.066 は健全なときの正しい行の距離 = 正しい行の計算は健全で、**別の1行だけが 0.000 になった**。直後に手元の6台で3周(72 本)回すと全部緑(正しい行を分類器が 0.066 で採る)。候補の側の門は、何が 0.000 を作るか(その行の切り出しの絵)を観測するまで掛けない
- 11/11(材料の採り口): 通った単数の `findImage` / `existImage` の照合の絵を次の1ステップへ持ち越し、そのステップ(`idIs` 等)が自分の絵を持たずに落ちたらレポートに添える(印 `preceding-image-match`)。照合の記述に採った候補の切り出しの枠(`cropped at x,y wxh`)も出す。**次に赤が出たら、添えた絵のその枠を切り出して 0.000 を作った絵を見る**(白紙・一色・正しい行と同じ絵か)。同じ時刻のその機械の Vision の死活の履歴(`vision-history.ndjson`・OI-137)も見る

### OI-289 Android 実機の横向きのフルスクリーン IME(extract view)で、DSL の type・Enter・検証が割れる
- 状態: 再現済み
- 確認: 657e032d1(2026-11-19)
- 属性: 低頻度
- 運用: 回避可 — type の後に hideKeyboard()。ただし①は避けられない
- 優先度: 高 — 横向きの実機で普通の書き方が赤になる

出典: シナリオ作成の評価 3回目(2026-11-19・`_work/scen-eval-20261119/`。AI のセッション 65 本が作った 332 本を、作成と別の端末で本番の経路 = `fleetest run`・inapp-boost・テキストの可視性検証ありで 93 回・延べ 446 本回した。一覧は同フォルダの `ISSUES.md`・各セッションの所見は `ws/TestProjects/<proj>/EVAL_REPORT.md`・実行ログは `logs/run-*.log`)
- 横向きの Pixel 4a でキーボードが出るとアプリの窓が木から丸ごと消える(注記「a full-screen keyboard (such as the landscape extract view) hides the app's window from the tree」)。5 セッションで踏んだ
- ① r6_e2ex_flutter_4a(Flutter): 入力の種類のパスワード欄・複数行欄への DSL の `type` が 500「cannot type into the field that was tapped (the field could not be found again after ACTION_SET_TEXT was accepted, 4000ms waited; read back 0 masked characters, …, the IME window is in front; giving up rather than typing into the wrong field)」で赤(2 本)。先頭の数字欄は緑。**縦の Emulator では同じ 9 本が全部緑**。MCP の ft_type は通る
- ② r3_e2ex_and_4a(Android View の SearchView): `ft_type(pressEnter: true)` で値は入るが、結果表示は search=none のまま(2 回)
- ③ e2e_rn_4a・r4_e2e_and_4a: type の直後の `textIs` が「element not found」だけで赤(キーボードが覆っている可能性を言わない)
- 測定(11/19 06:1x〜06:3x・同じ 4a): 作成時の赤(05:10〜05:15 に 5 回とも 500)は、縦で 7/7・横向き(user_rotation=1・ft_rotate)にして 4/4 とも緑。`dumpsys input_method` は横向きでも `mInFullscreenMode=false`(キーボードは窓を縮めるだけ)= 作成時に出ていた全画面入力(extract view)の状態を作り直せなかった。4a の向きは評価の途中(05:15〜06:12 の間)に横から縦へ変わっていた(誰が変えたかは未観測)
- 次の一手: 全画面入力が出る状態(Gboard の横向きの全画面入力)になったら、①の SET_TEXT の後に欄を見つけ直せない理由と②の Enter の宛先を測る
- 4回目の評価(11/19・`_work/scen-eval-20261119b/`): 縦向きでも出た(r6_e2ex_flutter_4a の `ft_batch` の type が `cannot type into the field that was tapped (the field could not be found again after ACTION_SET_TEXT was accepted …)` で FAILED、同じ応答の木では `textField value="山田"`・欄はキーボードで y 1312 → 1125 → 938 と上へ動いていた)。欄が動いたことは観測・見つけ直せなかった理由は未観測
- 2026-11-26(再試行・Pixel 4a・E2EX-Flutter の入力の種類・横向き): パスワード欄に焦点を当ててもキーボードは全画面入力にならない(`mInFullscreenMode=false`・`mExtractViewHidden=false`)= 11/19 と同じく状態を作れない。出る状態になったら測る
- 検証の所要(11/26): 約5分

### OI-292 RN の iOS(XCUITest)の type が、短い文字列でも毎回「retyped the whole text 1 time(s) after a keystroke was dropped mid-string」
- 状態: 再現済み
- 確認: 657e032d1(2026-11-19)
- 属性: 低頻度
- 運用: 合否に響かない(打ち直しで正しく入る)
- 優先度: 低 — 時間の損だけ

出典: シナリオ作成の評価 3回目(2026-11-19・`_work/scen-eval-20261119/`。AI のセッション 65 本が作った 332 本を、作成と別の端末で本番の経路 = `fleetest run`・inapp-boost・テキストの可視性検証ありで 93 回・延べ 446 本回した。一覧は同フォルダの `ISSUES.md`・各セッションの所見は `ws/TestProjects/<proj>/EVAL_REPORT.md`・実行ログは `logs/run-*.log`)
- 観測: r2_e2ey_rn_ios の `type("#field_otp", "123456")`・`type("#field_title", "こんにちは")` が MCP でも run でも毎回 1 回打ち直し
- 測定(11/19 06:4x・Sim -07): 同じシナリオ(PIN と OTP・戻るの横取り)を inapp-boost・xcuitest の両モードで回し、打ち直しは 0 回(2/2 緑・注記なし)= 再現せず
- 次の一手: 再び出たら 1 回目の打鍵で何文字落ちたかを測る
- 検証の所要(11/26): 台帳の読みだけ(11/19 に再現せず)・約5分

### OI-297 全体のテストの並列の負荷の下でだけ赤になる単体テストが3つある(単独では緑)
- 状態: 再現済み
- 確認: 作業ツリー(2026-11-19)
- 属性: 低頻度
- 運用: 合否に響かない(単体テストだけ)
- 優先度: 低 — 全体テストの揺れ

- 観測(11/19): 全体テスト(22 並列)で1回「the FM process is still busy」・`["status", "retire"]` が `["status", "retire", "retire"]` に届かず赤。同じクラスを単独で3回回して 0/3(緑)。触った変更(MCP の linkText・XCUITest の木の照会・countIs の注記・原点の断り)は FM の常駐と関係しない
- 観測(11/18・ジョブ機能を入れた回): `ShellTimeoutTests`(pid ファイルを削除できない)・`FMServeAlignmentTests`(fm-serve に書けない)が単体テストの全体の並列でだけ赤、単独では緑。拡張の `webviewRunBoard.test.mjs`「アクション/秒メーター: run 0 本でも出て…」(300ms 待って段数と数値の連動を見る)が2回赤・回し直しで緑。どれもジョブの変更とは無関係
- 観測(11/20): 全体テストの2回目で `FMServeAlignmentTests.testNormalStartupRechecksIdentityBeforeReusingOrStartingAReplacement` が `["status"]` ≠ `["retire", "status"]`(退役の失敗の後に身元を読み直していない)で赤。1回目の全体は緑・単独で3回とも緑
- 観測(11/26): 48 本の CPU 負荷(`yes`)の下で `FMServeAlignmentTests` を 10 回回して 0/10(再現せず)。`ShellTimeoutTests` の pid ファイルの赤は原因を測って直した(孫が pid を書く前に 0.5 秒の締切が来ていた。同じ負荷で起動から書き込みまで最大 0.39 秒 → 締切を 3 秒に)
- 検証の所要(11/26): 負荷の下の 10 回(OI-250 と同じ回にまとめて)・約30分
- 次の一手: 全体テストで再び出たら、FMServeAlignmentTests は退役の照会の間隔とテストが待つ上限(`retirementWaitSeconds` の差し替え値)を並べて負荷の下で1周が上限を越えたかを、webviewRunBoard は 300ms の待ちの間に描き直しが何回走ったかを測る

## 環境側

### OI-315 E2EX-CMP の iOS(M4Max)で、検索バーの入力欄を空にできず赤(clearInput が「空にできない」/「成功と言ったが値が残る」)
- 状態: 再現済み
- 確認: b1707fd1c(2026-11-27。原因は観測済み = M4Max の macOS 26 で OCR が使えない)
- 属性: 環境側・据え置き
- 運用: 回避不可 — macOS 26 の機械(M4Max)では毎回赤。macOS 27 の機械では緑(DR-236)
- 優先度: 低 — 特定の機械だけ・赤になる側(誤った緑ではない)
- 原因(2026-11-27): M4Max の macOS は 26.7.3。この欄(Material 3 の SearchBar の iOS)の value は入力でなく説明文「検索候補は次のとおりです」(12 文字)なので、
  消去の確かめは欄の絵を OCR で読んで「何も描かれていない」ときだけ通す(`clear-residual-not-drawn`・利用者向けの注意点に記載)。OCR は macOS 27+
  でしか動かない(`OCRSupport`)ので、M4Max では毎回「判断できない = 赤」になる。失敗時の絵では欄は空(プレースホルダとカーソルだけ)。
  失敗文は「OCR is off for this run(設定で切った)」と言い違えていた → 「requires macOS 27+ and this Mac runs an older macOS」へ直した
- 決定(2026-11-27・DR-236): 今のまま(除外表に足さない)。M4Max が macOS 27 になれば赤が消えるので、そのとき閉じる

出典: 回帰(`Scripts/regress.py`)の 2026-11-18(`_work/regress-20261118/`)と 2026-11-20(`_work/regress-20261120/`)。どちらも M4Max の E2EX-CMP / ios-inapp-boost の2本(2026-11-19 の回帰では出ていない)
- 観測: ①`検索バーで検索できること.S0040` が「The driver returned an error (422): could not empty the field (12 character(s) still there after 4 round(s))」②`検索バーで検索できること.S0030` が「clearInput reported success but the value remained: "検索候補は次のとおりです"」。②の残った値は入力した文字ではなく、検索候補の読み上げの文に見える
- 次の一手: 失敗時の木(欄の value に何が入っているか・候補の窓が前面か)を M4Max で採る。他の機械で出ない理由(OS の版・負荷)を確かめる。原因を観測するまで直さない(MN-108)
- 回帰 11/21 08:01(`_work/regress-20261121/regress.log`・24 対象・全マシン): M4Max で再出(3回目)。`検索バーで検索できること.S0040` の `clearInput "#field_search"` と S0030 の `type "ap" (replace)` の 2 本
- 11/23 の全マシンの回帰: M4Max の E2EX-CMP(iOS・inapp-boost)「検索バーで検索できること」S0030・S0040 で同じ形(`could not empty the field (12 character(s) still there after 4 round(s))`・`clearInput reported success but the value remained`)
- xcuitest モードの全体の回帰(2026-11-26 夕・652aa2c): M4Max の E2EX-CMP で `clearInput "#field_search"` と `type "ap" (replace)` の赤(2本)= 同じ形が M4Max でだけ続いている
- 範囲を絞った回帰(2026-11-27 未明・b1707fd1c・iOS の inapp-boost 12 対象 + Android 4 対象): M4Max の E2EX-CMP で同じ2本が同じ形の赤(他の 15 対象は緑)

### OI-385 この Mac で E2EY の文中リンクのシナリオが 120 秒のハング×3 を1回だけ出した(マシンの再起動で消えた)
- 状態: 据え置き
- 確認: b7d8ff62e(2026-11-24・出たのは1回。再起動後は同じ反復が 21/21 緑)
- 属性: 環境側・低頻度・据え置き
- 運用: 再実行で吸収
- 優先度: 低 — 材料不足で据え置き(帰属を分ける測定ができていない)

観測: 2026-11-24、この Mac(M2Ultra)で E2EY の linkText のシナリオが3回連続で各 120 秒(コマンドの期限)までハング。HEAD(f02ca2006)での対照は緑 → main の再走は白紙の絵の赤1件だけ → マシンを再起動した後は同じシナリオの反復が 21/21 緑。直前まで長時間のレビュー・ビルド・E2E を回しており、環境の劣化の窓と判断した。当時のプロセス一覧・メモリ圧・GPU の状態は採っていない
- 次の一手: 再発したら、再起動する前に `ps`・`vm_stat`・`log show --last 10m` を採ってから回復する

### OI-234 iOS Simulator のワーカーの蘇生が、起動直後の遅さで始まる SpringBoard の起こし直しとブリッジの再起動の途中で、蘇生の枠(60 秒)に切られる(Duo-02 で 2 回中 2 回)
- 状態: 据え置き
- 確認: 35040589d(2026-11-15)
- 属性: 環境側・低頻度・据え置き
- 運用: 再実行で吸収 — そのデバイスは run から外れ、残りの台が続ける
- 優先度: 低 — 赤やデバイスの離脱になるが、誤った緑ではない

出典: `_work/explore-20261115a/duo/r1.log`(55周目 duo)。開いた iPhone Duo(iOS 27.2)-02 で SpringBoard / InputUI が落ちた後(OI-184)にワーカーが離脱。蘇生の2回とも「xcuitest bridge ready → 1要素の照会が 2.03s / 6.86s(普通は 0.3s 未満)→ SpringBoard を起こし直してブリッジを再起動」の途中で取り消され、「Could not revive the worker」になった。取り消したのは蘇生の枠(`ProfileWorkerFactory.buildWorker` の Simulator は 60s・任務グループの `cancelAll`)= 起動を待つ `BridgeLauncher.waitUntilReady` の `Task.checkCancellation`(観測済み: 取り消しの出どころはこの経路にこれだけ)
- 文言は 11/15 に直した(取り消しを「did not become ready in time」と言わない・枠が尽きた事実を `⏱ … reviving gave up after 60s` で言う)
- 測る口(11/15): 蘇生の記録の各行に、蘇生を始めてからの経過秒を前置した(`[revive +12.3s] …`。`ProfileWorkerFactory.reviveStamped`)。デバイスでは未通過(蘇生が起きていない)
- **原因(11/15 に観測)**: 手元の Duo 2 台で 55 周目の手順(開いた Duo で一覧の行・入力からホームへ出て閉じる)を回し、経過秒つきの蘇生の記録を採った(`_work/oi234`・`_work/oi234b`)。**60 秒の枠**の蘇生 2 回はどちらも「XCUITest ブリッジの起動 29〜38 秒 → 1 問の照会 2.03s / 2.04s で遅いと判断 → SpringBoard の起こし直し 3〜7 秒 → 2 回目の起動の途中で枠切れ」。**枠を 180 秒に広げた実験**(手元だけ・戻した)では、起動し直しの後も照会は 2.04s のまま(SpringBoard の起こし直しは simctl が 30 秒で終わらず失敗)= 起動し直しは効かない。4 回の蘇生のうち戻ったのは遅さが出なかった 1 回(+27s)だけで、残り 3 回はブリッジの起動だけで 80〜160 秒以上かかるか終わらなかった
- 判断(据え置き): SpringBoard の落ちが続いた Duo(OI-184)は端末そのものが使えない状態で、枠を広げても run が長く待つだけ。蘇生をあきらめて残りの台で続けるのが正しい振る舞い
- 見直す条件: Duo 以外の Simulator でも同じ蘇生の枠切れが出たら(記録の `[revive +N s]` で段ごとの所要を見る)
- 11/19: 蘇生の入口で SpringBoard の落ち続け・止まったままを判定し、その Simulator を止めてその run では蘇生しないようにした(DR-200)。止めた台は次の run の起動で戻ることを手元の Duo-01 で確かめた

### OI-233 Android の E2E-Android「連続ジェスチャ」で、1本指の `gesture` の後にパンが検出されない(`pan=-`・17 回中 1 回)
- 状態: 据え置き
- 確認: 80c658e07(2026-11-15)
- 属性: 環境側・低頻度・据え置き
- 運用: 再実行で吸収 — `gesture` は ✅ で、後続の `textIs("#txt_pan", "pan=right-down")` が赤
- 優先度: 低 — 赤になる(誤った緑ではない)

出典: `_work/oi216`(11/14)。回帰で手元の Pixel 10 Pro(Android 17)-03、全端末への配りで手元の -06 が赤(手元 6 台中 1・M1Ultra 6・M1Max 4・M4Max 1 は全部緑)。2回とも手元
- 原因は未観測。11/11 の Android ブリッジの払いの離し方の変更(2832db37a・v136)と経路が近いが、11/12 の回帰はその版で緑
- 測る口(11/15): E2EAppAndroid のマップ画面に `#txt_touch_trace`(`trace=m<MOVE の数> f<最初の MOVE の ms> lp<長押しが立った ms・- は立たず> s<パンの onScroll の回数> u<UP の ms>`)を足した。シナリオは検証せず、赤の回の要素一覧に残る。緑の回の値は `trace=m56 f19 lp- s37 u900`(手元の emulator-5554・scene 2 と同じ形)。手元の6台で「連続ジェスチャ」が緑
- **11/15 に再現**(`_work/oi218b`・手元の 6 台へ 6 周 broadcast・36 回中 3 回): 3 回とも `trace=m56 f24 lp400 s0 u900`(緑は `lp- s37`)= MOVE は全部届いたが、GestureDetector の長押しが 400ms で立ち、パンの onScroll が 1 回も来なかった。シナリオの指は「0.3 秒止める → 動かす」で、長押しの時間(400ms)との余裕は 100ms。ブリッジの gesture は基準時刻からの絶対時刻で刻む(`InputInjector.gesture`・保持は伸びない)ので、負荷の下で閾値を越える最初の MOVE がアプリに処理されるのが 400ms を過ぎた回に長押しへ入る(アプリの長押しのタイマーはツールから動かせない)
- **前提が崩れた(11/15)**: 保持を 0.15 秒(余裕 250ms)にしても 36 回中 1 回が同じ形(`trace=m46 f24 lp400 s0 u750`)で赤 = 余裕の幅では防げない。シナリオの変更は取り消した。残る説明は「アプリのメインスレッドが詰まった間に、長押しのタイマー(Handler)が入力より先に走った」で未測定
- **原因(11/15 に観測)**: 測る口に x(閾値を越えた最初の MOVE をアプリが処理した時刻)・a(事象の時刻から処理までの最大の遅れ)・h(メインスレッドの最大のフレーム間隔)を足し、使い捨ての測定シナリオで手元の 6 台へ 10 周(`_work/oi233`・60 回中 6 回が赤)。緑 54 回は x 340〜369ms・a 中央値 69ms・h 中央値 16ms。**赤 6 回は x 402〜597ms・a 106〜728ms・h 16〜116ms(中央値 33ms)** = 閾値を越える MOVE がアプリに届いたのが長押しの 400ms より後。メインスレッドはほとんど詰まっておらず、遅れたのは事象がアプリへ届くまで(ブリッジの注入か入力の配送)。予定(約 332ms)から 70ms 遅れるだけで長押しに入る
- 判断(据え置き): 負荷の下の入力の配送の遅れで、OI-221(iOS の並べ替え)と同じ型。ブリッジは事象の時刻を予定どおりに付けて撃つが、届くのが遅れるとアプリの長押しのタイマー(壁時計)が先に走り、ツールからは止められない。保持の余裕を広げても遅れ(最大 728ms)に負ける
- 見直す条件: 配信を止めた回帰・1 台ずつの実行でも出るようになったら。赤の回は要素一覧の `trace=` の x と a で同じ形かを見る
- 11/18 のフル E2E(配信あり)と手元 6 台への broadcast で各 1 回: `lp458 s0 x880 a643` / `lp403 s0 x588 a291` = 同じ形

### OI-221 E2EX-iOS(inapp-boost)の並べ替えで、長押しからのドラッグ(XCUITest へ回した gesture)が ✅ なのに順番が変わらない(8台同時で約 3 割)
- 状態: 据え置き
- 確認: 80c658e07(2026-11-15)
- 属性: 環境側・低頻度・据え置き
- 運用: 再実行で吸収(手元の 8 台へ同時に配ると 24 回中 8 回。回帰の分散では 1 台ずつなので稀)
- 優先度: 低 — 後続の検証が赤にする(誤った緑にはならない)

出典: `_work/regress-20261113`(11/13 の全体の回帰)。E2EX-iOS の「ドラッグで並べ替えられること」S0010 の `gesture("#reorder_row_1") { hold 0.8 秒 → 2 行ぶん下へ 1 秒 → hold 0.3 秒 }` が「fell back to XCUITest」で ✅ のあと、`textMatches("^order=2,")` が `order=1,2,3,4,5` のまま赤。HEAD と 2 日前の版で同じ率 = 退行ではない。赤の端末は毎回違う。11/13 の録画では全台で長押しは届いて行は持ち上がり、赤の回は移動が時間どおりに反映されなかった
- **11/15 に測った(SUT の測る口)**: E2EXAppIOS の並べ替え画面に `#txt_touch_trace`(ウィンドウに付けた受け身の認識器で、1本のタッチ列の移動の数・最初の移動・移動の最大の間隔・事象の時刻から処理までの最大の遅れ・メインスレッドの最大のフレーム間隔・離した/取り消された時刻。契約は `E2EXAppCMP/docs/ui-contract-wave2.md`)を足し、手元の 8 台へ 3 周 broadcast(`_work/oi221-trace`)。**緑 16 回は全部、最初の移動(817ms)の約 100ms 後にタッチ列が取り消された**(= UIKit のドラッグがタッチを引き取った・`c916`〜`c1129`)。**赤 8 回は2つの形**: ①`u2200`(4 回・1 周目)= ドラッグが最後まで始まらず移動 46〜58 個が普通のタッチのまま届いた。そのときメインスレッドのフレーム間隔が 162〜195ms(緑は 17〜95ms)②取り消しが遅い `c1170`〜`c1563`(4 回)= 移動の間隔が 249〜633ms 空いた。うち 2 回はフレーム間隔 17ms(アプリは詰まっていない = 移動の事象そのものが遅れて届いた)・1 回は事象の時刻から処理まで 1443ms
- 原因(11/15 に観測): 移動の事象が時間どおりにアプリへ届かない回に、UIKit のドラッグが始まらない
- 判断(据え置き): ドラッグの開始は UIKit がアプリの中で決め、合成の事象を撃つのは XCTest(testmanagerd)なので、ツールには事象の間隔もアプリのメインスレッドも制御できない。赤は後続の検証が出す(誤った緑ではない)。8 台の Simulator を同時に動かす負荷の下でだけ出る
- 11/19 の回帰(E2EX-iOS の 52 本を手元の 8 台へ同時に配った回)で 1 回: `trace=m12 f817 g150 l14 h166 c1153` = ②の型(移動が 12 個で取り消し・メインスレッドのフレーム間隔 166ms)。同じシナリオを1本ずつ3回回して 3/3 緑 = 見直す条件(1 台ずつでも出る)には当たらない
- 見直す条件: 1 台ずつの実行(回帰の分散)でも出るようになったら。測る口は SUT に残してあるので、赤の回の要素一覧の `trace=` で ①②のどちらかを見る

### OI-231 iOS Simulator で、アプリが OS のアクセシビリティの部品の中で SIGTRAP で落ちる(`AXBinaryMonitor` → `CFPrefs` の `_CFSetTSD`)
- 状態: 再現済み
- 確認: cacfc6f18(2026-11-14)
- 属性: 環境側・低頻度
- 運用: 再実行で吸収 — 落ちた後の手は「the target app … is not running」で赤(アプリの落ちはレポートの ⚠️ の行に出る)
- 優先度: 低 — 落ちたのはアプリでも fleetest でもなく OS の部品

出典: `_work/regress-20261113e`(11/13 の全マシンの回帰)。M1Max の E2EX-CMP / ios-xcuitest「時刻ピッカーで時刻を確定できること」S0020 で、`tap("#btn_time_cancel")` の直後の `select` が「Lost connection to the application」の 500 で赤。M1Max の落ちの報告 `iosApp-2026-11-13-190843.ips` の落ちたスレッドは `AXBinaryMonitor _processLoadedImagesMatchingName` → `CFPrefsPlistSource handleReply` → `_CFSetTSD.cold.1`(EXC_BREAKPOINT)= アプリのコードの枠が無い
- 同じ落ち方は手元(M2Ultra)の SpringBoard(`SpringBoard-2026-11-13-104503.ips`)と CalendarPosterExtension(`…-104854.000.ips`)にもある = アプリに依らない。M1Ultra・M4Max の報告には無い(11/14 時点)
- ツールの側で手を打つ材料は無い(落ちた後の撃ち直しは「届いたか分からない操作は撃ち直さない」で行わない)。頻度が上がったら Simulator のランタイムの入れ直しで減るかを測る

### OI-228 iOS Simulator で、Mac 側の Metal の中継(SimMetalHost の落ちの報告)が落ち、Flutter のアプリが SIGABRT で落ちる(手元・11/13 に 15 回)
- 状態: 再現済み
- 確認: 6887fda26(2026-11-13)
- 属性: 環境側・低頻度・据え置き
- 運用: 再実行で吸収(アプリの落ちとして赤になり、文言が落ちの報告を名指す)
- 優先度: 低 — ツールの外(Apple の Metal の中継)・報告は事実と合っている

出典: `_work/regress-20261113d`。手元(M2Ultra)の E2E-Flutter「アプリの外へ出ても戻ってこられること」S0010(`tapAppIcon` の後に前面へ来ない)と E2EX-Flutter「時刻ピッカーで時刻を確定できること」S0010(`tap("#nav_time")` でアプリが落ちる)が、どちらも Runner の落ちの報告 `EXC_CRASH SIGABRT / METAL: Connection to SimMetalHost … XPC service was lost`。同じ秒に `SimMetalHost-*.ips`(EXC_BAD_ACCESS・`MTLSimImplementation` の `MTLSimApplicationContext::newObjectCommand_DEPRECATED` / `newCommandQueueWithDescriptor`)。11/13 の DiagnosticReports に SimMetalHost の落ちが 15 件(12:01・12:03・17:22〜17:31・17:50〜17:52)。回し直しで前者は 8/8 緑・後者は 1/8 赤(その時刻帯にも SimMetalHost の落ち)。Mac のホストの GPU の中継の落ちで、ツールが起こせる・防げる経路は見つかっていない
- 次の一手: 頻度が上がる・他のマシンでも出るなら、そのときの Simulator の同時起動数と GPU の負荷を見る

### OI-214 E2EX-Flutter の iOS で、負荷の高いときにシートの文字の一部が描かれず exist が赤(判定は画面と合っている)
- 状態: 再現済み
- 確認: コミット未記録(2026-11-10)
- 属性: 環境側・低頻度
- 運用: 再実行で吸収 — 負荷の高い間の Flutter の iOS の Simulator
- 優先度: 低 — 判定は画面と合っている(誤った赤ではない)。困るのは、レーンが外されず同じ Simulator で次のシナリオも走ること

出典: `_work/regress-20261110a`(11/10)。全体の回帰で S0020、この Mac で回し直した回で S0010 が、シートを開いた直後の `exist("#txt_sheet_title")` で「[notRendered] … observed=""」(11 秒待っても同じ)。**失敗時の全画面の絵ではシートは開き切っているのに、見出し・3つのボタンの文字が無く、行は「シー」と一部の数字だけ**(TestProjects/E2EX-Flutter/reports/scenario-20261110-025615-203-*-scene1.png)= 文字の字形が部分的に描かれていない。アニメーションの途中ではない。判定(描かれていない)は画面と合っている。どちらも Android と同時に回した負荷の高い間で、モニターを止めた静かな状態の --broadcast(8台 × 3本)は 24/24 緑
- ツール側に残ること: 全部の文字が消えた画面は「文字消え」として検出しレーンを外して回し直す(`blank-and-textless`)が、**一部の字形だけが欠けた画面は検出しない**(この形はレーンが外れず、同じ Simulator で次も走る)。足すなら既存の資産に当てて誤検知 0 を確かめてから、警告から

### OI-184 iPhone Duo の開閉の後に SpringBoard が落ちる(FBSDisplayMode の assert)
- 状態: 再現済み
- 確認: コミット未記録(2026-11-06)
- 属性: 環境側
- 運用: ④再実行で吸収(iPhone Duo だけ・環境側)
- 優先度: 低 — Duo だけ

出典: `_work/explore-20261106j/findings-*.md`(26周目・11/6)。④iPhone Duo の `unfold` → `home` → `tapAppIcon()` が「Application com.apple.springboard is not running」の 500 で赤(duo F1・1/1。同じ秒に testmanagerd 等のクラッシュ)・開いた Duo の `home()` が「3 回押しても前面のまま」の 422(duo F2・1/1・-02 だけ)= 環境側。11/6 の .ips 32 件のうち SpringBoard 24 件・testmanagerd 6 件がすべて同じ箇所の EXC_BREAKPOINT(`-[FBSDisplayMode _initWithWidth:height:…validityCheck:]` の assert。表示の構成が変わった通知で作り直した表示モードが妥当性の検査に落ちる)で、落ちたのは 2 台の Duo だけ(report-mduo。開閉の最中の途中の表示モードを受け取る筋書きは推測)。ツールは検知と回復まで。次の手(候補): Duo の開閉の後の赤に直近の .ips を事実として添える・開閉の直後は SpringBoard の pid が変わらないことを確かめてから次を撃つ
- 43周目(11/9): DSL の `unfold()` の後に -01 の SpringBoard が1分に3回落ちた(duo F1 1/1・同じ FBSDisplayMode の EXC_BREAKPOINT。run はレーンを起こし直して緑・失敗文は「bridge up」を勧め SpringBoard を名指さない)。MCP の `ft_fold` の unfold の後は 40・41周目で計 3/3
- 同じ落ちで出た形(どれも Duo だけ・1〜2回): `unfold()` の直後の `fold()` が「devicectl reports 0 active built-in displays」で撃たずに赤・同時に in-app ブリッジが落ちてワーカーが2回離脱(21周目 duo F1・1/1)/ MCP の `ft_fold unfold` の後に誰も触らず畳んだ状態へ戻り揺れ続ける(25周目 duo F3・2/2。SpringBoard が 12〜20 秒おきに落ちて起き直す)/ 開いた Duo で `back()` の直後の `exist` が「Lost connection to the application」の 500(27周目 duo F1・2/2)/ MCP の `ft_launch` が「checking the simulator's SpringBoard」の段のまま 184 秒以上返らず、中継を止めた後も子の fleetest-mcp が残る・開いた Duo の `ft_snapshot` が「screen: 951x951 pt」と言う(28周目 duo F2・F3・各 1/1。個々の赤と落ちの時刻の対応は未確認)/ MCP の `ft_fold` の unfold の直後から SpringBoard が約 18 秒おきに落ち続け(FBSDisplayMode の初期化で SIGTRAP・9 件以上)、`ft_fold` は「Lost connection to the application」か「Unfolded.」と返し、続く `ft_snapshot` が 123.5 秒塞がる・`ft_status` / `ft_snapshot` は SpringBoard を名指さない(40周目 duo F1・41周目 duo F1 で -02 でも・計 3/3。DSL の unfold・fold・hinge では 0/1 = 落ちの起点の候補)
- 53周目の前(11/13): 開いた Duo で `hideKeyboard()` が注記なし 0.00 秒の ✅ のままキーボードが残った件(52周目 2/2)は、この落ちが原因と観測した —— 52周目は `hideKeyboard` の約 3.8 秒前(04:46:16)に両方の Duo で InputUI が同じ FBSDisplayMode の assert で落ちていた(Retired の .ips)= その瞬間はキーボードが本当に無く、in-app の木の「出ていない」は事実(後で InputUI が起き直して出直した)。11/13 に再現: `unfold()` の後に SpringBoard と InputUI が約 18 秒おきに落ち続け、アプリが背景に回って in-app ブリッジが 423(-02 で 1/1・-01 で 2/2・`unfold()` 無しの対照は 2/2 緑)。入力の無い unfold だけでも起きる。**直し**: シナリオの間にそのシミュレータの SpringBoard / InputUI の .ips が出ていたら、緑・赤どちらのレポートにも回数・時刻・報告ファイルを添える(`SimulatorCrashReport.systemCrashes`・Duo の -01 で 2/2 に出て、落ちなかった -02 には出ないことを確かめた)。利用者向けの注意点(navigation の fold)にも足した
- 11/19: 蘇生の入口で SpringBoard の落ち続け・止まったままを判定し、その Simulator を止めてその run では蘇生しないようにした(DR-200)。止めた台は次の run の起動で戻ることを手元の Duo-01 で確かめた
- 評価 6回目(11/21・`_work/scen-eval-20261121b/`): Duo の作成 4 セッションと本番の 5 run 全部で出た(Duo-01 は SpringBoard が止まったまま約 20 分戻らず、XCUITest ブリッジの起動が `the simulator's SpringBoard is not running` の時間切れ = OI-196 と同じ形)。開いた画面のシナリオが Duo の上で本番を最後まで走ったものは 0 本。供給で落ちた後に全部が別の台で対象外になる形は DR-214 で失敗にした
- 評価 7回目(11/22・`_work/scen-eval-20261122/`): 05:48 に FBSDisplayMode の SpringBoard の落ち 1 件(DiagnosticReports)・Duo の作成 6 セッションが全部この落ちに当たった
- 評価 8回目(11/23): 作成の 8 セッションで開いた後に SpringBoard が落ち続け、MCP では起こし直せず探索が止まった(duo_lk_rn・duo_swiftui はシナリオ 0 本)。本番の Duo -02 は供給で合流できず `no iOS device joined the run … Run stopped`(0 本の緑にはならない)。05:30 に手で止めた後の fd_* の本番は 13 回中 11 回緑。M1Ultra の Duo は開いた後に `devicectl reports 0 active built-in displays` で送らずに赤(19d06abd3 どおり)。手元の Duo -02 は run の中で `SpringBoard restarted 5 time(s) in 45s … shutting the simulator down` で切り離された
- 評価 11回目(11/24): 手元の Duo の本番の大半が落ち続けの区間で `423 … is in the background`・`no key window (409)`・`devicectl reports 0 active built-in displays` → 台の離脱 → `no usable workers`。duo2-19・duo2-21 は供給で SpringBoard が居らず0本(`Run stopped: no iOS device joined the run`)。同じプロジェクトを M1Ultra の Duo で回した run は全部緑。MCP の探索中に固まった fd_e2ey_swiftui は、注記が「Simulator の起動し直し」を勧めるが MCP に起動し直す道具が無く、探索が止まった

## 据え置き

### OI-379 iOS の in-app ブリッジの読むだけのハンドラの `mainSync` に上限が無い
- 状態: 据え置き
- 確認: 2026-11-25(コードで経路を読んだ。デバイスで未観測)
- 属性: 据え置き
- 運用: 合否に響かない — main が塞がった間は /status も同じ `mainSync` で待つので、上限を付けても受け付けの詰まりは変わらない
- 優先度: 低 — 観測例が無く、直しても詰まりの形が変わらない

- 据え置きの理由: 受け付けは単スレッドで、/status 自身が main で待つ(readiness の設計)ので、他のハンドラへ上限を付けても main が塞がっている間は新しい要求を受けられない。違いは呼び手が時間切れ(504/409)を受けるか自分の待ちで切れるかだけで、上限の数字の根拠(DR-4)が書けない。見直す条件: main が塞がっても /status だけは答える設計へ変えるとき、または読むハンドラの待ちで受け付けが塞がった観測が出たとき
- 経緯: ②(`/clear` の deleteBackward 経路でキャレットを末尾へ寄せる)・④(DOM type の読み返しで枠が同じ欄だけを比べる)は 307 で直した。③(Hybrid の長押しの ref 引き直し)は in-app の `/press` が常に 501 で、`HybridFallbackDriver.press(ref:)` を呼ぶ本番の経路が無い(シナリオ実行は StepExecutor がセレクタで引き直す・ライブ操作は座標・MCP の iOS は XCUITest)ため外した

### OI-370 リモートで回した run の失敗文のクラス名が、濁点の分かれた形(NFD)で出る
- 状態: 据え置き
- 確認: 07d7fc00a(2026-11-23)
- 属性: 据え置き
- 運用: 合否に響かない — fleetest の照合は Swift の比較(正準等価)で通る。出力を文字列で拾う側(スクリプト)だけが一致しない
- 優先度: 低 — 注記・文言だけ

出典: シナリオ作成の評価 9回目(2026-11-23 17:05〜20:30・`_work/scen-eval-20261123b/`。版 07d7fc00a = 0.24.0。作成 86 セッション・本番は手元・M1Max・M1Ultra・M4Max・iPad・Duo・SE3。一覧は同フォルダの `ISSUES.md`・作成の所見の要約は `digest-aa〜ae.md`・観測メモは `findings.md`)
- 観測: M1Ultra へのディスパッチで `Error: every scenario of スクラッチダーク確認 is a draft (@Draft)` の「ダ」が `タ` + 結合の濁点(e3 82 bf e3 82 99)。ソースのクラス名は NFC(e3 83 80)。評価のキットの `q2.sh` が名前の一致で外せず、同じ断りを8回繰り返した
- 原因(11/23・確認): Foundation の `Process` は引数を NFD に分解して子へ渡す(`Process` で `printf` に「ダ」(e3 83 80)を渡すと e3 82 bf e3 82 99 が返る)。リモートへの `ssh` も子なので、受け取った `--scenario` の名前を文言にそのまま出すと NFD になる
- 範囲(11/23・評価 9回目の結果 JSON 2,979 個・日本語の値 57,026 個): NFC でない値は `reportPath`(リモートから集めたレポートのパス)の 1,260 個だけで、シナリオの ID 等の識別子は全部 NFC
- 据え置きの理由: 照合は Swift の比較(正準等価)で通り、APFS も正規化を区別せずに開く = 合否・表示・ファイルを開く操作に響かない。響くのは出力をバイト列で比べるスクリプトだけ。見直す条件: 識別子(シナリオ ID・バリアント名)に NFD が混ざり、拡張などの文字列比較で取りこぼす実例が出たとき

### OI-235 OCR の近道が準備できていない回に FM が空の転写を返すと、確かめの OCR も「文字なし」を返し、描かれている文字が赤になる(E2EY-Android・11/15 の回帰で 1 回・11/22 の評価で 7 回)
- 状態: 再現済み
- 確認: 6e1dce9ec(2026-11-15)
- 属性: 据え置き・環境側
- 運用: 再実行で吸収 — 赤になる(誤った緑ではない)
- 優先度: 中 — 読める文字が赤になり、普通の書き方では避けられない

出典: `_work/vis-pipeline/regress.log`(11/15 の全マシンの回帰)。E2EY-Android「反転チャットを扱えること」S0040 の `textIs("#msg_60" == "着信 60")` が「FM transcribed nothing, but the element's area is not blank (luminance stdDev 20.9); OCR found no text there」で赤。手元の Pixel 10 Pro(Android 17)-04。注記は `fm-empty-transcript-on-ink`・`ocr-shortcut-not-ready`、`ocrMs` 679。切り抜き(`~/Library/Logs/fleetest/occlusion/occlusion-2026-11-15T05-34-42.701Z.png`)には「着信 60」がはっきり写り、失敗の時点の木にも `msg_60` がある
- 通った経路(コードで確認): V16 の近道は準備ができておらず撃たず → FM が空の転写 → V21 の確かめの OCR(`RegionText.resolveWithinBudget`)が行を返さず → `awaitReadableVision()` が読み直しを許さず → FM の訊き直しも可視と言わず → 赤。V21 の処理は可視性検証の組み替え(ec4eeae58)の前後で同じ
- 頻度: 結果 JSON の集計で、`fm-empty-transcript-on-ink` の付いた赤は 10/18〜11/15 に 123 件(10/18〜10/23 に多く、11 月は 1〜5 件/日)。`ocr-shortcut-not-ready` を伴う回は 11/9・11/10 の E2E-RN・E2EX-RN・E2EX-Flutter にもある。起き方の型は MN-92.1・MN-84.4
- 測る口(11/15): 確かめの読みが空だった回の失敗文に、読み直したか・読み直さなかった理由を足した(`RegionText.ReadableVisionWait` を `StepExecutor.visionWaitFact` が写す。`(read again once Vision was ready)` = 読める Vision でも空 / `(not read again: … an earlier wait in this run had already timed out)` = このプロセスの前の待ちで尽きていた / `(not read again: Vision was still not ready after waiting 10.0 seconds)` = この回に待ち切った / `(not read again: Vision's readiness could not be checked)`)。デバイスでは未通過(この赤が起きていない)
- 再現の試み(11/15): M1Ultra の 6 台へ「反転チャットを扱えること」を 4 周 broadcast(96 回)で全部緑 = 再現せず(`_work/oi235`)
- **原因(11/15 の回帰で観測)**: 測る口が出した理由は `(not read again: Vision was not ready, and an earlier wait in this run had already timed out)`(手元の E2E-CMP の Android「WebViewの中身を操作できること」S0010・Pixel 10 Pro -03・`_work/regress-20261115d`)。そのステップの OCR の所要は 10,661ms = Vision が読めるまでの待ち(上限 10 秒)をこのステップの中で使い切り、判定の取り直しで 2 回目に通ったときは尽きていた。切り抜きには `wv_result=-` がはっきり写っている = **はっきり描かれた文字を、同じプロセスの Vision(10 秒探っても空)と FM(空の転写)が同時に読めなかった**。手元の負荷が高く、エミュレータの白紙・固まりが多発していた時間帯(同じ回帰で手元の Android 16 台ぶんが外れた)
- 判断(据え置き): 読み手が 2 つとも読めないとツールには文字が見えていると確かめられない(赤が正しい)。待ちの上限(10 秒)を延ばすと、Vision が長く読めない機械で失敗のたびに 10 秒以上を払う
- 見直す条件: 負荷の低い機械・時間帯でも同じ理由の赤が出たら
- 評価 7回目(11/22・`_work/scen-eval-20261122/`): **同じ形が 7 回**(lk2_e2e_cmp の --broadcast 手元 Sim 6/12・r5_e2ey_cmp_emu 1)。切り抜きは「E2E ホーム」等が鮮明・注記 `fm-empty-transcript-on-ink` と `ocr-shortcut-not-ready`・`ocrMs` 11,147(Vision の準備待ちを使い切った)・FM は4回呼んで失敗0 = 空の転写を返した。同じ run の M1Ultra は 4/4 緑。11 の作成セッションが並行する負荷の下 → 要測定へ戻す。次の一手: 残った切り抜き(`~/Library/Logs/fleetest/occlusion/`)を FM の常駐プロセスへ負荷なしで渡し直して空の転写が再現するかを測る(再現しなければ負荷の下の FM の取りこぼし)
- **測定(11/22 08:2x・`Scripts/occlusion-repro.swift` で本番と同じ指示・負荷なし)**: lk2_e2e_cmp の切り抜き6枚は 18/18 で「E2E ホーム」と転写した = 本番の空の転写は負荷の下の FM の取りこぼし。r5_e2ey_cmp_emu の「再生中: トラック 1」の1枚は負荷なしでも 3/3 空 = この絵は FM が決定的に読まない。本番の失敗文はどれも `OCR found no text there (not read again: Vision was not ready, and an earlier wait in this run had already timed out)` = 確かめの OCR は、同じ run で前に Vision の待ちが時間切れになったので待たずに諦めた(その後の FM の訊き直しも空)
- **訂正(11/22 11:0x・結果 JSON の段ごとの所要)**: lk2 の赤のステップ(S0020 の 17 本目 `exist "#txt_home_marker"`)は `ocrMs` 11,147 で、前のステップの `ocrMs` はどれも 0 = **Vision の待ち(10 秒)はこのステップの中で使い切り**、失敗文の「earlier wait」は同じステップの評価のやり直しで出ていた(11/15 の回帰の形と同じ)。前のステップからの持ち越しではないので、ステップごとに待ち直しても救えない。失敗文はこの2つを分けて言うよう直した(`StepExecutor.visionWaitFact` の `ranOutEarlierThisStep`。`(… this step had already waited 10.0 seconds for it)` / `(… a wait in an earlier step of this scenario had already timed out)`)
- 原因(観測): 負荷の下で、FM の空の転写と、10 秒探っても空を返す Vision が同じステップで重なった。ツールは設計どおり赤にしている(黙った緑ではない)
- 決定(11/22・DR-216): ①今のまま赤。待ちの上限は延ばさず、両方の読み手が読めない回を判定不能の緑にもしない。見直す条件は DR-216
- 評価 8回目(11/23): 本番で同じ形が 4 回(dc_rn_ios の手元 Sim -08・ip_va_cmp の手元 iPad Air 13 で 2 回・r2_e2ey_cmp_4a の手元 Emu)。切り抜きはどれも文字が鮮明。マシンの Vision は alive・ホストの負荷 25〜40(13 の作成セッションが並行)。DR-216 の見直す条件(負荷の低い機械・時間帯)には当たらない
- 関連の直し(2026-11-25 夜): OCR が等倍で0行のときだけ、文字の領域の検出で文字の矩形から切り直して1回読むようにした(`RegionText.readTextRegion`)。保存してある切り出し 553 枚で等倍0行の 368 枚のうち 5 枚(描かれた文字)がこれで読めた。この項目の「確かめの OCR も文字なし」の回のうち、文字が鮮明な切り出しに効く見込み(この項目の回の切り出しでは未確認)。見直す条件は変えない

### OI-282 注記の誤誘導の残り(OTP の装飾ボックスの重なりに「may have hit」・⑧の文言が両方の可能性を言う)
- 状態: 再現済み
- 確認: 657e032d1(2026-11-19)
- 属性: 据え置き
- 運用: 合否に響かない(注記)
- 優先度: 低 — 注記の文言だけ

出典: シナリオ作成の評価 2回目(2026-11-18・`_work/scen-eval-20261118b/`。一覧は同フォルダの `ISSUES.md`・各セッションの所見は `ws/TestProjects/<proj>/EVAL_REPORT.md`)
- ① `ft_type` の読み返しが CMP の iOS の反映の遅れを「the field did not show the typed text … taken as the app consuming the input」と断定(sutstore_ios(pressEnter あり)・e2e_cmp_ios5(なし)。直後の ft_snapshot では値が入っている)
- ② 「NN% of the screen has no element … a modal, sheet or menu may have replaced it」がモーダルの無い短い画面で出る(sutstore_and のログイン 47%・r3_e2ex_flutter_ios のメニュー等 60%。88154bc65 で下端だけ空いた全幅の形は弱めた = 別の形)
- ③ 「貼り付く見出し(sticky header)」の警告が、行の中のチェック円 `#circle` や OTP の装飾ボックス `#otp_box_1` を「見出し」と名指す(r3_e2ey_ios_sim)/ OTP の装飾ボックスの重なりに「may have hit #otp_box_1 instead」(3件・入力は通る)
- ④ OTP の隠し入力欄への selector なし `type` に「left input focus nowhere … the text may have gone nowhere」(r2_e2ey_cmp_4a。1回目の評価で直した隠し入力欄の焦点の警告の別の形・入力は通る)
- ⑤ `waitForChange` が内容の同じ木でも「the tree differs」(spec_ios)/ 読み返しに出所不明の既存値「the field already held "^_^"」(notes_se3)
- 測定(11/19 1:1x・Sim -05・SUT Store の検索欄): ①は pressEnter 無し・あり の2回とも読み返しは正常(「Typed: …」だけ)= 再現せず。②〜⑤は注記の文言だけで合否に響かないので測っていない
- 3回目の評価(11/19・`_work/scen-eval-20261119/`): ①④⑤は出ず。②はまだ出る(phys_and_3a 50〜77%・e2ey_cmp_3a / r3_e2ey_cmp_3a の PIN 画面 36%・e2ex_flutter_emu 61%)。③はまだ出る(「under the sticky header」が `#circle`・`#otp_box_1`・同じ段落の続きの文・商品名の staticText を名指す 5 件 / OTP の「may have hit #otp_box_1」3 件)。新しい形: ⑥「#pad_swipe is still empty after a short re-read wait — it may be genuinely empty, or still loading」が本文を持つ scrollView・子を持たない設計のジェスチャ板に出る(r3_e2e_flutter_ios・e2e_flutter_en)⑦snapshotAfter の即時の木に別ウィンドウのモーダル・アニメーション中のシートが出ていないのに、注記は「a dynamic list … may not have populated yet」(e2e_ios_sim・r6_e2ey_flutter_ios)⑧遅れて届く更新(着信)に「the action may not have changed the screen」(3 件)
- 次の一手: ①が再び出たら、読み返しの時刻と値が入る時刻の差を測る ②は2画面の木の形を並べ、短い画面とモーダルを見分ける材料があるか ③④は装飾の重なりの形をコーパスで数える ⑤は再現を取る ②⑦は直した(②モーダルの形は左の余白で見る・⑦初回の注記に開きかけのシートと別ウィンドウを足した)。⑧は文言が「変わらなかった」と「窓がまだ木に来ていない」の両方を言っており据え置き。残るのは③と⑥
- ⑥の測定(11/19): 注記は画面の 3 割以上の高さのスクロール可能な要素に depth の子が無いと出す(`emptyLoadingScroller`)。Flutter は中身を容器の子でなく兄弟として返す(r3_e2e_flutter_ios・e2e_flutter_en の木で、容器の枠の中に中身が同じ depth で並ぶ)。「容器の枠の中に中心がある要素があれば空と言わない」で直すと、固定コーパスの真陽性 2 件(`ios-messages_keyboard` = 新規会話の空の一覧の枠の中にナビバー・入力欄が重なる / `and-maps_transit_results`)も消える = 反例を見分けられないので直さなかった。次の一手: Flutter の兄弟と、重なった別部品(ナビバー等)を depth・木の順で見分けられるかを、Flutter の木(depth 付き)と2件で比べる
- 4回目の評価(11/19・`_work/scen-eval-20261119b/`): ③はまだ出る(7 セッション。e2ey_ios5 は注記を鵜呑みにして先頭の行を避けるようにシナリオを変えた)。⑥もまだ出る(Flutter の PIN 画面・日付ピッカー・ジェスチャ板。6 セッション)。②の「モーダルかも」は全部本物のモーダルの場面だった(直しは効いている)
- 11/19 夜: ⑥を直した(`MCPServer.emptyLoadingScroller` に「枠の中に中心のある小さな要素があれば空と言わない」を足した。固定コーパスで発火していた2件 = 器が空のまま中身が兄弟で描かれる誤検知が消えた。**本当に読み込み中の形の witness はコーパスに無い**ので、検知がまだ実画面で発火するかは未確認)。残るのは③(装飾の重なりの形をコーパスで数える)
- ③の測定(11/19 夜・固定コーパス 53 画面の全要素に `pinnedBandCovering` を当てた): **94 件発火し、ほぼ全部が貼り付く見出しではない**(設定の行の題名が同じ行の説明文を覆う・天気の日付の文字片どうし・地図の候補の行の題名が行のボタンを覆う 等 = 同じ行の中の兄弟)。94 件中 89 件は容器が申告の無い推定(`clippingContainer(inferring: true)` が行そのものを容器と読み、行の上端の題名を「容器の上端に貼り付いた帯」と読む)。witness(E2EX-RN・Flutter の sticky の単体テストの木)はどちらも容器が scrollable を申告している。**直しの候補**: MCP の注記(`pinnedBandNote`)は申告された容器のときだけ出す。**未確認なのは反例側** —— scrollable を申告しない CMP iOS(XCUITest)の sticky で witness を落とさないか。反例側を測った(11/19 夜・E2EX-CMP の iOS Simulator・XCUITest の木): 申告された容器は画面全体の `scrollView`(0,0 402x874)だけで、貼り付いた `#hdr_A` は y=182 = 容器の縁に揃わない。**申告された容器に限ると CMP iOS の本物の貼り付く見出しを見逃す**ので、申告だけでは誤検知と witness を見分けられない(MN-108)。**決めてほしいこと**: (a) 注記だけの見逃しとして CMP iOS を諦めて申告された容器に限る (b) 推定の容器でも、帯が行の兄弟(同じ行の中の題名)でないことを別の材料で見分ける形を探す(材料は未発見)(c) 据え置き
- 11/19 深夜(ユーザー決定「おすすめで」= (a)): MCP の貼り付く見出しの注記(`TapTargetGeometry.pinnedBandNote`)を、容器が scrollable を申告した要素の枠のときだけ出すようにした。固定コーパスの発火は 94 → 5 件(`PinnedBandNoteCorpusTests` が上限 5 で固定)。代償として CMP iOS の本物の貼り付く見出しには注記を出さない。DSL の撃つ前の送りは変えていない。**残りは据え置き**: OTP の装飾の重なりの「may have hit #otp_box_1」(入力は通る・注記だけ)と⑧(文言が両方の可能性を言っている)

### OI-298 inapp-boost の `swipeBy(dxRatio: -0.6)` が CMP の iOS で行を払い切り、削除を確定させる(作成時の XCUITest では途中で止まる。flick も同じ型)
- 状態: 再現済み
- 確認: 作業ツリー(91c8c035e + RR-8.3 の実装。2026-11-19)
- 属性: 据え置き
- 運用: 回避可 — 本番と同じモードで確かめ、ボタンを出すだけなら flick ではなく小さめの比率の swipeBy(docs の gestures の注意点・known_caveats に記載)
- 優先度: 高 — 誤った操作

出典: シナリオ作成の評価 4回目(2026-11-19・`_work/scen-eval-20261119b/`。67 セッション・本番 98 回・延べ 482 本・緑 442。一覧は同フォルダの `ISSUES.md`・各セッションの所見は `ws/TestProjects/<proj>/EVAL_REPORT.md`・本番のログは `logs/run-*.log`)
- r9_e2ey_cmp_ios(E2EY-CMP の途中まで払うスワイプ)の `swipeBy("#sw_row_1", dxRatio: -0.6, dyRatio: 0)`: 本番(inapp-boost)で手元 Sim -08/-09 と M1Max の 2 回 × 2 本 = 4 本とも赤。失敗時の木で払った行そのものが消え、エコーは `action=row1:delete`・`rows=5`(全部払ったときの動作)。swipeBy は ✅ と報告した。作成時の XCUITest(`ft_run_scenario`)では緑
- 原因: 結果(削除が確定)は観測・機構は未観測(in-app の `/drag` が速さで決まる部品にどう効いたか = 終点・速さ・指を離す瞬間)
- 次の一手: in-app の /drag で払った速さと距離を XCUITest の払いと並べて測る(「終点で止める」案は inapp-drag-selfrendered の決定で不採用)
- **測定(11/19 21:0x・手元 Sim -08/-09・同じ swipeBy の比率だけ変え、払った 2 秒後の結果)**: inapp-boost は `-0.3`・`-0.4` でボタンが出て止まり、`-0.5`・`-0.6` で `action=row1:delete`(削除まで走る)。xcuitest は 4 つとも止まる。行は Compose の `AnchoredDraggable`(Closed / Actions = -160dp / Full = -行幅)で、Actions を越えて離したとき離す速さが閾値を越えれば Full へ走る。in-app の /drag は位置も速さも届け、XCUITest の合成は最後の移動が離す操作と同着になり Compose が捨てる(inapp-drag-selfrendered の 10/22 の測定と同じ)= **人の指に近いのは in-app 側**。作成時の確認(MCP は iOS で常に XCUITest)だけが止まって見え、AI は `-0.6` を「途中まで」と書いた
- 決定: in-app の /drag を終点で止める直しは不採用の決定どおり(速さで決まる部品を壊す)。docs(gestures の注意点・known_caveats)に「離す速さで結果が変わる部品はモードで割れる・本番と同じモードで確かめる・ボタンだけなら小さめの比率」を足した。スキルの「完了の前に本番と同じ経路で回す」(DR-196)が効く形(評価は `ft_start_run` を禁じた構成)
- 評価 5回目(11/21・`_work/scen-eval-20261121/`): e2ey_flutter_ios(Flutter の iOS・作成時の XCUITest)で、`swipeBy` の大きい比率が Dismissible を削除まで走らせ、snapshotAfter は行のボタンが並んだ中間の状態を返した(シナリオでも `exist "#btn_sw_archive_1"` が赤・既に action=row1:delete)
- 評価 9回目(11/23 夜・`_work/scen-eval-20261123b/`): e2ey_cmp_ios の `flickRightToLeft(scrollFrame: "スワイプ行 1")` が本番(inapp-boost)で M1Max 2回・手元 Sim -08 1回とも、続く `exist "#btn_sw_delete_1"` は ✅・`tap "#btn_sw_delete_1"` が「見つからない」の赤。失敗時の木は `action=row1:delete`・`rows=5` = 払いが削除まで走り、`exist` は消えていく行のボタンを読んだ(払った後に「スワイプ行 1」が木に無いことも測定で確認)。作成時の MCP(XCUITest)はボタンで止まって緑。flick(速い払い)でも同じ型。docs の「途中までのスワイプ」と「スワイプで削除」を相互に参照させ、速い払いは削除まで走りうると書いた

### OI-291 scrollFrame の枠の外にある固定要素を探すと、最初の読みで枠の外と分かっていても払い切る
- 状態: 再現済み
- 確認: 657e032d1(2026-11-19)
- 属性: 据え置き
- 運用: 回避可
- 優先度: 低 — 時間の損だけ(①の scrollFrame に行を渡した形は直した = 行を収める容器を払う)

出典: シナリオ作成の評価 3回目(2026-11-19・`_work/scen-eval-20261119/`。AI のセッション 65 本が作った 332 本を、作成と別の端末で本番の経路 = `fleetest run`・inapp-boost・テキストの可視性検証ありで 93 回・延べ 446 本回した。一覧は同フォルダの `ISSUES.md`・各セッションの所見は `ws/TestProjects/<proj>/EVAL_REPORT.md`・実行ログは `logs/run-*.log`)
- ① r3_e2ex_cmp_4a: `ft_scroll_to(selector: "#nav_search", scrollFrame: "#nav_pager")`(一覧の先頭の項目 = 容器でない)が 66px 動いた後「nothing moved at all during the search … raising maxSwipes will not help」で端扱い。AI は一覧が 6 項目だと誤認しかけた(容器は id の無い `other scroll`)
- ② r2_e2ey_cmp_ios: スクロール枠の外の固定要素 `#txt_staggered_result` を `scrollFrame: "#grid_staggered"` で探すと、round 0 で「only outside scrollFrame (16,134 110x24)」と分かっているのに 8 払い+逆 8 で 34.8 秒
- 測定(11/19 06:3x・4a・縦・MCP): 同じ `ft_scroll_to(selector: "#nav_search", scrollFrame: "#nav_pager")` は 2 払いで届いた。1 回目の払いの後、scrollFrame に渡した `#nav_pager` 自身が中身と一緒に送られて `(0,246 1080x68)`(容器 `other scroll (0,312 …)` の上端をまたぐ 68px の帯)になっていた = **scrollFrame に渡した行は中身と一緒に動くので、払う場所が払うたびに細く・画面の外へずれる**。対象が遠いと次の払いが細い帯の中になり「nothing moved」へ落ちる(①の原因)
- 据え置きの理由: 同じ id の要素が後から枠の中に現れうるので、枠の外に見えたことで打ち切らない。症状が実害(誤った結論)になったら見直す
- 評価 5回目(11/21・`_work/scen-eval-20261121/`): mix_cmp_emu。固定のヘッダの `#btn_scroll_top` に `scrollFrame: "#list_rows"` を付けた `ft_scroll_to` が `round 0: only outside scrollFrame (48,516 272x144)` を出した後、8 払い + 逆向き 8 ドラッグ = 35 秒探して失敗

### OI-256 ランナー機の上で、そのランナー機に固定した実行プロファイルを `--device-machine <自分の名前>` で回すと、自分自身へ ssh しようとして落ちる
- 状態: 再現済み
- 確認: 2026-11-17
- 属性: 据え置き
- 運用: 回避可 — 手元から `--runner <機>` でディスパッチする
- 優先度: 低 — ランナー機で直接 fleetest を起こす保守者の迂回の経路だけ

出典: 61周目 phys F1(M1Ultra のランナーのクローンで `ios-iphone13` を回した・2/2)。`--runner local` だけでは「pass --device/--device-machine explicitly」と断られ、その案内どおり `--device-machine M1Ultra` を付けると「Could not resolve hostname m1ultra」で落ちて ran=0(従えない案内)。ランナー機が自分の名前を自分と判定しない理由はコードで確かめていない(原因は材料不足)
- 原因(11/17・コードと M1Ultra の登録簿で確かめた): ランナー機の登録簿は自分(`local`)しか持たず、「M1Ultra」のようなマシン名はディスパッチする側だけの概念(ユーザー決定・`FTCore.RunnerProfileView`)。手元から `--runner M1Ultra` で送る通常の経路は、プロファイルを「そのランナーから見た姿」へ畳み(`RunnerProfileTransfer`)、`--device-machine` も常に `local` で渡す(`RemoteRunArgs.build`)。ランナーのクローンの fleetest を直接起こす迂回(探索の手引きの代替)だけが畳まれていない生のプロファイルを読み、自分に固定されたデバイスを別のマシンと見なして、その名前へ ssh する。利用者の経路では起きないので据え置き。欠陥は、この迂回の経路で出る「--device-machine を付けよ」の案内がランナー機の上では従えないことだけ

### OI-253 横向きの iPad の WebView 画面で、欄へ type した後の `tap("送信")` と `hideKeyboard()` が赤(iPad Air・iPad Pro)
- 状態: 再現済み
- 確認: 2026-11-17
- 属性: 据え置き
- 運用: 回避可 — 縦向きで書く
- 優先度: 低 — 横向きの iPad の WebView だけ

出典: 60周目 ipad F1(iPad Air だけ 2/2・同じ run の iPad Pro は「nudged」で緑)・F2(両機 2/2)。キーボードでタブバーが押し上がり、送信が WebView の見える範囲の外に出て木から外れた。閉じようとしたタップ (73, 78) は「戻る」ボタンの 1pt 隣。hideKeyboard は背景のタップも Enter も効かず、iPad のキーボードの閉じるキーは使わない
- 測った(11/17・iPad Air の Simulator・横向き 1180x820): WebView の見える範囲は (0,126 1180x210) で下端 336、「送信」(16,339) はその 3pt 下 = 見える範囲の外(XCUITest の木では ⚠️scroll-leftover)。Pro は寸法が違い端に残ったので寄せて押せた(Air だけ赤の差はこの 3pt)。キーボードを閉じれば WebView が伸びて届くが、WKWebView の欄は外側のタップでも Enter でも焦点を失わず閉じない(DSL で両機 2/2)。iPad のキーボードの右下に閉じるキーがあるが、XCUITest ブリッジはキーボードの部分木をキーごと木から落とす(`BridgeRouter+Snapshot.gather`)= 押す口が無い
- 直した(11/17): 閉じるタップの点が戻るボタンの当たり判定の余白(枠の 1pt 右・12pt 下で戻るが押されホームへ遷移 = MCP の ft_hide_keyboard で再現)に落ちていた → ボタン類(`KeyboardDismissPoint.slopControlTypes`)の周りの余白(`controlHitSlop`)の外の空きを先に選び、無ければ OS の入力補助バーの Done、それも無ければ余白の中の空き、最後に Enter。点は (172,78) へ移り画面は変わらない
- 決定(11/17 ユーザー・DR-187): 据え置き。iPad のキーボードの閉じるキーを押す口はブリッジに足さない(版上げ・全端末のランナーの作り直し・キーの見分け方の実測に対し、影響は横向きの iPad の WebView だけで縦向きで避けられる)。見直すのは横向きの iPad の WebView の利用者から要望が出たとき

### OI-255 iOS の文字の子を持たない行の OCR だけの判定で、字形の紛らわしい文字が並ぶ行("Il1o0O")を Vision が1文字少なく読み("11000")、描かれた行への `exist` が赤
- 状態: 再現済み
- 確認: 2026-11-17
- 属性: 据え置き
- 運用: 回避可 — 字形の紛らわしい文字だけの並びを検証の値に使わない
- 優先度: 低 — 探索で作った文字列だけ

出典: 61周目 imax F1(M1Max の iPhone 18 Pro × 4・E2EY-iOS の反転チャットに送った行・4/4 赤)。902e88129・9989e8c47 の許容は同じ位置の文字の取り違え(同じ長さ)だけで、文字の欠けは許さない。欠けまで許すと別の行・別の値を緑にする側に倒れるので、直していない(材料: Vision の上位候補は1つしか返らない)

### OI-236 Android の E2EY-CMP で、launch が「the app never came to the foreground」(500)で赤になるのに、失敗時の画面ではアプリが前面に居る(M1Max・1 run で 2 本 × 2 回)
- 状態: 再現済み
- 確認: 2026-11-16
- 属性: 据え置き・低頻度
- 運用: 再実行で吸収 — 最初の launch で赤(後続は実行されない)
- 優先度: 低 — 赤になる(誤った緑ではない)

出典: `_work/regress-20261115c`(11/15 の全マシンの回帰)。M1Max の E2EY-CMP の Android で、-02(「スワイプの距離で結果が変わること」S0030)と -04(「シートが畳まれていても背面を操作できること」S0020)の `launch` が `The driver returned an error (500): the app never came to the foreground: com.ftester.e2ey`。同じ形が 11/10 の M1Max の E2EY-CMP にも 2 本(run 20261110-193808Z-442999f0)。手元・M1Ultra・M4Max の結果には無い
- 観測: -02 の失敗の記録の画面はアプリのホーム(機能の一覧)= 証跡を撮った時点では前面に居た。回帰の後に 2 台を見ると、起きていて前面はアプリ・ロックは無効(MN-63.1 のロック画面の形ではない)。文言に systemui の説明が無い = `BridgeRouter.handleLaunch` の最後の経路(前面の居座りを止めて 1 回だけ起動し直し、それでも前面に来ない)を通った
- 測る口(11/15・Android ブリッジ v143): 最後の経路の失敗文に、再試行の前に前面に居たパッケージ・止めたか・再試行の後に前面に居たパッケージ・launch 全体の所要を載せた(`BridgeRouter.handleLaunch`)。再現の試み: M1Max の 4 台へ過去に落ちた 4 クラスを 5 周 broadcast(260 回)と、11/15 の全マシンの回帰(E2EY-CMP の Android は手元)で起きず
- 測った(11/16): M1Max の Pixel 10 Pro 4台へ過去に落ちた 4 クラス 10 シナリオを 8 run broadcast(launch 320 回)で 320/320 緑。前回の 260 回と合わせて 580 回で 0 件 = 原因を測る材料が採れないので据え置く
- 次の一手: 次にこの赤が出たら括弧の中(前面に居たもの・所要)を見て、前面待ちが期限に負けたのか、別のものが前面に居たのかを分ける

### OI-225 実機の iOS(inapp-boost)で、合成タッチに、表示が変わったのに「the screen looked the same when it settled」と注記する(WebView の DOM 要素・UIKit の入力欄・SwiftUI の行)
- 状態: 再現済み
- 確認: 4563640be(2026-11-13)
- 属性: 据え置き
- 運用: 合否に響かない(注記だけ・判定は緑で正しい)
- 優先度: 低 — 注記は「整定した時点で同じに見えた」でぼかしてあり、事実と食い違わない

出典: `_work/explore-20261113c/findings-phys.md`(54周目 phys F1)。iPhone SE3(実機)の E2E-iOS の WebView 画面で、リンク・送信・アリアラベル・変形・固定の5つのボタンへの tap の全部に「activate did not fire -> synthetic touch …; the screen looked the same when it settled after the synthetic touch」(1 run 中 5/5)。直後の `textIs("wv_result=*")` は5つとも緑 = DOM の表示は変わっていた。Simulator の同じシナリオの最近 14 本では 0〜2 件/本。注記は in-app ブリッジの `pixelPrint`(`drawHierarchy(afterScreenUpdates: false)`)の前後一致で出るが、WKWebView の描画が写らないのか、JS の反映が整定より後なのかは確かめていない = 材料不足。同じ SE3 で `tap("#field_single")` にも同じ注記(キーボードが出たかは見ていない)
- 11/13 に測定(SE3・1/1 で再現): in-app の絵(`/screenshot` = `drawHierarchy`。注記の比べと同じ撮り方)は WebView の中身を写す —— タップの前は `wv_result=-`、タップのステップが返った直後の絵は `wv_result=link`、1.5 秒後も同じ。= 「撮り方に写らない」は否定。注記はブリッジの中で合成タッチの直後の整定(メインスレッド)の終わりに比べるので、別のプロセスの WebContent の描画が整定より後に来た(直後の撮影には間に合う)= 間合いの問題
- 2026-11-15(55周目の補い phys F1・SE3・7/7): WebView 以外でも出る —— `tap("#field_single")`(UIKit の欄。直後の `keyboardIsShown` が緑 = キーボードが出た)と `tap("#row_30")`(直後の `textIs("#txt_row_selected", "selected=row_30")` が緑 = 同じプロセスの SwiftUI の文字が変わった)の両方に同じ注記。対照: アラートのボタン `#btn_dialog_ok` の合成タッチには付かない。「別プロセスの WebContent の描画が遅れる」では SwiftUI の行を説明できない。キーボードはアプリの窓の外なので `drawHierarchy` に写らない、SwiftUI の更新が整定より後の描画で入る、はどちらも推測 = 材料不足。次の一手(測る口): 注記を出した回に、比べた前後の指紋と、整定の後さらに1フレーム待って撮った指紋を注記の材料として返す(ブリッジの版上げが要る)。Simulator では同じ画面でこの注記がほぼ出ないので、実機だけの間合いかを見分けられる
- 据え置きの理由: 注記の文は「整定した時点で同じに見えた」+「後から反応する処理(RN の onPress 等)はまだ動きうる」で、事実と食い違わない。直すなら、WebView の DOM へ撃った回は注記の「後から反応する」の例に WebView を足すか注記を出さない(ブリッジの版上げが要る)
- 測る口(2026-11-25・iOS ブリッジ 312): 注記を出した回に、比べた前後の指紋と1フレーム後に撮り直した指紋を同じ注記へ足した(`pixel prints before=… after=… one-frame-later=… (differs from before | same as before)`)。1フレーム後に違えば「整定より後に描画が入った」と分かる。実機では未通過

### OI-224 失敗文の添え書きが、後の操作が効いた後でも、前の「画面が変わらなかったタップ」(選択中のタブの押し直し等)を「飲まれたかも」と名指す
- 状態: 再現済み
- 確認: 35040589d(2026-11-15・55周目 im4 で E2E-iOS 4/4 再発)
- 属性: 据え置き
- 運用: 合否に響かない(添え書きだけ・「may have been swallowed」とぼかしている)
- 優先度: 低 — 帰属が的外れになることがある

出典: `_work/explore-20261113c/findings-im4.md`(54周目 im4 F1)。launchApp の直後(既にホーム)に `tap("#tab_home")` → ダイアログを開いて OK → `back()`(自前の戻るの画面なので効かない・注記は事実どおり)→ `exist("#nav_dialog")` の赤に「earlier, the screen was also unchanged between tap id=tab_home and the tap after it — that interaction may have been swallowed」(RN・SwiftUI・CMP の iOS で 6/6)。原因は観測済み: `StepExecutor.earlierTapsHint` は「直前のタップが画面を変えないのが正常な操作でも、その前のタップが効いていなかった事実は消さない」設計で、後の操作で画面が変わっても外さない。**据え置きの理由**: 名指す事実(そのタップの後に画面が変わらなかった)は正しく、文はぼかしてある。後の操作が効いたことで外すと、空振りした保存の後に戻って赤になった形(sut-ec-mobile)で名指せなくなる。効かなかった `back()` は別の注記が既に言っている

### OI-219 Google マップ Android の経路一覧のコーパスで、採取時の検知(overlay 3・misses 1・sliver 2・clippedByContainer 1)を1件ずつ確かめていない
- 状態: 推測
- 確認: 2026-11-25
- 属性: 据え置き
- 運用: 合否に響かない(コーパスの基準値の中身の確認だけ)
- 優先度: 低 — 観測した害は無い

出典: Google マップ Android の公共交通の経路一覧(コーパス `and-maps_transit_results`・11/12)。採取時の値を基準値にしただけで、1件ずつ真陽性かを確かめていない
- 解消した部分(2026-11-25 に確認): 経路カードを直前の横カルーセルの外と読む取り違え。今のブリッジ(keptDepth あり)で同じ画面(東京駅 → 新宿駅の経路)を撮ると、カルーセル `#query_options_filter_carousel` は depth 22・keptDepth 4、経路カード(clickable「14 分」)は depth 23・keptDepth 3 = カルーセルの部分木に居ない → `isOutsideContainer` は keptDepth の門(11/18 c516bddf6)で送り残しと読まない。コーパスの木は keptDepth を持たない古い採取なので、コーパスの上ではまだ取り違える
- 次の一手: この画面を今のブリッジで撮り直してコーパスを差し替え、overlay 3 件の覆いをスクリーンショットで確かめる(差し替えは `SweepHarnessTests` の基準値の変化を1件ずつ見てから)

### OI-216 xcuitest モードで、貼り付く見出しのリストの行への tap が何も起こさないまま ✅(E2EX の Flutter・iOS。RN は DR-234 で撃たずに断る)
- 状態: 再現済み
- 確認: 69f3cfe5b(2026-11-11)
- 属性: 据え置き・木に材料なし
- 運用: 要注意 — Flutter・iOS は tap が ✅ で、後続の結果の検証が赤になる(文言が見出しを名指して直し方を言う)。RN は tap が見出しを名指して撃たずに赤
- 優先度: 中 — 押した後に結果を確かめるシナリオなら赤にできる

出典: `_work/xcui-20261111`・`_work/fix215`(11/11 の xcuitest の3スイート)。E2EX の「貼り付く見出しのリストを扱えること」S0010 で、`tap("#row_s_F3")`・`tap("#row_s_B1")` が ✅ のあと `textIs("#txt_sticky_result", …)` が赤(「the preceding tap … did not change the screen at all」。Flutter は `found by sweeping back after overshooting it` の注記付き)。inapp-boost モードは緑。
- 手元の8台へ配った率: E2EX-Flutter は HEAD(69f3cfe5b)2/8・縁から少しはみ出した要素の寄せを遅いドラッグにした版 2/8、E2EX-RN は HEAD 3/8・その版 5/8 = その直しの退行ではない。E2EX-iOS は 11/11 の xcuitest の回帰で M4Max の1本が赤(回し直し 2/2 緑)
- **原因(11/11 に観測)**: 赤の回は全部、撃った時点の行の中心が貼り付く見出しの帯の下にある(Flutter: `#row_s_F3` 170..187 / 170..215 / 175..231 の中心が、絵で y 約 170〜206 の見出し F の帯の下。木の見出しは文字の枠 `#hdr_F` 16,180 83x20 だけ。RN: `#row_s_B1` 161..205 の中心 183 が `#hdr_B` 156..189 の中)。中心を撃つと見出しに当たる。見出しの下から送り出す段(`TapTargetGeometry.pinnedBandCovering` → `liftCoveredTarget`)は 6fd0771f4(11/5・OI-170 の決定)から塗り順のある木だけ = xcuitest モードの木では飛ばされる。11/1 の印の後に入った門なので、出始めの時期と合う。探索が止まる位置で見出しに掛かるかが決まるので率が割れる
- **決定の残り半分が届いていない**: OI-170 の決定は「中心を撃ち、後続が赤なら失敗の文言が覆いを名指して直し方を言う」(`coveredTouchHint`)。疑いを控える元(`coveredTouchPlan` の `advisoryKind` の `.overlayCovering` と `otherLayerCoverCandidates`)に貼り付く見出しの形が無いので、赤の文言は「画面が全く変わらなかった・飲まれたかシステムアラート」だけ
- ①(11/11 済み): 控える元に `pinnedBandCovering` を足した(文言だけ・決定の範囲内。`OtherLayerHitTestWiringTests.testFailureAfterATapUnderAStickyHeaderNamesTheHeader`)
- ②の材料は無い(11/11 に測定): XCUITest の `isHittable` は見出しの下の行にも true を返す(Flutter: `#row_s_A0` 179..235 の中心 207 が `#hdr_A` の帯 170..210 の下・RN: `#row_s_A0` 162..206 の中心 184 が `#hdr_A` 157..190 の中。どちらも中心を撃つと `sticky=none` のまま = 見出しに当たった。対照の `#row_s_A1` は押せた)。true は見出しの下を見分けられないので門にできない = 送り出しは戻さない(OI-170 の決定のまま)
- 印の扱い(11/11 ユーザー決定): このシナリオは xcuitest モードで探索の止まる位置しだいで赤になる(手元8台で 1〜5/8)ので、xcuitest の印の条件からだけ外す(`Scripts/mark_exclusions.py`。シナリオは回し続け、外した赤は名指す)。失敗の文言は①で見出しを名指して直し方を言う
- シナリオの扱い(11/17 ユーザー決定): SUT のシナリオを「見出しに掛からない位置まで送ってから撃つ」形に書き換えない(罠が試験から見えなくなる)。今の形(赤 + 見出しを名指す文言)で確定。送り出しを戻すのは XCUITest の木に塗り順の材料が出たときだけ(DR-145)
- 11/19 の回帰(`_work/rr83-impl/regress3`): E2EX-CMP の xcuitest で「伸縮するヘッダ」の `tap("#row_c_37", scroll: .down)` が ✅ のあと結果が `collapse=none` のまま(「the preceding tap … did not change the screen at all」)。同じ日の他の2回の回帰では緑 = 同じ系統の断続(送りの後のタップが飲まれる)
- 観測(2026-11-25・全マシンの回帰と手元 Sim の反復・E2EX-RN の xcuitest モード `貼り付く見出しのリストを扱えること.S0010`): `tap("#row_s_B1", scroll: .up)` の探索が行を貼り付く見出し `#hdr_B (16,157 370x33)` の下(行 `(32,163 338x44)` = 中心が見出しの帯の中)で止め、tap が見出しに当たって ✅・続く `textIs` が赤(回帰で1回)。手元の反復は今日の前のコミット 90fb61a66 で 6/8 緑・今日のコード(29c559d73 とXCUITest ランナーの keptDepth の変更)で 4/11 緑 = どちらも揺れる。差は回数が少なく偶然と区別できない(据え置きのまま。率が下がり続けるなら探索の止まり方を測る)
- 棚卸し(2026-11-25 夜): 新しい材料なし(xcuitest モードの木の形)
- 材料の見直し(2026-11-26・コードと API の読み、デバイス未測定): RN は見出しの枠が行の中心に重なるので DR-233 の撃つ前の OCR が働きうる(xcuitest で注記が付くかは未測定)。Flutter は見出しの枠が文字の箱だけで中心に重ならない = 候補が無い
- 材料の測定(2026-11-26・手元 Sim 8台へ `--broadcast`・E2EX-RN・xcuitest): 赤 6 台は全部、`tap("#row_s_B1")` に押す前の OCR の注記 `tap-target-drawn-over`(行の枠に見出しの文字が描かれている = DR-233)が付き、緑 2 台には付かなかった(6/6・反例 2/2)。失敗文は `#hdr_B` を名指して送り方を言う。RN の材料は撃つ前に取れている = 送り出す・断るへ上げるのは DR-233 の見直しの条件(全体の回帰で誤検知 0)を満たしてから。Flutter は見出しの枠が文字の箱だけで中心に重ならず候補が出ない(未測定)
- 検証の所要(11/26): 約6分(配って回す 約3分)
- Flutter の測定(2026-11-26・同じく8台へ `--broadcast`): 8/8 緑で行の中心が見出しの下に入る回が出ず、材料は未確認。緑の回の行のタップ 16 回に `tap-target-drawn-over` は付かなかった(誤検知 0/16)
- 検証の所要(11/26): Flutter 約5分
- 全体の回帰(2026-11-26 夕・489cb16・4 台・24 対象・1,189 本・全部緑。iOS は inapp-boost と Android): `tap-target-drawn-over` の誤検知 0 件(DR-233 の条件)。xcuitest モードは回帰に含まれない(上の手元8台の測定が RN の材料)
- 処理(2026-11-26・DR-234): xcuitest モードで撃つ前の OCR が見出しの文字を対象の枠に読めたら撃たずに断るようにした。手元8台へ配り、見出しの下に入った6台は `tap("#row_s_B1")` が「where its frame is, the screen shows the text of #hdr_B ("セクション B") … (nothing was touched)」で撃たずに赤、2台は緑 = 誤ったタップを撃たなくなった(赤の数は変わらず、赤になる位置が tap へ移り覆いを名指す)。残りは Flutter(見出しの枠が文字の箱だけで候補が出ない)と E2EX-iOS(未測定)

### OI-205 Android の Flutter のオートコンプリートの候補への tap が選ばずに緑(a11y の枠が描画とずれる)・セレクタの末尾の空白ほか
- 状態: 再現済み
- 確認: ad54d899c(2026-11-10)
- 属性: 据え置き・木に材料なし
- 運用: ①要注意 — Android の Flutter で、キーボードを閉じた直後のオートコンプリートの候補への `tap` は、候補を選ばずに緑になることがある。選んだ値を検証する
- 優先度: 中 — ①は既定の経路の誤った成功(材料不足)

出典: `_work/explore-20261109e/findings-*.md`(44周目のやり直し・11/9)。①Android の Flutter で、キーボードを閉じた後の候補 `#auto_opt_japan` への `tap` が注記の無い ok で、候補は選ばれず上の欄に落ちる(alocal F1 MCP 4/4・DSL 1/1。木の候補の枠が描画より約 240px 上にずれていた = スクリーンショットで観測。Flutter 側かブリッジの写像かは材料不足)**据え置き**: ⑤(c9fdc9f54 で解消)CMP のドロップダウンを開いたまま欄へ `type` すると「add waitSeconds」を勧め、メニューの窓が前面なことを言わない(amax F1 4/4)⑥覆いの窓の下の欄で断る文の「go back」は、CMP の候補の窓を閉じない(alocal F2 1/1。「tap a neutral spot」は効く)⑦`textStartsWith=検索 `(末尾の空白)は「検索バー」に一致し、同じ意味の `検索 *` は一致しない(ilocal F1・im4)
- 11/9(45周目の材料採り・phys): ①のずれは **OS の a11y の木にすでにある**(ブリッジの `ft_snapshot` と `uiautomator dump` の枠が画素単位で一致・描画は約 600px 下・Flutter の窓は動かない。`SnapshotBuilder.java:571` は `getBoundsInScreen` をそのまま使う)= ブリッジの写像の誤りではない・木だけからは正しい位置が分からない。ずれの量は状態で 222〜718px(候補の祖先の Overlay の層の枠が a11y で上端 0 に固定されている関係)。CMP は候補が別の窓で枠と描画が一致。Flutter 側か Android 側かは材料不足
- 11/10(①の時間の推移): 手元の Emulator(Pixel 10 Pro -01・Android 17)で `type("#field_auto", "Ja")` → `hideKeyboard()` の後 20 秒置き、`fleetest snapshot` を 0.5 秒ごとに撮って枠を記録。**候補の枠は時間で直らない**(閉じた後の 40 秒間 `#auto_opt_japan` = y 1677・h 168 のまま)。欄 `#field_auto`(y 1752〜1920)は描画と一致し、候補の描画(スクリーンショット)は約 1931px から = 木は約 254px 上・木の候補の中心(約 1761)は欄の中 = tap は欄に届いて候補を選ばない。閉じる前も木 1296・描画約 1709 = 約 413px 上で、ずれはキーボードを閉じた後だけの事象ではない。待っても木は正しくならないので、観測できる事象を待つ直しは成り立たない。**木の外の材料(画素)が要る**: 撃つ前にその枠の画素にラベルの文字があるかを OCR で確かめる案(テキストの可視性検証を tap の前にも掛ける = 費用と適用範囲はユーザーの判断)。Flutter 側の既知の不具合は検索で見つからなかった
- 11/10(①の扱い・ユーザー決定): ツールでは吸収せず、制約として文書に書いた(ui_component_patterns の「現時点の制約」と FD-5.1 の表: 候補を押した後は選んだ値を echo で確かめる)。撃つ前の OCR の確かめは費用(全 tap)に見合わないので入れない
- 2026-11-25(⑤の再確認・手元の Emulator・E2EX-CMP のメニュー画面・1/1): 開いたままの `type("#field_fruit", "x")` の失敗文は「the app's own dialog window is in front of the screen (ポップアップウィンドウ) … close the dialog first — waiting will not bring back what is behind it」= アプリ自身のポップアップを名指して閉じるよう言う(11/13 の c9fdc9f54 で解消)。waitSeconds は勧めない
- 11/10(⑦ は据え置き): ⑦ は書き方で空白の扱いが割れる形(フィルタの値は項の端の空白を落とす = `#a && text=b` の書き方を許すため・ワイルドカードは項の中の空白を残す)で、どちらへ揃えてもセレクタの一致が変わる。11/9 のユーザー決定「セレクタの空白は今のまま」の範囲なので、決定が無い限り直さない
- 棚卸し(2026-11-25 夜): 材料の候補あり(枠が描画とずれる形)。対象の枠を OCR で読み、自分の文字が読めず別の要素の文字が読めれば手前を決められる(OI-387 の検知と同じ材料)。オートコンプリートの候補は重なる要素が木に無い形なので、この検知は当たらない(未測定)
- 次の一手の条件(2026-11-26): ①は、押す前の OCR を「対象の中心に、ラベル付きの別の要素が重なる」ときだけに絞れば、全 tap の費用にはならない(OI-170 と同じ形)。ただし 11/10 のユーザー決定(押す前の OCR は入れない)を変えることになるので、検証の側の同じ判定(`covered-by-front-element-read-on-screen`)の誤検知を全体の回帰で確かめた後に、判断をもらう
- 処理(2026-11-26・DR-233): ①は撃つ前に候補の枠を OCR で読み、欄の文字(値 "Ja")が描かれていれば注記 `tap-target-drawn-over` を付けるようにした(合否は変えない = 押した後の値の確かめが赤にする)。手元 Emu -01 で 3/3 注記が付いた。撃つ前に断る・描かれた位置を押す、へ上げるかは全体の回帰で誤検知 0 を確かめてから(⑤は 11/13 の c9fdc9f54 で解消。⑥⑦は従来の記載のまま)
- 材料の見直し(2026-11-26・コードと API の読み、デバイス未測定): ①の材料(画素)は DR-233 の撃つ前の OCR で入っている。描かれた位置を押す・断るへ上げるのは全体の回帰で誤検知 0 を確かめてから
- 全体の回帰(2026-11-26 夕・489cb16・4 台・24 対象・1,189 本・全部緑。iOS は inapp-boost と Android): 撃つ前の注記 `tap-target-drawn-over` は 0 件 = DR-233 の見直しの条件(誤検知 0)を満たした。撃つ前に断る・描かれた位置を押すへ上げるかはユーザーの決定待ち
- 2026-11-26(DR-234): 撃たずに断るのは XCUITest が座標で撃つ iOS だけに決めた。①の Android の Flutter は今までどおり撃って注記(押した後の値の確かめが赤にする)

### OI-202 iOS の CMP 検索バーの value の説明文を中身と読む注記・Duo の形・MCP の文言・SE3 の in-app ブリッジが供給から落ちるほか
- 状態: 再現済み
- 確認: コミット未記録(2026-11-10)
- 属性: 据え置き
- 運用: ③M4Max では合否に響く(下の 11/17)・ほかの機械と④〜⑧は合否に響かない(文言・MCP だけ・Duo だけ)⑨再実行で吸収(供給から落ちた台のぶんは残りの台が回す)
- 優先度: 低 — 文言・MCP・Duo の形

出典: `_work/explore-20261109b/findings-*.md`(42周目・11/9)。③iOS の CMP 検索バーで、value の説明文(「検索候補は次のとおりです」)を中身と読んで type の注記が「already held … Call clearInput first」と言う(amax F4)④Flutter の iOS で検索画面に置き換わった欄の clearInput の失敗文がキーボードのせいと言い、Back の 9pt 下を叩く(amax F6)⑤向きの戻しに失敗して再キューされた Simulator が以後「開始時の向き = 横」を戻し先にし続ける(amax F10・1回)⑥iPhone Duo: `rotateTo(.landscape)` が常に 422 で文言が事実と合わない(duo F1)・開いた状態で XCUITest の払いが動かない(duo F3・xcuitest モードと MCP)・`ft_fold degrees` が送る前の状態を言う(duo F6)・開いた状態で value が入力を映さない欄への打ち直しが二重に入る(duo F7)⑦hideKeyboard の文が inputAccessoryView の窓を「toast」と呼ぶ(im4 F4。in-app ブリッジの文)・横向きの replace に「キーボードを閉じた」が2回並ぶ(phys F4)⑧MCP: snapshotAfter 無しの ft_type の後の ft_clear_input が「unchanged」と言う(alocal F2)・容器の ref への ft_clear_input が「別の欄も消えた」と言う(alocal F4)⑨iPhone SE3 の inapp-boost で in-app ブリッジが応答せず供給から落ち、文がケーブル・iproxy に帰属する(phys F5 14回中4回。XCUITest は答え in-app の iproxy も生きていた)
- 11/17(回帰): ③の形が E2EX-CMP の「検索バーで検索できること」S0030・S0040 を **M4Max でだけ**赤にする(`clearInput "#field_search"` が「12 character(s) still there」・`type(replace)` が「value remained: 検索候補は次のとおりです」)。M4Max の2台で一斉に回し直して 4/8 赤・手元の8台で 32/32 緑。11/9 の回帰でも M4Max でだけ同じ2本が赤。M4Max で欄の値が説明文になる理由(Simulator の設定か SUT のビルドの違いか)は未測定
- 測った(2026-11-25): M4Max では今も S0030・S0040 が赤(`clearInput` が「12 character(s) still there」・`type(replace)`)。**M4Max でビルドした SUT(FTE2EX.app)を手元の 8 台へ入れて回すと 4/4 緑** = SUT のビルドの違いではない。Simulator の言語(`ja-JP, en-JP`・`ja_JP`)とランタイム(iOS 27.2 24B8117)も手元と同じ。測った中で違うのはホストの macOS(M4Max 26.7.3・手元 27.2.1)だけ = 原因の候補(確かめていない。M4Max の macOS を上げたら回し直す)
- 実機(2026-11-25): iPhone SE3(iOS 26.6.2・手元の Mac に USB)へ実機用にビルドした E2EX-CMP を入れ、「検索バーで検索できること」4本を inapp-boost・xcuitest の両モードで回して 4/4・4/4 緑 = 実機では起きない。緑の Simulator のホストは全部 macOS 27.2.1(手元・M1Ultra・M1Max)、赤は 26.7.3 の M4Max だけ = ホストの macOS の候補と食い違う事実は無い

### OI-211 xcuitest モードで、SwiftUI の隠れるバーを送って戻した後の FAB への tap が「行が手前」と断られる
- 状態: 再現済み
- 確認: コミット未記録(2026-11-10)
- 属性: 据え置き・木に材料なし
- 運用: 回避可 — xcuitest モードだけ。既定の inapp-boost モードでは押せる。xcuitest モードで要るなら送らずに押す順に書く
- 優先度: 低 — 誤った赤(失敗文が手前の要素を名指すので沈黙しない)・既定でない経路

出典: `_work/explore-20261109l/findings-im4.md`(50周目)と 11/10 の測定。E2EY-iOS「スクロールで隠れるバー」で `scrollDown()` → `scrollUp()` の後、XCUITest の `isHittable` は FAB に false を返すが、同じ点への座標の tap は両モードとも FAB に届く(XCUITest の本物のタッチでも届く)= `isHittable` の答えの誤り。**inapp-boost モードは直した**: in-app の当たり判定 `/touchlands` が「対象に届き、覆いの候補のどれにも届かない」と言えたら撃つ(`TapTargetGeometry.touchClearsCovers`・注記 `touch-reaches-target-despite-hit-test`。測定: FAB の中心は FAB の view だけに届き、行の view〈PlatformGroupContainer〉には届かない。Flutter の半分のシートの裏の行は覆いにも届くので断るまま)。**xcuitest モードには in-app ブリッジが無く、この材料が取れない**ので断るまま。MCP の ref 経路(`otherLayerRefTouchRefusal`)も iOS は XCUITest の木の番号なので `/touchlands` に渡せず、モードに関わらず断るまま
- 戻す条件: XCUITest の側で本物のタッチの当たり先を答える手が見つかったら(公開 API には無い)
- 棚卸し(2026-11-25 夜): 新しい材料なし(xcuitest モードの木の形)
- 材料の見直し(2026-11-26・コードと API の読み、デバイス未測定): xcuitest モードには本物のタッチの届き先を答える API が無い(`hitPoint` や点の要素も `isHittable` と同じ AX の当たり判定)。FAB は文字が無く OCR も効かない = 材料なしのまま

### OI-210 iPhone Duo の折りたたんだ状態で、キーボードに押し上げられて上端で半分切れたテキストの検証が OCR の読み誤りで赤
- 状態: 再現済み
- 確認: コミット未記録(2026-11-09)
- 属性: 据え置き
- 運用: ①誤った赤(沈黙しない)— Duo の折りたたんだ状態だけ。上端で切れたテキストを検証するならキーボードを閉じてから
- 優先度: 低 — Duo だけの誤った赤

出典: `_work/explore-20261109k/findings-duo.md`(49周目・11/9)。①`ios-duo`(inapp-boost)で `fold()` の後に入力画面で `type(replace:)` すると、キーボードで画面が上へ押し上げられ、`#txt_echo_single`(枠 (16,-9 94x20) = 上端で半分切れている)への `textIs("single=fold2")` が「the text drawn there reads "single=1010a2"」で赤(duo F1 2/2。木の text と欄の値は期待どおり・開いた状態では 3/3 緑・同じシナリオの1周目は緑)
- 据え置きの理由: 原因は材料不足(上端で切れた絵の OCR の誤読か、切り出しの位置かを分ける材料が無い)

### OI-209 this* だけのシナリオがステップ0件で赤(1回)・値の改行で表示が割れる・ft_scroll_to の文言ほか
- 状態: 再現済み
- 確認: コミット未記録(2026-11-09)
- 属性: 据え置き
- 運用: ①再実行で吸収(4回中1回)②⑤合否に響かない(表示・文言)④誤った赤(MCP だけ)
- 優先度: 低 — 誤った赤・文言・MCP だけ

出典: `_work/explore-20261109i/findings-*.md`(48周目・11/9)。①`this*` だけのシナリオが 28ms でステップ0件・失敗文なしの赤(ilocal F1 4回中1回。結果 JSON は passed:false・steps 0・workerAnomalies なし・クラッシュ報告なし。回し直すと緑)②値に改行を含む `this*` のステップの説明と失敗文が2行に割れる(ilocal F2 2/2)③MCP の `ft_batch` で単一行の欄へ type した直後に、上 39pt が見えている複数行の欄への type / clearInput / doubleTap を「中心がキーボードの下」と断る・対処文の ft_hide_keyboard ではこの画面のキーボードを閉じられない(duo F2 7/7)④「a b」の複数行の欄への type(replace) が「could not empty the field」で赤になり値が「 b」に壊れた(duo F3 1回の連鎖だけ・新しい状態からは 0/5)⑤ft_scroll_to が上端から一部はみ出た要素に2回払って何も動かなかったのに「scrolled to」と返す(duo F1 5/5)。ほかに、絵文字の扱いが部分一致(書記素の単位)と正規表現(UTF-16 の単位)で割れる(値 "👍🏽" に `textContains("👍")` は赤・`textMatches("👍")` は緑 = im4 の参考)
- 2026-11-25(③の再確認・手元の iPhone Duo(iOS 27.2)-01・新しい fleetest-mcp を stdin で起こして): `ft_batch` の `type '#field_single' 'abc'` → `type '#field_multiline' 'x'` の2行目が「the target's centre (191, 375) is under the soft keyboard and the keyboard could not be closed without side effects (tapping (378, 344) above the keyboard did not close it) — nothing was typed」で断られる(キーボード (0,374 466x304) = 中心が上端の 1pt 下)。`ft_batch` は DSL と同じ StepExecutor を通るので、③は MCP だけの形ではない(DSL の type も同じ判定)。**③は直した(2026-11-25)**: キーボードを副作用なく閉じられず、欄の上側が見えているときは、見えている部分を押して焦点が立ったのを確かめてから打つ・消す(焦点が立たなければ打たずに断る・押し直さない)。iPhone Duo の inapp-boost・xcuitest で type と clearInput が緑(注記「tapped its visible part above the keyboard and confirmed focus moved to it」)・通常の iPhone の Simulator の両モードは変わらず緑。(f72c623c0)
- 据え置きの理由: ①④原因は材料不足 ②⑤文言・表示。正規表現の照合は UTF-16 の単位(書記素の途中に一致の範囲が落ちても見つける)で、部分一致は書記素の単位のまま

### OI-208 正規表現の値の中の `&&` で切れる・キーボードの下と言い切る失敗文
- 状態: 再現済み
- 確認: コミット未記録(2026-11-09)
- 属性: 据え置き
- 運用: ②回避可 — 正規表現の値に `&&` / `>>` を書かない(`Sel.text(…, .matches)` なら書ける)③合否に響かない(文言)
- 優先度: 低 — ②③は誤った赤か文言

出典: `_work/explore-20261109h/findings-*.md`(47周目・11/9)。②セレクタの `textMatches=` の値の `&&` / `>>` で値が切れ「the same condition is written twice」で断る・切れたことを言わない(amax F2 4/4・ilocal F2 3/3・im4・phys)③キーボードより上に実在する要素の「見つからない」の失敗文が「キーボードの下で木から消えた・hideKeyboard せよ」と言い切る(phys F2 2/2。`keyboardResizedHint` は窓が縮んだかだけを条件にする)
- 据え置きの理由: ②③文言・誤った赤(沈黙しない)

### OI-207 MCP の ft_status が返らない(1回)・ft_batch の引数
- 状態: 再現済み
- 確認: コミット未記録(2026-11-09)
- 属性: 据え置き
- 運用: ②③合否に響かない(MCP だけ)
- 優先度: 低 — MCP か文言

出典: `_work/explore-20261109g/findings-*.md`(46周目・11/9)。②MCP の `ft_status` が -01 で 60 秒以上・-02 で 90 秒以上返らず記録にも残らなかった(duo F4 1/1。同じ時刻に自分の run が -01 のブリッジを起動中)③MCP の `ft_batch` が結合文字・異体字セレクタで始まる引数(`'́x'`・`'️'`)を引用符の文字列として読めずに断る(duo F3)④正規表現が不正なとき・空のときの DSL の赤に理由の行が付かない(ilocal F3)
- 据え置きの理由: ②原因は材料不足(46周目に1回・48周目に MCP の ft_status {udid: -01} が 193.6 秒返らず、その間に MCP サーバ自身が -01 の XCUITest ブリッジを起こしていた = duo F5。失敗文は「tried 0s ago」で理由の本文が空)③MCP の ft_batch の引数の字句解析だけの形(④は 11/25 の 94d0ed48c で直した)

### OI-206 数値比較の this* が全角・桁区切りを読まない・Flutter の起動直後の type の read back の赤
- 状態: 再現済み
- 確認: コミット未記録(2026-11-09)
- 属性: 据え置き
- 運用: ②要注意 — 数値比較の `this*`(`thisIsGreaterThan` 等)は全角数字・桁区切り・前後の空白の付いた値を数値に読まず赤になる。比べる前に数値へ直す
- 優先度: 低 — 誤った赤(沈黙しない)・遅さ・文言

出典: `_work/explore-20261109f/findings-*.md`(45周目・11/9)。①Android の E2EX-CMP のホームで、一覧の上に固定の題 `#txt_screen_title` を「容器の外の残り」と読み、`select` が毎回約 5.7 秒の再解決・`tap` は払いを撃って一覧の位置を戻す(alocal F3 DSL 6/6・MCP 5/5。他の SUT のホームでは起きない)②数値比較の `this*` は正規化前の値を `Double()` で読み、"5"+ZWSP・" 5"・全角の "１０"・"1,200" を赤にする・失敗文が数値に読めなかったことを言わない(amax F2 4/4)③Flutter で起動直後の最初の `type('#field_auto >> .textField')` が、欄に入っているのに「read back ""」の 500 で赤(phys F1 9回中7回。同じ画面で clearInput → type は 4/4 ok)④→ OI-196 ⑤
- 11/9(46周目の回し直し): ①は直っていない(alocal DSL 6/6・select のたびに 7 回の再解決の注記)②は直っていない(amax 4/4)③は直っていない(phys 実機 6 回中 3 回・赤の回も欄に "Ja" が入っている)・47周目も直っていない(phys 4 回中 4 回)
- 据え置きの理由: (①は 11/25 に解消)②数値の読み方を広げるのは書式の解釈の決定が要る ③原因は材料不足
- 2026-11-25(①の再確認・手元の Emulator・E2EX-CMP のホーム): `select("#txt_screen_title")` を3回続けて 0.36〜0.61 秒・再解決の注記なし(11/9 は毎回約 5.7 秒・7 回の再解決)= 解消(11/18 の keptDepth の門 c516bddf6 と同じ形の見込み。この画面の木の keptDepth は確かめていない)。残りは②③
- 測る口(2026-11-25): ①の容器の外の判定を判定の足跡 `container-outside`(選んだ容器の枠・外と読んだか・容器が画面からはみ出ていたか)に残す

### OI-192 端に着いて動かなかった探索の失敗文が、従っても赤になる scrollFrame を勧める
- 状態: 再現済み
- 確認: コミット未記録(2026-11-07)
- 属性: 据え置き
- 運用: ④合否に響かない
- 優先度: 低 — 文言だけで合否は正しい

出典: `_work/explore-20261107e/findings-*.md`(34周目・11/7)。④端に着いて何も動かなかった探索(反転チャットの最下端から下へ・RN と SwiftUI)の見つからない失敗が「withScrollDown(scrollFrame: "#list_chat") { } で包め」と勧めるが、従っても同じく赤(im4 F1・RN 3/3・SwiftUI 2/2。`StepExecutor+ScrollSearch.swift` の scrollFrameHint は全画面の払いが候補の容器の中から撃たれたかを見ていない = 出し分けるには払いの始点と候補の容器の枠が要る)
- 据え置きの理由(11/8): 全画面の払いの始点はブリッジが決めてホストは知らない。端に着いて何も動かなかった回は、払いが容器の中に落ちても外に落ちても同じく動かないので、木の材料では案内を出し分けられない(案内のためにブリッジの応答を変えるのは見合わない)

### OI-194 RN の iOS の数字キーへの doubleTap が1回しか届かない
- 状態: 再現済み
- 確認: コミット未記録(2026-11-07)
- 属性: 据え置き
- 運用: ④再実行で吸収(後続の検証が赤にする)
- 優先度: 低 — 後続が赤にする届かない操作

出典: `_work/explore-20261107g/findings-*.md`(36周目・11/7)。④RN の iOS の数字キーへの `doubleTap` が ✅(fell back to XCUITest)なのにアプリに届くのが 1 回だけのことがある(im4 F2・4/7。SwiftUI・Flutter は 3/3 で 2 回届く。単発の tap は 6/6 で届く)
- 据え置きの理由(11/8): XCUITest の doubleTap(2回のタッチの間隔が短い)を RN の Pressable が2回目の押下と扱わないのか、タッチが1回しか届いていないのかは、SUT を変えずに分ける材料が無い

### OI-195 iOS の home() の後の読み・操作が待ちの上限まで待ってから赤
- 状態: 再現済み
- 確認: コミット未記録(2026-11-07)
- 属性: 据え置き
- 運用: ③合否に響かない(待ちの時間の損)
- 優先度: 低 — 待ちの時間の損

出典: `_work/explore-20261107h/findings-*.md`(37周目・11/7)。③iOS の inapp-boost で `home()` の後の読み・操作が待ちの上限まで前面に戻るのを待ってから「did not read or touch it」で赤(im4 F1・17/17。`terminateApp()` の後は 0.47 秒で断る。openURL の直後の戻る途中を断らないための待ち = `StepExecutor.backgroundedAppRefusal`)
- 据え置きの理由: ③の待ちは openURL の直後の戻る途中を断らないための待ち(遅さとの兼ね合い)

### OI-193 覆われた要素への exist・テキストの検証が注記付きの緑
- 状態: 再現済み
- 確認: コミット未記録(2026-11-07)
- 属性: 据え置き
- 運用: ①要注意 — RN・UIKit の in-app・Android の View で、覆われた要素への `exist` / テキストの検証は緑のまま注記 `covered-by-front-element` が付く。見えていることを確かめたいなら同じ要素を `tap` してみる(覆われていれば撃つ前に断る)
- 優先度: 中 — ①覆われた要素への `exist` / テキストの検証が注記付きの緑(全数を見て警告のまま据え置き)

出典: `_work/explore-20261107f/findings-*.md`(35周目・11/7)。①RN の iOS で払う前の行の裏のスワイプのボタン・半開シートの裏の行への `exist` / `textIs` が ✅(im4 F2・13/13)、同じ要素への `tap` は「露出 0」で撃つ前に断る。11/7 に注記 `covered-by-front-element`(合否は変えない)を入れた(f12f698fb。M1Ultra の6台で狙った形 6/6・既存のスワイプのクラスの検証に 0 件)。赤へ上げるのは E2E・E2EX・E2EY の全数で注記が付いた検証を1件ずつ見て、見えている要素に付いた例が0と確かめてから
- 11/8: ①の全数(39cf36280 の回帰・1,099 本): 注記は7か所(E2EX-RN の iOS のメニュー・ダイアログ・長押しメニューで、項目を押して閉じた直後の結果欄の `select`)だけで、7か所とも閉じかけのメニューがまだ木の上で手前に残る間の読み。同じ手順を手元の8台と M1Max の4台へ同時に回すと、直後に読むと 12/12 で注記が付き、1秒待つと 0/12(合否はすべて緑)= 遷移の途中の覆い。このまま赤へ上げると正しいシナリオを赤にする(12/12)。赤にするなら覆いが外れるまで待つ形が要るが、遷移の完了は待たない方針と衝突するので、警告のまま据え置く
- 関連(2026-11-25 夜): 塗り順の分からない木(SwiftUI・CMP・Flutter)でも、重なるラベル付きの要素の文字が対象の枠に描かれていれば、画素(OCR)で読んで注記 `covered-by-front-element-read-on-screen` を付けるようにした(OI-387。合否は変えない)

### OI-197 xcuitest の実機でモーダルの裏への tap が警告付きの ✅
- 状態: 再現済み
- 確認: コミット未記録(2026-11-07)
- 属性: 据え置き
- 運用: ⑥要注意 — xcuitest モードの実機だけ。別ウィンドウのモーダルの裏への `tap` が警告付きの ✅
- 優先度: 低 — xcuitest モードの設計(警告のみ)

出典: `_work/explore-20261107j/findings-*.md`(39周目・11/7)。②SwiftUI で `back()` の直後の木に前の画面の `#BackButton` が残り `exist` / `tap` が ✅(im4 F1・6/6)。手元の8台で直後 8/8・0.5 秒後 6/8・1 秒後 0/8 = 戻る遷移のフェードの間(画面にも描かれている) ⑥xcuitest モードの実機で別ウィンドウのモーダルの裏のボタンへの `tap` が「the tap will land on that overlay」と警告して撃ち ✅(phys F1・2/2。`OverlayWindowOcclusion` は警告のみの設計。inapp-boost は撃つ前に断る)
- 据え置きの理由: ⑥xcuitest モードは警告だけの設計
- ②は消えた(2026-11-26・04f90dc2a・手元 Sim・E2EY-iOS・inapp-boost): `tap("#nav_links")` / `tap("#nav_nested")` → `back()` の直後の `exist("#BackButton", waitSeconds: 0)` が 10/10 not found(11/7 は直後 8/8 で残った)。iOS ブリッジ 317・318 の去り際の戻るボタンを木に載せない直し(`InAppSnapshot.isLeavingBackButton`)の効き目
- 検証の所要(11/26): 台帳とコードの読み(エージェント) + 一時シナリオを書いて `run-file` で5回(1回 約30秒) = 約10分

### OI-204 MCP の back と ft_type(replace:) の断りの文言
- 状態: 再現済み
- 確認: コミット未記録(2026-11-09)
- 属性: 据え置き
- 運用: 合否に響かない(MCP だけの文言)
- 優先度: 低 — MCP だけの形

出典: `_work/explore-20261109c/findings-*.md`(43周目・11/9)。**据え置き**: ②MCP の Android の `ft_navigate back` はキーボードを閉じただけでも「back sent.」とだけ返す(alocal F1 4/4。`BackEffect` を呼ぶのは DSL だけ)③MCP の `ft_type(replace:)` の「消え残り」の 422 は、fmAndVision が無ければ確かめた事実の無い断りのまま(ilocal F1。`ft_clear_input` と同じ扱い = 既定で OCR を使わない決定)

### OI-201 桁上限の欄への type で末尾が切れても注記の無い緑(iOS・Android の改行入り)・replace の読み返しの文言
- 状態: 再現済み
- 確認: コミット未記録(2026-11-09)
- 属性: 据え置き
- 運用: ①③要注意 — iOS で桁上限のある欄へ上限を超えて打つ `type`(Android は改行を含むセレクタ無しの `type`)は、末尾が欄に残らなくても注記の無い緑。打った値は `valueIs` / 画面の表示で確かめる ④合否に響かない
- 優先度: 中 — ①③桁上限で末尾が切れた `type` が注記の無い緑(`valueIs` で確かめれば赤にできるが知識が要る)。④は文言

出典: `_work/explore-20261109/findings-*.md`(41周目・11/9)。①iOS(inapp-boost)の桁上限の欄(OTP の 6 桁)へ上限を超える `type` が注記の無い ✅(im4 F1 15/15・SwiftUI・RN・Flutter。iultra F2 6/6。セレクタ無し・付き・replace とも。Android は注入器の読み返しで「did not keep the last N character(s)」を言う) ③Android の改行を含むセレクタ無しの `type` は、桁上限で末尾が切れても「did not keep …」が出ない(phys F2 5/5。読み返しが書いた文字列の先頭部分にならないので注入器が黙る = 整形と区別できない) ④replace の `type` で「whether the field was emptied could not be read back」と読み返した値が同じ行に並ぶ(phys F1 の追記 1/1。消去の段は焦点の欄を読めず、打鍵の段は注入器が読み返した)
- 据え置きの理由: ①iOS のブリッジは書いた文字列と欄の値を突き合わせて切れを言う経路を持たない。この画面は 6 桁で自動送信して欄が空に戻るので、読み返しで切れを見分けられるかも材料不足 ③注入器の判定を広げると整形(区切り・大文字化)を切れと誤認しうる ④消去の段と打鍵の段の別々の事実で、どちらも誤りではない

### OI-200 Flutter(iOS・Android)のダイアログの注記の欠け・tree-underreported・MCP の文言ほか
- 状態: 再現済み
- 確認: コミット未記録(2026-11-08)
- 属性: 据え置き・木に材料なし
- 運用: ①要注意 — Flutter のダイアログの間の `notExist` は、裏が木から消えても注記の無い緑。裏の要素を確かめるなら先に閉じる(CMP の iOS は v319 で `absence-behind-modal` が付く)
- 優先度: 中 — ①注記の無い誤った緑(先に閉じれば避けられるが知識が要る)。他は文言か MCP だけ

出典: `_work/explore-20261108/findings-*.md`(40周目・11/8)。①Flutter と CMP の iOS(inapp-boost)でダイアログの間に裏の要素への `notExist` が `absence-behind-modal` 無しで ✅、同じ裏への `tap` の赤は `waitSeconds:` を案内してダイアログを名指さない(im4 F3・ilocal F1・各 3/3。木はダイアログの要素と全面の "Dismiss" だけで、`modalScope` も `coveredByFrontWindow` も来ない) ②WebView の無い画面(E2EY の編集画面・RN の編集画面)の `notExist` / `countIs(0)` に `tree-underreported` が付く(amax F1 12/12・iultra F2 12/12。既存シナリオ 58 の S0040 にも 76 件) ④Android の横向きで全画面の IME がアプリを覆った後の検証の見つからない失敗がキーボードを言わない(amax F4・4/4) ⑤MCP の Android で、押せる `#mini_player` が中心を覆う半分のシートの裏の行への `ft_tap` が警告付きの done(alocal F3・4/4。警告がシートを「sticky header」と呼ぶ) ⑥MCP の ref 無しの `ft_type` が同じ応答で「read back」と「could not be read back」を並べる(alocal F2・3/3)
- 据え置きの理由: ①ブリッジがダイアログを申告しない(材料が木に無い = OI-170 と同じ) ②④原因は材料不足 ⑤⑥MCP だけの文言・判定
- ⑦(MCP の `ft_fold` の unfold の後の Duo の SpringBoard の落ち)は OI-184 へ
- 探索 2026-11-25(`_work/explore-20261125/findings-r2-amax.md` F2): ①と同じ形が Android の Flutter にもある。ダイアログが前面のとき、裏の要素への `notExist` が注記なしの ✅(DSL 5/5)、`tap` / `exist` の失敗文もダイアログを名指さない(CMP・RN の Android は「the app's own dialog window」と名指し、`absence-behind-modal` も付く)。原因(観測済み): Flutter のダイアログを開いた状態の生 `/snapshot` は要素4つ(全面の "Dismiss" を含む)で、modalScope も覆いの申告も無く、`dumpsys window` の窓も MainActivity の1枚だけ = 別窓の判定(`ForegroundWindows.swift:54`)に乗らない
- 棚卸し(2026-11-25 夜): 新しい材料なし
- 材料の測定と直し(2026-11-26・手元 Sim・in-app の一時的な診断の口で全ノードのクラス・modal・当たり判定を記録): **CMP** のダイアログ(E2EY-CMP の戻るの横取り)とドロップダウンメニュー(E2EX-CMP)は、本体と別の UIKit の層(`UIKitComposeSceneLayerView` を直接の子に持つ入れ物)に描かれ、開いている間は本体の `AccessibilityRoot` の子が0個(層の無い画面・インラインのパネルでは子がある)。modal の旗はどの要素も false。→ in-app ブリッジ(v319)が「層があり本体の根が空」のときに `modalScope` を申告するようにした。E2EY-CMP で背面への `notExist` に `absence-behind-modal`・背面への tap の失敗文が「a modal view or popup layer … close the modal first」になることを確認。手元の E2EY 4 SUT の4画面・E2EX-CMP のメニュー・E2E-CMP のダイアログ(50 本)は緑・新しい誤った注記なし。**Flutter**(iOS)は同じ FlutterView の中のノードで層も旗も無い(全面の「Dismiss」だけ = 名前からの推測になるので取らない)→ ①の残りは Flutter の iOS と Android(FD-2.1 の表)
- 検証の所要(11/26): 診断の口を足して3画面を測る 約25分 + 実装(エージェント)と直し・テスト 約30分 + デバイスでの確かめ(一時シナリオ2回・絞った実行 50 本 約9分) 約20分
- 処理(2026-11-26 夜・DR-235): **Android の debug / profile のビルド**では、アプリの VM サービスのダンプ(Android ブリッジ v154 の `POST /semanticsorder`)がダイアログの役割を申告する(破棄の確認ダイアログの間のダンプは幕・`role: alertDialog`・中身だけで、裏のノードは無い)。否定の検証がその間に通ったら注記 `absence-behind-flutter-dialog`(合否は変えない)。一時シナリオで、ダイアログの裏の `#field_title` への `notExist` にだけ付き、ダイアログの前・閉じた後の `notExist` には付かないことを確かめた。Flutter の Android の3スイート 135 本で発火 0。①の残りは Flutter の iOS と Android の release のビルド・失敗文がダイアログを名指さない部分
- 検証の所要(11/26 夜): ダンプでの材料の確かめ 約5分 + 実装・テスト・変異 約20分 + デバイス(一時シナリオ1本・3スイート 135 本)約15分

### OI-168 settle: false の flick の直後のワイルドカードの tap が寄せの後に見失う
- 状態: 再現済み
- 確認: a5e87ce1(2026-11-04)
- 属性: 据え置き
- 運用: ⑦回避可 — 既定の経路ではない(`settle: false` を使わなければ出ない)
- 優先度: 低 — ⑦は既定の経路ではない

出典: `_work/explore-20261104b/findings-*.md`(10周目・11/4)。⑦`settle: false` の flick の直後のワイルドカードの tap が、寄せの後に見失って赤(im4 F6)。原因(11/7): flick が返った 7ms 後の慣性の残る木で対象を決め、寄せの後に対象が縁の外へ出た(`settle: false` の既定でない経路なので据え置き)

### OI-181 iPhone SE3 でタブバーの下に潜った要素を、容器を送らずに断る
- 状態: 再現済み
- 確認: コミット未記録(2026-11-06)
- 属性: 据え置き
- 運用: ①回避可 — 文言の案内どおり、自分でスクロールして外してから押す(SE3 だけ)
- 優先度: 低 — 案内どおりの回避

出典: `_work/explore-20261106g/findings-*.md`(23周目・11/6)。①iPhone SE3(375x667)でタブバーの下に潜った `#btn_under_footer` を、容器を送って外さずに「#tab_controls が上にある・自分でスクロールしろ」と断る(phys F2・3/3。inapp-boost・xcuitest とも。iPhone 13 では緑)。原因(11/7): iOS の木に z が無いので覆いを外す送りは入らない(塗り順の無い木では手前を推測しない決定 = OI-170)。SE3 は対象が全部タブの下で `/hittable` が false なので断る・iPhone 13 は 10pt がタブの外にある

- 測った(2026-11-25・SE3 の実機・inapp-boost・E2E-iOS の覆い画面・3/3): in-app の当たり判定(`/touchlands`)は `#btn_under_footer` の中心への本物のタッチが**対象と `#tab_controls` の両方に届く**と答えた(タッチを受ける view は両者に共通の SwiftUI の入れ物)。半分のシートの裏の行(OI-170)と違い「対象に届かず覆いに届く」と言い切れないので、当たり判定を送りの根拠にできない(試した直しは取り下げた)= 据え置きのまま
- 別の形(2026-11-27・探索 phys F1・SE3 の実機・xcuitest モード・3/3): `setTextSize(.extraLarge)` で行が下がり、中心だけがタブバーにかかった `#nav_lifecycle` を `tap(…, scroll: .down)` が送らずに押して ✅(説明文に「the target's centre is covered by staticText "コントロール", so this may have hit …」・notes 無し)。実際にタブ「コントロール」が押され、次のステップで赤。断る形(対象が全部タブの下)と違い一部が外に出ているので押す。送らずに押した理由(`/hittable` が真だった等)は材料不足 = 据え置きのまま(覆いの警告は文言だけで判定を変えない = 新しい検知は警告から)
- 別の形(2026-11-27・探索3周目 iultra F1・iPhone 18 Pro(iOS 27.2)の Simulator・**xcuitest モード**・横向きの E2E-Flutter のテキスト入力・DSL 2/2): `tap("#btn_input_submit")` の中心がタブ「ホーム」の枠の中にあり、タブが押されてホームへ飛んだのに ✅(覆いの警告も notes も無い = SE3 の形と違い文言も出ない)。inapp-boost では「#tab_home が覆っていて人には押せない・in-app ブリッジで直接押した」の注記付きで緑。xcuitest で警告が出ない理由は材料不足 = 据え置き(既定のモードでは出ない)

### OI-186 iOS の `back()` が自前の「戻る」を押さず、戻らないまま緑になる
- 状態: 再現済み
- 確認: コミット未記録(2026-11-06)
- 属性: 据え置き
- 運用: 要注意 — 戻るボタンがナビゲーションバーの `BackButton` でない iOS の画面の `back()` は、戻らなくても緑(注記 `back-stayed-on-screen` が付く形と、付かない形がある)。自前の戻るがあれば `tap` で押し、`back()` の後は戻った画面を確かめる
- 優先度: 中 — 戻らずに ✅(後続で赤)

iOS の `back()` は画面に押せる自前の「戻る」(`#btn_back`)があっても、ナビゲーションバーの `BackButton` でなければ左端のスワイプに落ちる(28周目 iultra F1)。同じ画面に留まったら注記 `back-stayed-on-screen` を付ける(合否は緑のまま)。E2EY-Flutter(iOS inapp-boost)の入れ子スクロール・スワイプ・選択モードの画面では `back()` が戻らないのに ✅(注記なし・または「no effect」付き。27周目 im4 F1・各 3/3。後続は赤)。11/7 の観測: back は左端から右へのドラッグ(y=437)1本で、スワイプの画面ではそれが5行目のスワイプ操作を開いて識別子の組が変わり `back-stayed-on-screen` が黙る。Flutter の戻るは id=btn_back で `BackButton` の探しに拾われない
- 据え置きの理由: 自前の「戻る」を押すと、どれが戻るかを書き手でなくツールが決めることになる。注記で知らせる(11/6)

### OI-155 ft_batch の途中で別アプリが前面へ来た後の tap を ok と言い、前面を離れたことを言わずアプリの古い木を返す
- 状態: 再現済み
- 確認: コミット未記録(2026-11-03)
- 属性: 据え置き
- 運用: 要注意 — MCP の ft_batch だけでシナリオの実行には響かない。別アプリが前面へ来うる列は ft_batch で通さず、1手ずつ画面を確かめる
- 優先度: 低 — MCP の ft_batch だけ・直さないと決めた

出典: `_work/explore-20261103a/findings-*.md`(6周目・11/3)。冷えた状態から起動した設定アプリが手の開始から 3.8〜4.2 秒後に前面へ来た回で 7/7(MCP。2.2 秒後なら 422 で止まる 9/10 = batch F2)。各行の警告は「画面が変わらなかった」だけで、結論は「All 5 step(s) ran」。別アプリの起動後 1〜2 秒は `/appstate` が元のアプリを前面と答え続ける(検出の限界)
- 据え置きの理由(ユーザー決定 11/6): 待ちを足すと根拠の無い秒数を置くことになり、どの読みなら追いつくかも測っていない。飲まれた tap の警告(「another app had already come to the front」)で足りるとする

### OI-182 Android で別のアプリを launchApp した後の否定の検証が緑(注記付き)
- 状態: 再現済み
- 確認: コミット未記録(2026-11-06)
- 属性: 据え置き
- 運用: ①要注意 — Android で別アプリを `launchApp` した後の否定(`notExist`・`countIs 0`)は緑のまま、注記 `absence-checked-on-another-app` が付く。対象アプリを確かめるなら否定を書く前に戻す
- 優先度: 低 — 注記で知らせる・直さないと決めた

出典: `_work/explore-20261106h/findings-*.md`(24周目・11/6)。①Android で `launchApp("com.android.settings")` のように別のアプリを起こした後の `notExist`・`countIs 0` が緑(amax F3・4/4)。原因(report-mand): `launchApp(<別>)` は `appMayHaveLeft` を落とす(`FTRuntime` の `noteAppMayHaveLeft(false)`)ので門が照会せず、照会しても候補は起こしたアプリ(`lastLaunchedAppBundleID`)と対象のアプリ(`StepExecutor+AppLeftRefusal.swift` の `backgroundedAppRefusal`)で前面の起こしたアプリが通る = 起こしたアプリを対象と読む設計の帰結
- 据え置きの理由(ユーザー決定 11/6): 別のアプリを意図して検証するシナリオがあり、書き手の意図はツールに分からないので門は変えない。注記 `absence-checked-on-another-app`(`StepExecutor.absenceReadAnotherApp`)で知らせる

### OI-172 in-app の当たり判定が「中心に撃つと別の物に当たる」と名指ししても、合成タッチで撃って ✅ を返す
- 状態: 再現済み
- 確認: 6fd0771f(2026-11-05)
- 属性: 据え置き
- 運用: 要注意 — 撃って ✅ を返すが、後続の検証で赤になり、失敗文が覆い(NavigationBarContentView)を名指して直し方を案内する。押した後に結果を確かめる
- 優先度: 低 — 後続の赤が覆いを名指して直し方を言う・直さないと決めた

E2EY-RN の iOS(inapp-boost)の A1 入れ子スクロールで、`scrollDown()` の後に一覧の外へ出た先頭のカード `#card_3_00` を id で `tap` すると、注記が「a real touch at the centre of its frame lands on another view (NavigationBarContentView at (86, 110)) / activate did not fire -> synthetic touch」と言いながら撃って ✅、`#txt_nested_result` は `nested=none` のまま(手元8台で 8/8。後続の検証が NavigationBarContentView を名指して赤)。
- 試して取り消した直し(11/5・iOS v270): 撃つ前に合成タッチの受け手が要素と同じ窓の無関係な view なら断る = 上の形は 8/8 で断ったが、E2EY-RN の PIN/OTP(`#otp_box_3`。透明な入力欄が枠の上に重なり、そこに当たるのが正しい)で誤った赤。不透明なナビゲーションバーと透明な入力欄を見分ける材料が無い
- 据え置きの理由: 重なりは判定を足さず書き手を促す側で扱う決定(11/5)の範囲。記録は MN-108.4

### OI-170 塗り順の無い iOS の木で、覆われた・描かれていない要素を in-app が押す
- 状態: 再現済み
- 確認: 6fd0771f(2026-11-05)
- 属性: 据え置き・木に材料なし
- 運用: 回避不可(見逃し) — 人には押せない要素を in-app が押せるので、アプリの「覆われて押せない」不具合はテストでは見つからない(押した後の結果を確かめても緑)。user-docs に既知の制約として書いてある
- 優先度: 中 — 回避不可の見逃しだが、推測を足さないと決めた(ブリッジが塗り順を申告できるようになったら見直す)

SwiftUI・CMP・Flutter の iOS の in-app の木は塗り順 `z` を持たない(FD-1.4。RN と UIKit は `z` で断る)。XCUITest の木(MCP の iOS・DSL の xcuitest モード)も同じ。観測した形:
- 全開・半分のシートの裏の行への tap・doubleTap・hold が SwiftUI・Flutter・CMP で ok かキューの行に当たる(12周目 ilocal F18: CMP 11/11・Flutter 4/4 / iultra F1・F2・F6・F8)
- CMP の隠れるバー・縮み切ったヘッダの `#btn_top_action`・`#btn_follow` への触る操作が ✅(9周目 iultra F4・2/7・10周目 iultra F2)。隠れた間の木は容器を落とすのに中のボタンを固定領域の下に残し、固定領域の不透明な背景は木に無い
- はみ出した行の tap が別の部品に当たる(se3 F4)・隠れたバーのボタンは警告が出るが撃つ(sim F10)・Flutter の Android 横向きも同じ形
- E2EY-iOS(SwiftUI)の画面全体に半透明の幕を掛ける確認ダイアログの表示中、幕の下の `tap` / `type` が ✅ で下の要素に届く(22周目 im4 F2・6/6・3/3)
- MCP で RN の iOS の半分のシートの上端の下の行への `ft_tap` が警告なしで done・行は押されない(37周目 ilocal F2・6/6。MCP の iOS は XCUITest の木 = 塗り順が無く、覆いの slider も木に出ていない。同じ画面の DSL(inapp-boost の RN = z あり)は slider を名指して見えている部分を押す)
- RN のスワイプ行で同じラベルの「アーカイブ」が複数あるとき、MCP の iOS と xcuitest モードでは覆われた先頭(行1の裏)を撃つ(シナリオは `#btn_sw_archive_4` のように1つを名指す。inapp-boost の RN は z があるので露出した候補を撃つ)
- 据え置きの理由(ユーザー決定 11/4): 9〜11周目に木の順で手前を推測するたびに別の縁で誤った赤が出た。塗り順の無い木では手前の推測で撃ち方を変えず、中心を撃ち、後続が赤になったときに失敗の文言が覆いの疑いと直し方を言う。既知の制約として FD-2.1 と user-docs「覆われた要素を押した後は結果を確かめる」に書いた。探索ではこの形を新しい所見に数えない。見直すのは、ブリッジが塗り順か当たり判定を申告できるようになったとき
- XCUITest の `isHittable`(11/5): false は全部正しく、true は誤ることがある(SwiftUI の半分のシートの裏の行・CMP の縮んだヘッダでナビゲーションバーの裏の `btn_follow`)。そこで「撃つ点に別のスクロール容器の押せる要素が重なり、`isHittable` が false なら断る」だけを入れた(`TapTargetGeometry.otherLayerCoverSuspect`)。残るのは true が誤る2つの形
- 処理(2026-11-25): true が誤る形のうち SwiftUI の半分のシートの裏の行は、inapp-boost モードで true のときも in-app の当たり判定(`/touchlands`)を聞き、対象に届かず覆いに届くと言い切れたときだけ断るようにした(`TapTargetGeometry.touchLandsOnCoverInstead`・FD-2.1)。E2EY-iOS の `#row_main_08`: 直しの前は in-app が行を直接押して ✅(本物のタッチはシートのセルに届く)・直しの後は断る。対照の見えている背面の行・シートの行と、E2EY の CMP・Flutter・RN のシート・E2EX-iOS の FAB は緑のまま。残るのは xcuitest モード(当たり判定を聞けない)と自前描画(CMP の縮んだヘッダの `btn_follow` = 全要素が同じ view で対象にも届く)
- 棚卸し(2026-11-25 夜): 材料の候補あり。塗り順の分からない木で「対象の中心に重なるラベル付きの別の要素の文字が対象の枠に描かれている」を画素(OCR)で読む検知を検証の側に足した(`covered-by-front-element-read-on-screen`・OI-387)。同じ読みを in-app の撃つ前の確かめに使えば、覆われた要素を押す前に注意を出せる。検証の側の誤検知を次の全体の回帰で確かめてから、撃つ前へ広げるかを決める
- 次の一手の条件(2026-11-26): 検証の側の判定(`covered-by-front-element-read-on-screen`)の誤検知を全体の回帰で確かめた後に、押す前の確かめへ広げるかの判断をもらう(OI-205 ①の 11/10 のユーザー決定「押す前の OCR は入れない」と関わる。重なりがあるときだけに絞れば全 tap の費用にはならない)
- 処理(2026-11-26・DR-233): 撃つ前の確かめを入れた(塗り順の分からない木で、対象の枠に重なる要素の文字が描かれていれば注記。in-app の activate で押した回は「人には押せない物を押した」と言う)。ただし手元の SUT の形のうち、Flutter の iOS は既存の当たり判定が断り、SwiftUI はシートがモーダルで裏を木から外す = この確かめに来ない。CMP の縮んだヘッダの下に残る `#btn_follow` は in-app の木でラベルを持たず(自分の文字が無い = 読まない)、注記は付かないまま押されて ✅(11/26 に再現)。自分の文字の無い要素へ広げるかは、アイコンのボタンが文字の上に浮く正常な画面と見分けられるかを測ってから
- 材料の測定(2026-11-26・手元 Sim・E2EY-CMP の縮んだヘッダ): 非公開の AX の当たり判定(`_accessibilityHitTest:withEvent:`)は `#btn_follow` の中心で手前のナビバーの題名を、見えている行・手前のタブでは対象自身を返した(枠の少し外の要素を返すこともある = Compose の最小のタッチ領域)。→ `/touchlands` が答え(`axHit`)を返し、塗り順の無い木で対象の中心に別の要素が重なるタップだけ聞いて、別の要素が答えたら後続の赤の案内で名指すようにした(警告だけ・撃ち方は変えない・v319)。今回の inapp-boost の確かめでは in-app のタップが対象に届いて緑(案内の出る赤にならなかった)。ⓐ(xcuitest モード)は材料なしのまま
- 検証の所要(11/26): OI-200 と同じ回の測定 約5分 + 実装・テスト(OI-200 と一緒)
- 処理(2026-11-26・DR-234): ⓐ(xcuitest モード)は、撃つ前の OCR が重なる要素の文字を対象の枠に読めた回は撃たずに断る(ラベルの無い `#btn_follow` の形は自分の文字が無く読まないので対象外のまま)

### OI-140 存在しない `--scenario` 名でも、先に全台のブリッジの供給が走ってから「scenario not found」になる
- 状態: 再現済み
- 確認: dea279d5(2026-11-02)
- 属性: 据え置き
- 運用: 回避可 — 時間を損するだけ。名前を確かめてから回す
- 優先度: 低 — 時間の損だけ・直さないと決めた

11/2 の探索(1/1)。打ち間違えた名前で -04〜-08 のブリッジの起こし直しと再インストールが走り、他の作業の端末を巻き込んだ。ビルドが要らない回は供給の前に断る(`ScenarioPreflight.rejectUnknownScenarios`)。残るのはビルドが要る回(シナリオ一覧はビルドと並行に解決する作り)
- 据え置きの理由: 前回の一覧で照合すると新しく足したシナリオを誤って弾く。ソースの文字列での照合も誤って弾く恐れがある

### OI-58 枠なしの払い・探索の払いの始点が容器の外に落ちる
- 状態: 据え置き
- 確認: コミット未記録(2026-11-07)
- 属性: 据え置き
- 運用: 回避可 — 失敗文の案内どおり `scrollFrame` で一覧を名指せば通る形が多い(半分のシートの裏を探す形は `scrollFrame` でも赤で、回避の手は未確認)
- 優先度: 低 — 多くは `scrollFrame` で回避

**据え置きの理由(1回だけ)**: 始点を容器へ寄せる案は2度取り消している(`StepExecutor+ScrollFrame.swift` の「3度目は無い」)。複数の容器が残る画面は木に区別の材料が無く、当てずっぽうに選ぶと別の一覧を動かすので、赤 + `scrollFrame` の案内のまま据え置く。払い直し先は払う軸で絞った上で一意のときだけ(`ContainerGeometry.uniqueScrollContainer`)

形ごとの観測:
- 横向きで低い縦の一覧: 「nothing moved at all」の経路でだけ、唯一のスクロール容器の中で払い直すようにした(E2EY-Flutter の横向きの `#list_chat` で 0/3。修正を外した版で 3/3 が赤・修正ありで 0/3・`oi58-scrollto-low-list-landscape`)。容器が2つ以上の画面(E2E-Android のスクロール画面 = 高さ 94px の一覧とカルーセル)は払い直さず `scrollFrame` を勧めるだけで、枠なしの `scrollTo` は赤のまま
- 探索の pixel F7・F8 から: 枠なしの払いが一覧の外に落ちる(キーボードなしはブリッジ既定に任せる決定)
- OI-161 ③: E2EY-RN の A11 横向きの `tap("#post_39", scroll: .down)` が2回払っただけで「nothing moved at all」の赤(3/6)。in-app は UIPageViewController の下で 501 → XCUITest の固定の割合の払いの始点がヘッダの上。11/7: この SUT のヘッダは払いを一覧へ渡さない。行の上から払えば動く
- OI-161 ④: iOS の半開のシートの中を `tap(scroll:)` で探すと背面の一覧を送る(e2ey F2・iOS 12/12。`scrollFrame:` を付ければ通る)。in-app の path の無い払いは窓の中心の点を含む最小のスクロールビューを選ぶ = 背面の一覧。直すならホストが選んだ容器の中の点を path に載せる
- OI-163 ⑧: SwiftUI の横向きで高さ 0 に潰れた一覧の探索の払いが横のカルーセルを押す(land F3)。探索の3本目の短い払いの始点がカルーセルの帯
- 9周目 amax F1: CMP の Android の横向きの伸縮するヘッダで、上への払いが2回目以降動かない(素の `scrollUp()` でも。amax F1・6/6)
- 12周目の所見 ⑧: E2EY-Android の横向きで枠なしの `scrollUp()` が動かずに ✅(A10・4/4)。枠なしの払いの始点はブリッジが画面の高さの比率で決め、上への払い(`scrollUp()`)は 30% = 横向きで y≈384px の一覧の上の帯に落ちる(`scrollDown()` は 70% で一覧の中)。何も動かなかった送りには注記 `scroll-moved-nothing` を立てて ✅ で黙らないようにした(11/5)。`tap(scroll: .up)` の nothing moved の赤が逆向きの `scroll: .down` だけを案内し `scrollFrame` に触れない(A1・4/4)のは、`scrollFrame` の候補の案内が名指せる id を持つ容器があるときだけ付き、A1 の容器は id を持たないため。SUT の契約に id を足すかは判断
- 13周目 amax F2: E2EY-Android の A9 でシートを半分にしたまま背面の `本文 20` / `本文 39` を `tap(scroll: .down)` で探すと、背面の一覧が動かないまま「the scroll area reached its end」で赤・対処文は対象の居ない `#list_queue` を勧める(amax F2・10/10。`scrollFrame: "#list_main"` でも 4/4 赤)。E2EY-RN の Android でも同じ形(8/8)。探索の払いの始点がシートの上に落ち、1本目でシートが全開になり、以降は背面の一覧が動かず「端」と読まれる(`scrollFrame` を付けても始点は y=2209 でシートの下)
