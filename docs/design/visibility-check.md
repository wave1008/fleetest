# 設計: テキストの可視性検証

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 正典 | テキストの可視性検証(occlusion-guard)の段の構成・OCR の段・FM の段・起動直後の未描画画面・判定の控え・段の出口と副作用の表(DS-24) | 可視性検証の判定・段・待ちを変える前 | FM 呼び出し層の共通部分(→ [overview.md](overview.md) DS-1.1・DS-5)・PoC と実測(→ [../poc-fm-occlusion-guard.md](../poc-fm-occlusion-guard.md) OG・PT-3.5.1) |

`exist` の既定 `requireVisible` が、木の上では通ったテキストが画面に本当に描かれているかを画像で確かめる。
利用者向けの名前は「テキストの可視性検証」、プロファイルのキーは `fmTextVisibilityCheck`(FM の段)/
`ocrTextVisibilityCheck`(OCR の段)。触るときの規律は `.claude/rules/fm-occlusion.md`。

## DS-24 テキストの可視性検証

### DS-24.1 段の構成と入口

段は幾何 → インクの足切り → OCR → FM の順に見る。

- **Tier-0 幾何** = 収まる軸の中心が画面外なら不可視(`TapTargetGeometry.offscreenScrollGateCentre`。
  スクロール探索の「見つかった」ゲート・逆走査 `reverseSweep`・MCP の `ft_scroll_to` 再照合と同じ述語で、
  **文言は呼び手ごと**)。iOS の木は画面外の要素も frame ごと残し、FM 側は crop が
  画像の外に落ちると nil(素通り)なので、**通り過ぎた要素への exist は FM が生きていても FM では
  塞げない**(横スクロール区画で実際に起きた)。幾何の段は FM の有無に依らず
  `fmTextVisibilityCheck || ocrTextVisibilityCheck` の下で効く(`StepExecutor.visibilityGuardActive` が唯一の入口。FTRuntime の
  保持値の高速経路もこれを見る)
- **Tier-1 インクの足切り**を通って「訊く」と決まった crop だけが、OCR の段(DS-24.2)と FM の段(DS-24.3)へ進む

**FM の失敗は素通りになるが、黙らない**: FM 失敗時に nil を返して素通りする契約(DS-1.1)はこの検証にも掛かる。
そのため **FM に訊いたのに判定が返らなかったステップ**に `StepNote.visibilityGuardSkipped`(`visibility-guard-skipped`)を立て、
結果 JSON の `notes` から run 横断で数えられる(立てるのは FM まで到達した回だけ。マスタースイッチ OFF・
macOS 26・インクゲートで省いた回は「訊く必要が無かった」)。run 単位の公表は DS-5.4。

### DS-24.2 OCR の段(Tier-2)

インク足切りを通って「FM に訊く」と決まった crop に、まず
`FTCore.RegionText` が Vision OCR を当て、**期待文字列が丸ごと読めたら可視として素通り**させる
(FM を呼ばない)。crop 矩形は `FTCore.OcclusionCrop` を FM と共有するので、両者は同じ画素を見る。
FM の段に届く crop の大半がここで片付く(実測は OG-5.17・PT-3.5.1)。守る規律は4つ:

1. **丸ごと読めなかったことだけを反転の根拠にしない**(日本語モデルを載せると可視なテキストを 1 文字誤読する。PT-3.5.1)。
   FM の段(`fmTextVisibilityCheck`)が使えるときは丸ごと読めなかった回を**全部** FM に回し、
   `OCROnlyVisibility.merge` で**見えていると読めた側を採る**(赤は両方が見えないと言った回だけ。割れた回は注記
   `ocr-read-what-fm-missed` / `fm-read-what-ocr-missed`。OG-5.22)。FM の段が無い・使えないときは
   `OCROnlyVisibility` の判定だけで赤にする
2. **一致は完全含有だけ**(先頭一致を許すと、部分的に覆われて残りだけ読めた回を通してしまい誤った緑になる)
3. **読ませる言語は期待文字列から決め、言語補正は日本語の集合でだけ掛ける**
   (`RegionText.languages(for:)` / `usesLanguageCorrection(for:)`。ASCII の期待値に日本語モデルを載せると
   遅くなり誤読も増える = PT-3.5.1。en ロケールの端末は「単」を中国語フォントの字形で描き、補正なしだと「单」と読む)
4. **読めなければ拡大して読み直す**(`upscaleLadder = [1,2,3]`。×4 で悪化するので上げ続けない。
   **1行も読めない crop は段を上げない** = 覆いが消えるのを待つ poll 周回で毎周 3 回払わない)

版(revision)は固定せず OS の既定に従い、**版・認識レベル・言語補正・言語規則が動いたことの検出は
実 crop の固定コーパス**(`Tests/Fixtures/OcclusionCrops/`)が担う。既定 on・殺しスイッチは
`FT_OCCLUSION_OCR=0`・`measure` でコーパス採取(実測は OG-5.17)。

**①の例外は FM が判定を返さないときだけ**(実呼び出しの失敗。macOS 26 は OCR も使わない = `OCRSupport`・注記 `visual-text-check-unsupported`):
近道が読んだ行を `TranscriptMatch.judge` に通し、行が無ければインク量で分ける(`FTCore.OCROnlyVisibility`)。
不可視なら FM の反転と同じく赤(コーパス・E2E の誤った赤 0 を確認済み。実測は OG-5.19)。
**先頭だけ描かれた形**は `TranscriptMatch` が FM と OCR で共通に分ける: 省略記号 → 緑(`text-ellipsized`)/
割合 > 0.5 → 緑(`text-partially-hidden`)/ 以下 → 赤(ユーザー決定)。

**近道が本道より高くつかないための3つの門と、コンパイルの置き場**(MN-18): ①**モデルが載って実際に読めるまで近道は撃たない**
(`RegionText.isModelReady`。コンパイルの探りが 1 行以上読めた回だけ ready。Vision が `[]` を返し続ける日がある)/
②**諦めた読みが走っている間は撃たない**(`abandonedInFlight`。積み増すと 12 本が全部予算切れになり
戻った瞬間に協調スレッドプールが止まる)/ ③**予算 1.3 秒 = 置き換える相手(FM 照合)の実測下限**
(`RegionText.occlusionBudget`。尽きたら FM へ落ち注記 `ocr-budget-exhausted`。**諦めても読みは止めない**
= そのままコンパイルとして効く。合流点は `TaskBudget`)。判定は3つとも変えない(読めなかったのと同じ扱い)。

コンパイルの実体は Espresso(認識器)の **AOT コンパイル**で、キャッシュは
`~/Library/Caches/<プロセス名>/com.apple.e5rt.e5bundlecache` に**プロセス名と署名 ID で**鍵付けされ(SwiftPM の Debug ビルドは
ID に LC_UUID が入るので、`ScenarioHost.build` が ID を製品名に揃える。PT-3.33)、
**コンパイル(コールド 20〜45 秒 × 言語集合 2)がそのプロセスの生存中に終わったときだけコミット**される。
1 シナリオ = 1 プロセスの実行バイナリは終わる前に死んで `.tmp` を残すだけなので、
**run の開始時に同じプロセス名の待てる子 `fleetest-scenarios-<project> compile-ocr` を背景で 1 本起こす**
(`ScenarioHost.listForRun`。**その run で OCR の段か FM のテキストの可視性検証が有効なときだけ** = `ScenarioHost.ocrCompileNeeded`
(プロファイル・`--set` で両方を切った run では起こさない。機械分担の親は起こさず機械ごとの run が決める)。dry-run / MCP / codegen の一覧取得 `list` では起こさない・機械で同時に 1 本
= `OCRModelCompileLock`・**親の死を生き延びる** = `FT_PARENT_PID` を渡さない唯一の例外)。シナリオ側の探りは
同じロックを**待ってから**読む(8 レーンが同じモデルを同時に焼かない)。認識器は **ANE を避けて CPU/GPU**
に載せる(定常の所要は同じ 100〜160ms。判定の近道を FM フラップと同じ部品に依存させない。装置で読みが
変わる 1 行はコーパスに固定)。効果の実測は OG-5.17・PT-3.5.1。

### DS-24.3 FM の段: 転写 + ホスト照合

OCR で読めなかった crop に FM が答えるが、**FM に期待文字列は
渡さない**。訊くのは「何が描かれているか」(転写 1 欄・prompt は定数)だけで、可否は `FTCore.TranscriptMatch`
が期待文字列と突き合わせて決める(含む / 先頭 2 文字以上の切り詰め / 5 文字以上なら len÷5 の誤読・先頭文字
必須 / 末尾だけ = covered / 空 = notRendered / 無関係 = textMismatch)。等倍で読めなければ 2 倍で読み直し、
転写が 1 文字差で惜しいときだけ OCR に丸ごと読めたかを確かめる(素通りの向きだけ)。期待文字列を渡して
「見えるか」を訊く形にしない(空白・別の文字の crop でも期待文字列を写して visible=true と答える
おうむ返しになる。OG-5.18・MN-19)。

### DS-24.4 launch 直後の未描画画面は「覆い」と見分けられない

`restartApp` / `launchApp` は
木が引けた時点で戻るので、a11y の木は新インスタンスの要素を返しているのに画面はまだ
launch storyboard(全画素同一)ということが起きる。負荷の高いランナーでは描画が既定の待ち窓に
間に合わず、occlusion-guard が**正しく**「見えていない」と言って赤になる(実測: crop 265x100 が
全画素 (255,255,255))。そこで launch 系コマンドの直後だけ `StepExecutor.firstFrameGatePending` を
一度きり立て、**最初に FM の可視性判定が返った回**で消費する(可視でも消費 = 描画済みなら猶予は
要らない)。不可視かつ crop の `RegionInk.luminanceStdDev` が **`StepExecutor.firstFrameBlankStdDevCeiling`
(= 1.0。8-bit 輝度の量子化1段階未満 = ディザ・圧縮の揺らぎしか無く構造が無い、の定義であって
調整値ではない)未満**なら、そのステップの deadline を
**一度だけ**同じ式(`step.timeout ?? FlowStep.defaultWaitSeconds`)で延ばして待ち直し、
`first-frame-pending` を立てる。延ばしても一様色のままなら従来どおり赤にして `first-frame-timeout`
を添える。**通る経路は増やさない**(flip は返し続ける) —— 変えるのは待つ長さだけなので、
誤った緑は1つも作らない。**上限を厳密 0 にしない**(M1Max の launch storyboard は min=253 / max=255 = stdDev ≈ 0.1 で、0 では猶予が付かず赤になる。
`nearBlankPNG` の対照と、上限をリテラルで固定するテストで縛る)。**stdDev は Tier-1 のインク足切りを通らない経路(幾何が疑い有り・閾値 0)
では未計算**なので、門が開いている回だけ測り直す。

### DS-24.5 FM 判定の控え `VisibilityVerdictMemo`

occlusion-guard の FM 判定を、
**FM への入力そのもの**(スクショのバイト列の hash・frame・screen・期待文字列)を鍵に控える。
「読む回数を減らす」ので、2回目の読みが担っていた砦を列挙してある —— ①画面が変わった
(→ バイト列が変わり鍵が外れるので控えは効かない)②要素が動いた(→ frame が変わり鍵が外れる)
③期待値が違う(→ 鍵が外れる)④FM の死活・ブレーカの回復(→ nil は控えないので次は必ず訊く)。
残るのは「同じ画像・同じ領域・同じ文字列に FM が違う答えを返す」だけで、FM は同一画像に
決定的(92_screenLooksLike の実測)なのでそこに砦は無い。**控えは直近のスクショ1枚ぶん**
(バイト単位で変わった瞬間に丸ごと捨てる = 上限の定数を置かない)。効く場面は `select(...).textIs(...)`
のように同じ要素を続けて確かめる書き方 —— textIs が保持値を再検証するのは「検査を静かに消さない」
ための設計(FTRuntime の保持値の高速経路)で、控えはその検査を**同じ答えで**満たすだけ。
理由: E2E-iOS ジェスチャ S0010 は FM 60 回中ほぼ半分がこの重複で、FM の遅い M1Ultra では
180s の予算を超えて kill された。

### DS-24.6 段の出口と副作用の表

`StepExecutor.occlusionFlip` → `occlusionFlipOnScreen` の**書き順**がそのまま段の順になっている(宣言は無い)。
各行は上から順に評価され、「出口」が緑(nil = 素通り)・赤・次へのどれかを決める。**段を足す・外す・並べ替える前に
この表を直し、`VisibilityCheckCharacterizationTests` の等号を通す**(行ラベル V1〜V24 はテストの doc と対応)。
門 = 起動直後の画面待ちの門 `firstFrameGatePending`(DS-24.4)。「消費」は `consumeFirstFrameGate` を通る出口。

| 行 | 段 | 入る条件 | 出口 | 注記・書き換える状態 | 門 |
|---|---|---|---|---|---|
| V1 | 入口 | `visibilityGuardActive` が偽 | 緑 | なし(`guardEnteredThisStep` も立てない) | 残す |
| V2 | 画面外 | 中心が画面外(`offscreenScrollGateCentre`) | 赤(offscreen) | `guardEnteredThisStep` | 残す |
| V3 | 覆いの下 | 塗り順が本物の木で `coveredTouch` が tooThin | 次へ | `coveredByFrontElement` | — |
| V4 | 行の確かめの判定 | iOS・OCR の段あり・文字の子の無い行 | 次へ(V17 で決める) | 最後の判定で `rowLabelNotRead` を付け外し | — |
| V5 | 文字の子へ | 同じラベルの文字の子が1つ | 次へ(以降は子を見る) | — | — |
| V6 | 段なし | FM の段も OCR の段も無い | 緑 | — | 残す |
| V7 | 退化枠 | 幅か高さが 1 未満・期待が空 | 緑 | — | 残す |
| V8 | 枠の復元 | Compose が削った枠 | 次へ | `a11yFrameRestored` | — |
| V9 | 対象の足切り | `OcclusionEligibility.eligible` が偽 | 緑 | — | 残す |
| V10 | 古い絵(新規撮影) | 撮り直しても `StaleFrameDetector` が古い | 緑 | 期待が OCR で読めれば `staleFrameTextVisible`、読めなければ `staleScreenshot`・`knownStaleGuardImageHash`・`guardFrameStaleThisEval` | 残す |
| V11 | 既知の古い絵 | 前に古いと見た絵のまま(使い回しの絵を含む) | 緑 | V10 と同じ | 残す |
| V12 | インクの足切り | 幾何の疑いなし・容器の縁でない・閾値 > 0・stdDev ≥ 閾値 | 緑 | 文字の型なら `pixelsShowedTextThisStep`・`lastGreenTextByElement` | **残す** |
| V13 | 黒い絵 | `isBlackApartFromSystemBars` | 緑 | `blankScreenshot` | 残す |
| V14 | WebView の取り逃し | 木で覆われていない・WebView の内側が一色 | 緑 | `webViewCaptureBlank` | 残す |
| V15 | OCR のコンパイル待ち | OCR の段あり・未 ready・詰まりなし | 次へ | `ocrCompileWaited` / `ocrCompileCapped`(待ちは締め切りから差し引く) | — |
| V16 | OCR の近道 | `shouldTakeShortcut` | 丸ごと読めて mode on なら緑、他は次へ | `pixelsShowedTextThisStep` / `ocrBudgetExhausted` / 見送りは `ocrShortcutBusy`・`ocrShortcutNotReady` | **残す** |
| V17 | 行 | V4 が真 | 読めた文字に期待が無ければ赤、他は緑 | (V4 の注記) | 残す |
| V18 | FM が使えない | FM の段なし・画像入力なし・無回答の注入 | `OCROnlyVisibility`: 可視 → 緑 / 不可視 → 赤 / 判定不能 → 緑 | 可視は `pixelsShowedTextThisStep`・部分の注記、不可視の notRendered は `lastNotRenderedFrame`、OCR も非対応なら `visualTextCheckUnsupported` | 可視・不可視で消費、判定不能は残す |
| V19 | 判定の控え | 同じ絵・枠・期待(`VisibilityVerdictMemo`) | 次へ(FM を呼ばない) | — | — |
| V20 | FM 無回答 | FM が nil を返した | V18 と同じ(控えない) | `visibilityGuardSkipped` を加える | V18 と同じ |
| V21 | 空の転写の確かめ | FM 不可視・転写が空・領域に構造 | OCR の確認か訊き直しで読めたら緑、他は次へ | `ocrReadWhatFMMissed` / `fmEmptyTranscriptOnInk`・`fmReaskedEmptyTranscript`(控えを読めた答えへ・同じ絵に1回 = `reaskedEmptyTranscripts`)/ 失敗文の事実 | 読めたら消費 |
| V22 | 突き合わせ | 以降すべて | `OCROnlyVisibility.merge` で可視なら緑 | 割れた注記・部分の注記・`pixelsShowedTextThisStep`・全部見えたら `lastGreenTextByElement` | **ここで消費**(可視・不可視とも) |
| V23 | 前の値の古い絵 | FM の文字が同じ要素の1つ前の緑の値 | 緑 | `staleScreenshot`・`knownStaleGuardImageHash`・`guardFrameStaleThisEval` | (V22 で消費済み) |
| V24 | FM の赤 | 上のどれでもない | 赤(on screen) | notRendered なら `lastNotRenderedFrame` | (V22 で消費済み) |

**待ちのループ側**(`executeAssertExists` / `executeAssertTextComparison` に同じ形で2回ある): 赤が締め切りを跨いだら、
①遅い木の撮り直し(`SlowSnapshotBudget`)②門が一様な絵を見た回(`firstFrameBlankObserved`・`first-frame-pending`)
③1回目のガード評価が締め切りを跨いだ回(`guardCostExtended`)の順に、それぞれ1回だけ締め切りを延ばす。
`select`(`StepExecutor+Actions`)は延長せず、見えないと出た回だけ木と絵を1回撮り直す。

**表から見える未決の点**(挙動は変えずに残してある。直すなら原因を観測してから): 門は「判定が出た回に消費」
(DS-24.4)だが、V12・V16(可視と決まった緑)と V2・V10・V11 は消費しない。門は次の launch まで残り、後の
ステップの一様な絵に延長を与えうる(延ばすのは待つ長さだけで、合否は変えない)。
