# fleetest

## 読者の分岐(最初に判定する)

- **このツールを「使う」だけ**(自分のアプリのシナリオを書いて実行したい。ツール本体は改造しない):
  `/fleetest-setup` スキルに従ってセットアップする。手順の全体像は docs/user-docs/quick-start_ja.md。
  **以下の保守者向けルール(委譲方針・コメント規約・i18n・ソース分割等)は適用しない。**
- **このツール本体を「改造する」保守者**: 以下すべてが適用対象。

**この文書は規則だけを持つ。**「なぜその形なのか」「一度実際に壊した記録」は
**docs/maintainer-notes/**(規則を緩めたくなったときに読む)。subsystem の設計・計測は
各 docs が正典。

## ドキュメント

**どの文書に何があるか(読む場面ごとの索引)と書き方の規約は docs/README.md**。ここには文書を
直すときの規則だけを置く。

- **利用者向けドキュメント(Shirates 流の en/ja 対)は docs/user-docs/**。入口は `index.md` /
  `index_ja.md`。1ページ = `<name>.md`(英)+ `<name>_ja.md`(日)で**片方だけ変えない**(`userDocsIntegrity.test.mjs`)。
  DSL の挙動を変えたら docs/commands.md と併せて該当ページも直す
  ・**`## 注意点` の項目や「現時点の制約」を足したら `reference/writing/known_caveats(_ja).md` にも1行足す**(シナリオを書く AI が
  必ず読む一覧。`knownCaveatsIndex.test.mjs`)
- **README.md(英)/ README_ja.md(日)は入口だけ**(何か・必要環境・利用者と保守者の入口)。仕様を書かない ——
  仕様は user-docs と docs/ に置き、README からは指すだけ
- **受け手の配布口は最新リリースタグ**・main は開発線で版固定の導線は案内しない。`FLEETEST_REF` は
  保守者のブランチ検証口(docs/releasing.md)
- フレームワークで挙動が割れる変更を入れたら docs/framework-differences.md の表に1行足す
- コマンドを足す/名前を変えるときは docs/shirates-parity.md も更新する
- 残件を直したら docs/open-issues.md の項目を消す
- ユーザーの決定(方針・不採用・トレードオフ)を足す/変えるときは docs/decisions/ の DR を足す/直し、本文からは `DR-n` で指す
  (載せる基準と欄は docs/decisions/README.md)

### 失敗の記録と操作の規律

- **失敗の記録に置くのは事実だけ** —— フェーズ(`section`)・コマンド名(`command`)・
  経路(`failureKind`)・注記(`notes`)。**「環境要因の失敗」という分類は置かない**
  (アプリが重いのかマシンが混んでいるのかツールには区別できず、推測は誤った緑・赤を作る。
  DR-1)。**言えないときは欄ごと省く**(「その他」に丸めない)。
  `command` を description から切り出さない・`failureKind` をエラー文言の一致で決めない
  (どちらも書式を変えた瞬間に静かに壊れる。仕分けは `DriverError` の case で行う)。
  渡し忘れは `CommandNamePlumbingTests` がソース走査で落とす
- **届いたか分からない操作は撃ち直さない**(DR-136。届いていた場合に二重実行 = 送信・購入で取り返しが
  つかない)。**届いていないと確定している操作は撃ち直してよい** —— 確定の根拠はブリッジが構造化した理由で返す
  断り(`ErrorResponse.reason` = `stale-ref` / `system-alert-blocked`。撃つ前に断った・XCTest が合成せずに諦めた)だけで、
  文言の一致・所要時間・画面の無変化からは確定と言わない。途中まで届きうる操作(入力・ダブルタップ・ドラッグ)には理由を付けない。
  ツールが閉じるのは**ステップ開始時点で出ている割り込み**と、**届けずに断られた操作の直前に出た登録済みのアラート**まで
  (加えて前のシナリオが残したアラートを開始前に消す = `.claude/rules/executor.md`)。**届いたか分からないまま間に湧いた分の
  復帰はシナリオ側**(docs/commands.md §割り込みが「操作を吸った」ときの扱い)。
  **届いたか分からない操作の自動リトライを再提案しない**

### fleetest 自身の E2E(SUT)

SUT は3系統 × UI フレームワーク5つ(CMP・SwiftUI・View/XML・Flutter・RN): **E2E**(画面・`#id`・ラベルは全 SUT 共通契約。`Scripts/e2e.sh`)/
**E2EX**(定番部品。`Scripts/e2ex.sh`)/ **E2EY**(判定を直撃する作り・罠は意図して残す。`Scripts/e2ey.sh`)。表と契約は `.claude/rules/e2e-sut.md`


## 領域ごとの規律(`.claude/rules/`)

**領域に固有の規律は `.claude/rules/<領域>.md` にある**。その領域のファイルを **Read ツールで**読むと
自動で読み込まれる(サブエージェントにも届く)。**読み込まれないのは3つの場合** ——
grep やシェル(`cat`)で見るだけのとき・新しいファイルを読まずに書くとき・設計や方針を相談するとき。
**そのときは該当する規則ファイルを先に Read する**。

**`AGENTS.md` は他のエージェント向けの入口で、規則の本文を書かない**(`claudeRulesIndex.test.mjs`)。

**規則を足すときの置き場**: どの作業でも効く規則(検証の進め方・判断の規律・コメント規約・
「どこであれ新しいものを足すとき」の規律)だけをこのファイルに置き、特定の領域のファイルを触るときに
効く規律は該当する `.claude/rules/<領域>.md` へ足す(frontmatter の `paths:` がその領域のファイルを
指しているか確かめる)。**このファイルを肥大させない** —— 全セッションと全サブエージェントが毎回読む(実測は MN-52。上限は `claudeRulesIndex.test.mjs`)。

| 規則ファイル | 領域 |
|---|---|
| `.claude/rules/android.md` | Android(Play Protect・テキスト注入) |
| `.claude/rules/app-framework-scroll.md` | UI フレームワーク判定・容器推定・スクロールの端 |
| `.claude/rules/bridge-provision.md` | ブリッジ(版・ポート・供給) |
| `.claude/rules/device-health.md` | デバイスの健康状態(凍結) |
| `.claude/rules/docs.md` | 保守者向けドキュメント(索引・書き方・節の ID) |
| `.claude/rules/dsl-commands.md` | DSL コマンド(索引・引数名・スクロール指定・操作の待ち) |
| `.claude/rules/e2e-sut.md` | fleetest 自身の E2E(SUT) |
| `.claude/rules/executor.md` | StepExecutor(実行時設定・失敗の文言・システムアラート) |
| `.claude/rules/fm-occlusion.md` | FM・テキストの可視性検証(occlusion-guard / OCR) |
| `.claude/rules/gesture.md` | ピンチ・座標ジェスチャ |
| `.claude/rules/installer-agents.md` | 受け手フローのスクリプト・エージェント連携・配布 |
| `.claude/rules/live-control.md` | ライブ操作 |
| `.claude/rules/mcp.md` | MCP サーバ(ft_*)と Bench |
| `.claude/rules/process-lifecycle.md` | プロセスの生存管理(終了猶予・Shell.run・台帳) |
| `.claude/rules/profile.md` | 実行プロファイルの --set |
| `.claude/rules/remote.md` | リモート(SSH ディスパッチ・監視の fan-out・ロックと待機列・占有) |
| `.claude/rules/results-retention.md` | 結果 JSON・run ボード・保持容量の掃除・LPT |
| `.claude/rules/selector-snapshot.md` | セレクタ・スナップショット・自己修復(指紋照合) |
| `.claude/rules/vision.md` | 画像(findImage / checkIsON / 画像分類) |
| `.claude/rules/vscode-i18n.md` | VSCode 拡張(ビルド・ソース分割・i18n) |
| `.claude/rules/webview-dom.md` | WebView / ブラウザの DOM |

**どこであれ新しいものを足すときの規律**(ファイルが決まらないので読み込まれない。詳細は各規則ファイル):
- 子プロセスを起こす経路を足す → 中断のリレー(`InterruptRelay`)・fleetest を起こすなら
  `ParentDeathWatch.childEnvironment()`・ssh 越しなら非対話 PATH の補正・`-tt` の ssh は
  `ParentBoundCommand` で包む(process-lifecycle.md / remote.md)
- fleetest 自身の実行ファイル(隣の製品を含む)を子として起こす → `ExecutablePath.current` / `.resolved`(実体のパス。`.build/debug` は
  SwiftPM がビルドのたびに作り直すリンクで、その間 ENOENT。`Bundle.main.executableURL` の直読みは `ExecutablePathTests` の許可表)。拡張は
  `resolveBinaryPath` が実体へ解決する → MN-82.8・MN-82.9
- 子プロセスのパイプを読む → `readDataToEndOfFile` を使わない・`availableData` のループは
  `autoreleasepool` で区切る・生死判定は `ProcessLiveness.isAlive`(process-lifecycle.md)
- 外部コマンドの出力から値を作る → **終了コードを見る**(`Shell.run` は非ゼロで投げない。
  `Shell.Result.outputIfSucceeded`。失敗の出力から「無い」「止まった」が確定する。`ToolOutputStatusScanTests`)
  → MN-56.10
- FM を呼ぶ → `FMCallAdmission` を通す・オンデバイスだけ・**画像を伴う呼び出しは FM の常駐プロセス(`fleetest api fm-serve`)へ頼む**
  (自分で `LanguageModelSession` を作らない。fm-occlusion.md → MN-81)
- MCP のツール・引数を足す → `ArgumentBounds` に載せる・ツールの集合を固定するテスト
  (`MCPToolCallTests` の driverBackedTools 等)を更新する・DSL と同じ判定は共有する・下書きに DSL の行を残すか
  (残さないなら理由)を `MCPDraftCoverageTests` の表に載せる(mcp.md)
- compose.yaml に読めるキーを足す → `ComposeNormalizer` の許可表・`ComposePolicy` の検査・`ComposePolicyTests` / スクリプトの中継
  `fleetest-services` に動詞を足す → `ServicePolicy` と `ServicePolicyTests`(executor.md)
- ブリッジの挙動・エンドポイントを変える → 版を上げる(iOS `bridgeProtocolVersion` / Android
  `VERSION_CODE`。`BridgeContractTests` が落ちたらそこで上げる)・XCUITest を触ったら `--ios-xcuitest`
  (bridge-provision.md)
- 実行時設定を足す → `ScenarioExecutionSettings` の1箇所(executor.md)
- inapp-boost モードで XCUITest ブリッジへ回す問い合わせを足す → `AppAttachDriver` でランナーのセッションを確かめてから撃つ・
  「答えられない」に畳む経路は畳んだ事実を注記に残す・**inapp-boost のデバイス実行で1回通して効いたことを文言で確かめる**
  (偽ドライバの単体テストは通らない。bridge-provision.md)
- DSL コマンドを足す・改名する → docs/shirates-parity.md・`ft_batch` のキー・引数名は `waitSeconds:` 等の規律(dsl-commands.md。
  索引と docs の漏れは `CommandIndexSyncTests` / `CommandDocsCoverageTests` が追記先付きで落とす)
- 受け手のフロー(install.sh・スキル)を変える → SKILL.md のステップ番号と 1:1(`installStepSync.test.mjs`)・
  受け手のファイルを書くのはステップ7.6 の入口だけ(installer-agents.md)
- シナリオ実行バイナリを起こす経路・子が書く場所・子からの `simctl` / `devicectl` / `adb` の呼び出しを足す → サンドボックスの
  入口(`ScenarioHost.sandboxedLaunch`)・`ScenarioSandbox.writablePaths`・`SimctlPolicy` / `DevicectlPolicy` / `AdbPolicy` にも足す
  (executor.md。常に有効なので漏れはデバイス実行で赤になるか、黙って効かなくなる)
- 「キーボードが出ているか」を読む → `KeyboardWait.isShown` / `shownState`(`keyboardFrame != nil` と書かない = 隠れたキーボードは
  画面の外の矩形で来る。`KeyboardShownJudgmentTests`)/ シミュレータのアプリを「止めた」と言う・止めてから壊す →
  `BridgeClient.stopOnSimulator`(ランナーの terminate はセッションが起動したアプリにしか効かない。`ClearAppDataContractTests`)
- iOS Simulator を起動する経路を足す → **`SimulatorBoot.ensureBooted(udid:log:)` を通す**(起動前の掃除 `SimulatorBootCleanup.beforeBoot(udid:)` と、機械全体で同時2台の枠 `SimulatorBootSlots`。直接 simctl boot / bootstatus を撃たない = `SimulatorBootSingleEntryTests`・`SimulatorPosterCachePurgeWiringTests`。DS-12.4.2・DS-12.4.3)
- モニターの周期に計測を足す → 周期の中で待たない(裏で回して控えを読むだけ。`DeviceStorageSampler`)→ MN-55
- 待ち受けのソケットを足す → `FTCore.AcceptLoop` を通す(**fd を閉じるのは、その fd で待っているスレッドだけ** = 別のスレッドが閉じると
  番号が再利用され、受付が無関係の待ち受けの接続を奪う。中継中の接続も一覧から外してから待っていた側が閉じる。`AcceptLoopTests`)
  → MN-96
- 並行なクロージャ(Task・concurrentPerform・完了ハンドラ・Thread)へ値を渡す → 捕捉した `var` は `FTCore.LockedValue`、
  スレッド安全の契約が無い呼び手の log / emit は `SerializedSink`、子タスクへ渡す非 Sendable(主に `AppDriver`)は
  `UncheckedTransfer`(`Sources/FTCore/LockedValue.swift`)。`@unchecked Sendable` には守っている不変条件を1行書く。
  **in-app dylib に単体でコンパイルされるファイル**(`InAppBridge/build.sh` の一覧)からは FTCore の他の型を使わない → MN-66

## ビルド・検証

**検証の詳細な罠と判定規律(flake/性能の判定・macOS/Xcode ベータ整合・常駐プロセス掃除・
「Application is not running」全滅時の切り分け・`Scripts/e2e.sh` の各オプション)は docs/verification/**。
以下は毎回効く最重要ゲートだけ。

### Swift

- **単体テストの全体は `FT_FULL_TEST=1 Scripts/unit-tests.py`**(テストクラスごとに1プロセスの並列。`swift test --parallel` を
  使わない理由と実測は docs/verification/judgment.md)。**絞った実行は `swift test --filter <Class>`**。
  **5 SUT のシナリオもこのビルドで型チェックされる**ので、DSL の改名・シグネチャ変更の
  追随漏れもこれで捕まる。別途ビルドが要るのは変異テストの直後に製品バイナリを作り直すときだけ
  (`swift build --product <名>`)
- **クラス単位で回すので、同じプロセスの中で前のテストの状態が残る**(`swift test --parallel` では1件1プロセスで
  見えなかった)。プロセス内の控え・static を使うテストは、テストごとに捨てる(例: `CheckStateClassifierTests` の
  `invokeTest`)。完了の行が出ないテストもランナーが赤に数える
- **テストとデバイス実行の範囲は PreToolUse フック `Scripts/test-scope-guard.py` が撃つ前に検査し、断るときは理由と代わりを返す**
  (`.claude/settings.json` は git 管理外なので**クローンごとに登録する**)。全体テストは作業の区切りにユーザーが回す運用 ——
  **全実施を頼まれたときだけ**コマンドに `FT_FULL_TEST=1` を書く
- **合否は exit code で見る**(パイプすると grep 等の exit code に化けて失敗を握りつぶす)
- **並列はテストプロセスを分けるので、ホストの共有資源に触るテストは自分で隔離する**
  → MN-4.9。**隔離できないホストの実体**(simctl/adb・起動中の Simulator/Emulator・
  固定パス)と、`.fleetest/` の台帳・`DiagnosticReports` の走査は
  `Sources/FTTestSupport/SharedResource.swift` の `SharedResource.<key>.locked { }` で
  資源キーごとに直列化する(詳細は docs/verification/judgment.md)
- 実行ファイル差し替えは `swift build --product <名>`。`--target` はリンクせず旧バイナリを実行する

### デバイス実行(E2E)

- **`fleetest bridge down --all` を頻繁に打たない**。1回ごとに XCUITest ランナーの `xcodebuild` が
  全台ぶん走り、他セッションや監視が使う端末も巻き添えにする。**打たずに済む順序で組む**:
  **①ブリッジに触る編集を全部終えてから版を1回だけ上げる** / **②起動し直しは使う端末だけ**
  (`bridge down --port <N>`)/ **③版ガードに弾かせる**(古いブリッジは明示的に落ちるので
  **弾かれたポートだけ**起動し直す)/ **④起動し直しの要らない段から検証する**(単体テスト →
  dry-run → 生きているブリッジ1台での MCP 確認 → 最後にデバイス実行)。
  **ワイヤ形式(DTO の enum・フィールド)を変えたら必ず版を上げる**
- **回帰は `Scripts/regress.py` で全マシンを回す**(E2E・E2EX・E2EY。docs/verification/operations.md)。
  **使わないときは E2E をこの Mac(M2Ultra)で・E2EX を M1Ultra で同時に回す**(DR-127。この形は E2EY を回さない):
  `Scripts/e2e.sh --local`(手元のデバイスだけ)と `Scripts/e2ex.sh --on M1Ultra`(ssh でランナーの
  クローンに入り、そこで SUT をビルドして回す)を同時に起こす。先に `Scripts/align.sh M1Ultra`
  (手元の作業ツリーを未コミットのまま直送する。push もコミットも要らない)。E2EX の SUT は M1Ultra でビルドする(競合しない・負荷分散)
- **1シナリオの確認にフリート全台を用意しない**。`ProfileRunner` は回す本数から台数を絞る
  (`ResolvedProfile.deviceKeepCount` = 本数ぶん)。**予備は置かない**(欠けた台のぶんは残りの台が消化する。
  実測と不採用理由は MN-103。DR-146・DR-147)。
  **例外は `--broadcast`** —— 各デバイスで1回ずつ回すのが目的なので絞らない(分配だけ
  `ScenarioDispatch.broadcast` に差し替え、他は同じ経路)。`fleetest api run` と、ビルドが要る回の
  `fleetest run --profile` はシナリオ一覧をビルドと並行に解決するので一覧を待てない —— 確定している `--scenario` の指定
  だけで判断する(`ApiRun.exactScenarioCount`)
- **E2E 実行中に `swift build` / `swift test` を打たない** → MN-4.1。
  **E2E を投げたらビルドを伴う作業は止める**。**例外は単一のリモートへのディスパッチ**(`run --runner <機>`・
  デバイスが全部1台のリモートにあるプロファイル)と `e2ex.sh --on` —— 前者は中継役を一時ディレクトリのコピーから
  動かす(`DispatchSelfCopy`)、後者は手元で fleetest を動かさないので、回している間も手元でビルドしてよい
- **モニターを止めるのは性能を測るときと、`Scripts/regress.py` の回帰だけ**(DR-2。regress.py は自分で止めて戻す)。
  止めるのは `fleetest monitor pause [--for <分>]` / 再開は `resume`(kill では拡張が数秒で起動し直す。効くのはこの機械だけ)。
  **配信は遅くするだけでなく落とすので、赤が出たら真っ先に配信の有無を疑う**(判定材料: run.json の `workerAnomalies` の
  `degraded` / `requeued`。実測と旧手段は docs/verification/operations.md「モニターと E2E」)
- **長時間ジョブ(E2E 等)の完了を「プロセスの生死」で待たない** → MN-4.2。
  **ジョブ自身が出す成果物で待つ**:
  `nohup bash -c '<job> > log 2>&1; echo "exit=$?" > log.done' &` で起動し `log.done` を待つ。
  併せて**起動を報告する前にログの実在を確かめる**(「開始しました」は観測ではなく期待になりやすい)

### e2e.sh を回す条件

- **DSL コマンド・`StepExecutor`・ドライバ・ブリッジ(`InAppBridge`/`Runner`/`AndroidRunner`)・
  セレクタ/スナップショット/自己修復(指紋照合)/FM 呼び出し(`FTFoundationModels`)を変えたらデバイスで回す**
  (ユニットテストはデバイス境界のバグを1つも捕まえない。範囲は下の表)。**ブリッジのスナップショット/型写像と、
  StepExecutor の操作合成(タップ/ドラッグ/スクロール探索の終端処理)を触ったら SUT を絞らず全部**
  回す(フレームワーク差の退行は SUT を跨がないと出ない)→ MN-4.4.1
- **既定の e2e.sh は iOS を inapp-boost モードで回す**(**利用者の既定も inapp-boost モード**
  なので、既定スイートが見るべきはそちら)。**フル E2E はモード・SUT・OS を指定しない `Scripts/e2e.sh` だけ**
  (xcuitest は含めない。置き場の指定 `--local` / `--align` は可)。**XCUITest ブリッジを触ったときだけ xcuitest モードを
  的を絞って回す**(`fleetest run --profile ios-xcuitest --scenario <クラス>`)。
  モード指定(`--ios-inapp-boost` / `--ios-xcuitest`)は **iOS だけを回す**(Android にモードの
  選択肢は無いので既定スイートと同一の実行を二度払うだけ)。OS の絞り込みは `--ios` / `--android`
- **この漏れは e2e.sh が警告する**(落とさない)—— **回さなかった側**のブリッジ入力集合(`BridgeSourceSet`)の
  digest を、そのモードの実行が**全部成功したときだけ** `.fleetest/<bridge>-e2e-verified` へ記録し、
  開始時と終了時に食い違いを警告する。経緯は docs/verification/operations.md → MN-4.5

**e2e の実行範囲はリスクとコストで決める**(上のゲートは「デバイスで回すか」の下限で、
常に全部回す意味ではない。フルスイートは10分超かかるので、**何も足さない実行はしない**)。
範囲の欄のシナリオは **`fleetest run --project <P> --profile <prof> --scenario <クラス>` で、変更が通るものを名指しする**
(`e2e.sh` 系は絞ってもスイート全体を回す):

| 変更の性質 | 範囲 |
|---|---|
| 改名・シグネチャ変更・型に閉じたリファクタ | **単体テストだけ**(`swift test --filter`。全体を頼まれたら `Scripts/unit-tests.py`)。追随漏れは必ずコンパイルエラーになる |
| ホスト側ロジック(`StepExecutor` の分岐・セレクタ解決) | `swift test` + **該当シナリオ1〜2本** |
| ブリッジの挙動(注入) | 該当 SUT の**1プロファイル**で通るシナリオ。フレームワーク差が絡む・スナップショット/型写像なら全 SUT の同じ画面 |
| 入力・キー・IME 系 | 上記 + **xcuitest モード**(`--profile ios-xcuitest`。既定は inapp-boost モードなので、もう片方のモード) |
| **幾何・容器推定・整定**(実ジェスチャの慣性で挙動が変わるもの) | 上記 + **xcuitest モード**。**in-app ブリッジは慣性を持たない**ので、この種の退行は既定スイートでは原理的に出ない(MN-4.5.1) |
| flake 調査・性能 | 該当プロファイルを**反復10周**(docs/verification/judgment.md) |
| run 制御(再キュー・ワーカー離脱など。シナリオ実行の中身を触らない) | `swift test` + **その経路を強制的に通す陽性対照**。緑の run では1度も実行されないのでフルは情報ゼロ |
| リリース前・大きな統合の締め | **フルスイート = `Scripts/e2e.sh`(引数なし)だけ** |

**回す前に「それで何が検証できるか」を言えること**。判定はひとつ ——
**その変更は緑の run で1度でも実行されるか**。実行されないなら、フルは 10 分を捨てるだけで、
代わりに要るのは**経路を強制的に通す陽性対照**。

### 判定の規律

- **直す前に原因を観測する** —— 症状(誤った緑・取りこぼし)の観測は原因の観測ではない。原因を示す事実(デバイスの木・照会の答え・ログ・仕組みのコード)を所見に書けたものだけ直す。書けなければ**直さず**、測る口を足すか「材料不足で据え置き」と書く(**「判定できない」は正当な結論**)。材料の無い所を型・深さ・木の順・閾値で埋める直しは、別の画面で誤った赤になって戻ってくる。サブエージェントの報告の原因も、根拠の事実が付くまで推測として扱う。**1つの形の観測を判定の規則にするなら、効かない側の形(反例)を同じ材料で見分けられるかを既存の SUT で先に確かめる**(見分けられなければ判定にしない) → MN-108
- **特定のアプリに特化した直しを採用しない**(DR-3)。1つのアプリ(地図・天気等)で観測した失敗でも、判定・自動の操作・待ちの条件を**そのアプリの形(id・ラベルの語・表記・寸法)に合わせて書かない** —— 条件は形の一般的な性質で書き、**固定コーパスの全数で直しの前後を突き合わせて**、消えた/増えた発火を1件ずつ見る(1アプリの確認だけで入れない)。とくに①**エージェントの癖(同じ誤りの繰り返し)を判定を緩めて吸わない**(注記で言う。MCP だけ判定を広げると DSL と割れ、写したシナリオが赤になる)②**画面を動かす自動の操作を名前の一致だけで撃たない**(幾何・状態の裏付けを足す。足せなければ案内に止める)。実例: `*円*` を ¥ にも当てた待ち・名前だけでグラバーを引いたシートの救済(どちらも 2026-11-13 に外した)
- **受け手が受け取る経路も一度は通す** —— **コードの正しさと、それが受け手へ届くことは別に
  確かめる** → MN-4.6
- **flake の修正は1回グリーンで判定しない・単発の観測で性能を断じない**(反復+負荷で叩く。
  手順は docs/verification/judgment.md「flake・性能の判定規律」)
- **「読む回数を減らす」最適化は、その読みが担っている砦を先に列挙する**。**節約できるのは
  誰も見ていない読みだけ** → MN-4.7。**読みを新しくする最適化も同じ** —— 待ちが担っていた
  「次の読みも追いついている」を消す(Android の迂回はキャッシュを更新しない。`nextResolveBypassesCache`)→ MN-38
- **単体テストが緑でも実データで1回動かすまで信用しない**(テストは書いた本人の前提を共有するので、
  前提が誤っていると実装とテストが同じ誤りを持ったまま緑になる。実害3件は docs/verification/testing.md「単体テストが緑でも「実データで1回動かす」まで信用しない」)
- **定数を置くときは根拠・単位・尽きたときの発話を書く**(DR-4)。
  書けないなら数字を調整するのではなく**数字への依存を消す**(観測可能な事象を待つ・デバイスの
  応答が要らない情報源から導く)。**片方の文脈で詰めた値を別の文脈へ流用しない** —— 読み手の
  予算・シミュレータの実測・pt で測った床は、読み手のいない経路・実機・px の木では
  **遅くなるのではなく黙って誤る**(実例と直し方は MN-12.1・MN-104.5)。残す数字は名前を付けて
  1箇所に置く。**既定値はリテラルで固定するテストを置く** —— 他のテストが差し替え口で値を
  明示していると production の既定を1度も通らず、既定を戻す変更が緑のまま通る
  (`FMCallSlotsTests.testDefaultConcurrencyIsPinned`)。**既定を変える変更は、その既定に依存している
  テストを1件ずつ見る** —— 落ちずに「素通り」して検証をやめる型がある
- **共有資源の枠(並列度)は「平均利用率」で決めない** —— 需要がバーストなら利用率が容量の半分でも
  待ち行列はできる。**待ちそのものを測る**(FM なら結果 JSON の `fm.gateWait*`)。さらに
  **掃引だけで決めない**: スループットの膝と実 run の最適は一致しない ——
  判断軸は**「待ち + 実働」の和**で、片方だけ見ると必ず誤る(実測は
  PT-3.5)
- **陽性対照は pass/fail でなく出力の文言まで読む** → MN-4.14
- **回復の操作(起動し直し・再起動)は、効いたかを直後に測る**。効かなければ同じ操作を繰り返さず、
  測った事実を 1 行言う(`RunnerRestartFutility`。XCUITest ランナーの起動し直しが緑のたびに約 10 秒ずつ
  空振りしていた)。**遅さ・失敗の帰属は、それを分ける測定をしたときだけ書く** —— 検知の入力から
  導けない帰属を文言に入れない(遅いレーンの警告と供給時プローブが同じデバイスに正反対の帰属を出した)
  → MN-29
- **失敗の帰属は「HEAD での対照」で決める**(`git stash push -u` → HEAD で1シナリオ →
  `git stash pop`。3〜4分。docs/verification/testing.md「失敗の帰属は「HEAD での対照」で決める」)
- **「差が出ない」ときは仮説より先に実験系を疑う**。**陽性対照を先に通す**(マーカーを書くだけの版で
  差し替えが効くことを確認してから本番)。判定に使うシナリオは **`clearAppData()` から始める**
  → MN-4.8
- **不具合を直したら「同じ型が他に無いか」を機械的に掃討する**(grep で同じ呼び出し形・同じ定数・
  同じ既定実装依存を列挙してから潰す)。同じ型はほぼ必ず複数ある(→ MN-4.6.1)。**再現しない同型でも、
  失敗モードが沈黙(誤った成功)なら塞ぐ価値がある**(その場合は「再現していない」と明記する)。
  可能なら**同型の再発を落とすテスト**まで足す(`SwipeForScrollForwardingTests` = ソース走査 /
  `BridgeRouterStatusContractTests` = 本数固定 / `AppDriverDefaultDispatchTests` = 宣言の突き合わせ)
- **探索・負荷の誤った成功と回復の失敗を直すときは、再現手順と別経路の形を `Scripts/replay-cases/` に足し、直しを外した版で赤を確かめてから完了とする**
  (修正の関門。所見の様式の「直しとの関係」も必須)→ docs/verification/testing.md「修正の関門」

### 検知を足すとき

- **新しい検知(警告・lint・修正提案)は「既存資産の全数に当てて誤検知0」まで確認する**。
  dry-run はデバイス不要なので全数が安い(レシピと実例は docs/verification/testing.md「新しい検知・警告は「既存資産の全数に当てて誤検知0」まで確認する」)。
  **ただしスナップショットの検知(遮蔽・積み重なり・ghost)は自前 SUT では代表できない**
  (木が要るので dry-run では当てられない)。**「出ない」ことを設計の根拠にするなら、
  コーパスとデバイス実行の両方で確かめる**
  → MN-4.10
- **実アプリのスナップショットは `Tests/Fixtures/RealAppSnapshots/` に固定してあり、
  `SweepHarnessTests` が `swift test` で毎回当てる**(件数の基準値+タップ対象に対する警告率の上限)。
  **基準値を上げるのは増えた分を1件ずつ見て真陽性だと確かめてから** —— 黙って上げるとこの砦は
  現状の追認装置になる。採り直しは `FT_SWEEP_BASELINE=1`
- **凍結・a11y 異常など「意図的に起こせない事象」の検知には注入口を用意する**
  (`FrozenInjection` / `FT_FAKE_FROZEN_KEYS`)。**陰性(誤検知0)の確認は「常に false を返す
  検出器」と区別できない** → MN-4.11。注入は**観測と公表の経路だけ**を通し、
  回復・除外のような**デバイスを触る動作は撃たない**(`FrozenVerdict.isInjectedOnly`)
- **「観測」と「配信(表示の最適化)」を同じループに書かない**。抑制は配信段だけに効かせ、
  観測は cadence を落として続ける(`ApiMonitorCommand.capturePlan` = 純粋関数)
- **新しい検知はまず警告から**入れる

### テストを足すとき

- **新しいテストは「破ったら落ちる」ことを1回確かめる**。変異は **`Scripts/mutation-check.sh` で
  git worktree 並列**(本線のツリーには書かないので復元忘れが起きない)。手で1件だけやるときは
  壊して実行→復元(**復元に `git checkout <file>` を使わない** = 未コミットの変更ごと消える)
- **検知の類は両方向に掛ける**(出さなくする変異 / 常に出す変異)—— 片方だけだと
  「常に空を返す」変異を「空を期待するテスト」に当てて素通しする
- **テストが production の関数を通っているかも見る**(→ MN-4.13)。検出できない変異が出たらテストを境界へ
  寄せる(要素数を増やす・既定値でなく限界値で呼ぶ)
- **テストが production の代わりに正規化・整形していないか** → MN-4.13.1
- **変異が生き残ったら、まずテストの置き場所とフィルタを疑う** → MN-4.12。
  **「殺せた」も exit code で数えない** —— 変異がコンパイルエラーでも exit 1 になる。狙ったテスト名の失敗行で取る

### 版と契約の同期(片方だけ変えない)

- `fleetest api` の JSON/NDJSON 契約を後方非互換に変えたら `Sources/FTCore/ProtocolVersion.swift` と
  `vscode-fleetest/src/protocolVersion.ts` の版を +1(両者一致必須・`protocolVersion.test.mjs` が
  検出。拡張は起動時に照合し不一致を警告)。**後方互換の読み替えは置かない**
  (DR-5)—— 欄を足すときも `decodeIfPresent ?? 既定値` で古い形を吸わず、
  **必須にして版を +1** する(ベータ版の間は改名にも別名を置かない = DR-180。欄が無いこと自体が「測っていない」等の意味を持つ省略可の欄は読み替えに当たらない = DR-75)。リモートは `Scripts/align.sh` で毎回使う機械を手元と同じ中身へ揃える運用で、
  版がずれた状態は存在しない(ずれていれば適合チェックが止める)。互換を入れると、その経路は
  テストでしか踏まれずに腐り、**沈黙する縮退**(decode 失敗で機械1台ぶんの行が消える等)を作る
- **`fleetest run` と `fleetest api run` は2実装**。共通のオプション宣言と検査は
  `RunCommonOptions`(`@OptionGroup`)に1つだが、片側だけのフラグと**配線(受け取った値を実行段へ渡す)は
  別々**で、片方だけに足した変更はどちらの経路も緑のまま通る。**両方で同じ意味のオプション・検査は
  `RunCommonOptions` へ足す**。フラグの差分と「併用不可・必須」の検査の揃いは `RunCommandFlagParityTests` /
  `RunRejectionParityTests` が等号で固定する(落ちたら共通へ寄せるか、差分の理由を表へ書く)

### 判定は1箇所に置く


- **判定は MCP と DSL で共有する**。「手前かどうか」は `FTCore.PaintOrder`、「撃つと別の物に
  当たるか」は `FTCore.TapTargetGeometry`(合成チェーンは `occlusionAdvisory`)と
  `FTCore.OcclusionGeometry`(中心を覆う最前面の名指し。`OcclusionSuspicion.covering` とは
  判定軸が別 = 面積比 vs 中心点。統合しない理由は両型の doc)、「絵が古いか」は
  `FTCore.StaleFrameDetector`、焦点待ちの定数は `FTCore.FocusWait` の1箇所だけに置き、
  `RefGuard`/MCP は転送する。別々に持つと**同じ画面で MCP と DSL の判断が食い違う**
  (実例は MN-5)。移設したときは**掃討ゲート(`SweepHarnessTests`)が
  実アプリのコーパスで等価性を検証する**
- **判定の関数を `StepExecutor` の static に置かない**(`.claude/rules/executor.md`)
- **前面にあると観測しただけの相手へ、画面を動かす操作を撃たない**(activate を使わない。`.claude/rules/bridge-provision.md`・MN-40)
- **FM の失敗トリアージ・FM ヒール・ヒールキャッシュは置かない**(DR-6・DR-7。`FMTriageRemovedTests` / `FMHealRemovedTests`)。
  **`heal` は指紋照合だけのスイッチで、FM のトグルと独立**
- **共有するのは「判定」であって「文言」ではない**。正しい形は**①判定・順序・当たり判定を
  FTCore に1つ ②文言は呼び手ごとに持つ**。**呼び手は中核を呼んで写すだけ**にする。中核は `TapTargetGeometry.advisoryKind` /
  `FTCore.SimilarLabels` / `FTCore.BackEffect` / `FTCore.SnapshotTruncation.remedy` /
  `TapTargetGeometry.offscreenScrollGateCentre`。**天井まで来ていたら「上げろ」と言わない**。
  **FM に訊いて答えが無かったステップは `visibility-guard-skipped`** を立てる。
  **判定に文言を埋め込んだら、呼び手が増えた日に他人の対処文が出る** —— **対処文は `remedy` として
  呼び手が渡す**(既定値を置かない = 渡し忘れをコンパイルで止める。実例は `.claude/rules/bridge-provision.md` の `BridgeIdentityCheck`)

### 個別の規律

- **PCC(Private Cloud Compute)は完全に禁止**(DR-8)。FM で使ってよいのは
  **オンデバイスの `SystemLanguageModel` だけ**・**利用者向けのトグルも置かない**(user-docs の about が
  「画面情報は Mac の外に出ない」と断定している不変条件)。`LanguageModelSession` に `model:` を渡さない
  (`PrivateCloudComputeProhibitionTests`。仕組みは DS-1.1 末尾)

## 実装の委譲

- 原則、実装タスクは Sonnet サブエージェントに委譲する(メインセッションは計画・プロンプト設計・レビュー・検証を担当)
- ユーザーの指示があればそちらを優先する
- 小さな修正や、レビュー中に見つけた直しなど、直接編集した方が良いと判断できる場合は委譲せず直接編集してよい

## 並列一括作業(サブエージェント委譲)

- 全域一括の機械的変更は、ファイル集合が互いに素になるようバッチ分割して並列委譲する(コメント量・行数で均等化)
- サブエージェントに swift build / npm build を実行させない(SPM ビルドロック・出力の競合)。ビルド・テストはメインで全バッチ完了後に一括実行。軽量な per-file チェック(node --check 等)は各エージェントで可
- 「コメントのみ」「移動のみ」を謳う変更は、diff の全変更行を機械検証(全 +/- 行がコメント/空行か、末尾コメント編集はコード部分が同一か)してからコミットする
- TestProjects/ 配下のシナリオ(.swift)はユーザー資産(一部は explore 生成)。リポジトリ全域の一括整形・コメント編集の対象に含めない

## ソース分割の方針

保守者は Claude Code。目安: 1ファイル約2,000行以下(一度の Read で収まる)、1タスクで編集するのは1〜2ファイルに収まる構成を保つ。超えたら分割を検討する(人間向け可読性は目的ではない)。
Sources は `SourceFileLineBudgetTests` がラチェットで止める(超過分は今の行数で凍結・増やすと落ちる・減ったら表を下げる。表の数字を上げて通さない)。
**分割したら `Scripts/split-scan-check.py <元> <移した先>...` を回し、挙がったテストを1本ずつ読む** —— ファイル名で名指しする走査テストは
移した中身を黙って見なくなる(件数の下限・「どこかに1つ」の形は緑のまま。`AdbPolicyBuilderSyncTests`)。
移した中身を検査しているなら移した先も読むように直し、直しは移した先への変異で落ちることを確かめる。


## 国際化(i18n・日英切替)

拡張の UI 文字列は日英切替対応(設定 `fleetest.language`: auto/ja/en、auto は VSCode 表示言語に追従。モニター「設定」タブからも変更可)。UI 文字列を追加/変更するときの
規律は `.claude/rules/vscode-i18n.md`。どの作業でも効くのは次の1つ:

- **CLI(`fleetest`)の表示文字列は英語だけ**(DR-9。切替機構は入れない)。
  コメント・docs・SKILL.md・拡張 UI は日本語のまま(`CLIEnglishStringsScanTests`。例外は理由付きの表 → MN-44.3)

## コメント規約

コメントの読者は人間ではなく Claude Code。目的は「編集時の事故を防ぐ」「再調査を不要にする」の2つだけ。それに寄与しないコメントはトークンの無駄なので書かない・見つけたら消す。

残す(最小の行数に圧縮して):
- コードから導出できない制約・不変条件・順序依存(例:「acquireVsCodeApi は1回しか呼べない」「stdin EOF が終了指示」)
- ファイル間・言語間で同期が必要な契約(postMessage のメッセージ型、NDJSON プロトコル、ブリッジ HTTP API)と、同期相手のファイルへのポインタ
- 一見単純化・削除できそうに見えるが、すると壊れる箇所の理由(1-2行)
- 数値・チューニング値の意味(単位・上限・根拠)

書かない・削除する:
- 識別子・型・import から分かる「何をするか」の説明
- 設計経緯・履歴(移動元、旧仕様との比較、日付・指示・要件タグ)
- UI・見た目の意図の散文(結果は CSS/コードにある)
- 同じ内容の重複(契約はどちらか1箇所に置き、他方は参照)
- 長い設計解説の散文(要点だけ箇条書きに圧縮)

迷ったら: 契約・制約・罠は残す、説明・散文は削る。

**用語**: 「実機」は**物理端末(本物の iPhone / Android)だけ**を指す。仮想デバイスは
**「仮想デバイス」「デバイス」「Simulator」「Emulator」**と書く(「実デバイス」も使わない ——
実機と紛らわしい)。デバイス上での実行一般は「デバイス実行」「デバイス上」でよい。
**「デバイスで動かした」と書きたくなった瞬間に、何の上で動かしたかを確認する**
→ MN-7

**用語(iOS のモードとブリッジ)**: 設定は**モード**(`inapp-boost` = XCUITest ブリッジに in-app ブリッジを足す構成 / `xcuitest`)、
部品は**ブリッジ**(in-app / XCUITest。`IOSModeVocabularyTests`)。
`bridge: "inapp"` はブリッジの種類の値でモード名ではない —— **モードの値を /status の `bridge` との比較へそのまま渡さない**
(主ポートのブリッジは `IOSMode.primaryBridge(forMode:)`)

**用語(モニターのペイン)**: 「デバイスモニター」タブは**ラインビュー・グリッドビュー・実行ログビュー**の常設3ペイン
(契約は DS-12.6)。ペインを「フリート」と呼ばない(複数機械・`run --fleet` の製品概念)。詳細は `.claude/rules/vscode-i18n.md`

**用語(利用者向けの表記)**: user-docs の ja・README・拡張の i18n の表記ゆれと保守者の内輪の語(受け手・木・撃つ 等)は
`UserFacingSpellingTests` が置き換え先付きで落とす(表は同テスト・DR-182)。保守者向けのコメント・docs は対象外

**用語(陽性/陰性)**: **「陽性/陰性」は検知の語彙**(発火したかどうか)で、**判定の結果(緑/赤)には使わない**。
`偽陽性`・`偽陰性` は `VocabularyPolarityTests` が代わりの語付きで落とす(MN-11)。**陽性対照**は1語の固有名詞。
occlusion guard の利用者向けの名前は**「テキストの可視性検証」**(`fmTextVisibilityCheck` / `ocrTextVisibilityCheck`)
