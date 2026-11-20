# メモ(writeMemo, readMemo, clearMemo, memoTextAs, writeRunMemo, readRunMemo, clearRunMemo, runMemoTextAs)

[in English](memo.md)

値を受け渡します。`@Test` は1本ずつ別プロセスで動くので Swift の変数は引き継がれません。メモは2種類あります。

- **メモ(`writeMemo` など)**は、**テスト1本の中**(`beforeEach()`・本体・`afterEach()`)だけで使えます。同じテストの中で、ある手順から別の手順へ値を持ち越すときに使います。
- **run メモ(`writeRunMemo` など)**は、**run のすべてのシナリオ(どのデバイスでも・どのマシンでも)**で共有されます。他のテストへ値を渡すときに使います。

## 関数

| 関数 | 説明 |
|---|---|
| `writeMemo(key, text)` | キーの履歴に `text` を追記します(このテストの中だけ)。 |
| `readMemo(key) -> String` | このテストの中でキーに書いた**最後の値**を返します。無ければ `""`(失敗にはしません。ステップに注記 `memo-key-not-found` が付きます)。 |
| `clearMemo()` | このテストのメモを全部消します。 |
| `element.memoTextAs(key)` | 取得した要素のテキスト(ラベル → 値のうち空でない最初のもの)を書き、要素を返します。要素を取得できていなければ失敗します。 |
| `string.memoTextAs(key)` | 文字列を書き、その文字列を返します。 |
| `writeRunMemo(key, text)` | run メモのキーの履歴に `text` を追記します。 |
| `readRunMemo(key) -> String` | run メモのキーの**最後の値**を返します。無ければ `""`(失敗にはしません。ステップに注記 `run-memo-key-not-found` が付きます)。 |
| `clearRunMemo()` | run メモを全部消します。 |
| `element.runMemoTextAs(key)` | 取得した要素のテキストを run メモへ書き、要素を返します。要素を取得できていなければ失敗します。 |
| `string.runMemoTextAs(key)` | 文字列を run メモへ書き、その文字列を返します。 |

## 共有の範囲

### メモ(`writeMemo` など)

- 範囲はテスト1本です。`beforeEach()`・本体・`afterEach()` で共有され、次のテストは空のメモから始まります。他のシナリオへは渡りません。
- **テストの外での読み書きは失敗になります。** `beforeAll()`・`setUpDevice()`・`tearDownDevice()`・`afterAll()`・`beforeRun()`・`afterRun()` が対象で、ヘルパー関数を経由しても止まります。
  エラーには「run 全体で共有するなら `writeRunMemo` / `readRunMemo` を使う」と出ます。

### run メモ(`writeRunMemo` など)

- **run のすべてのシナリオ(どのデバイスでも。マシンをまたぐ run ではマシンをまたいで)**共有されます。次の run へは持ち越しません。
  MCP の `ft_run_scenario` は1回の呼び出しが1つの run で、その run メモは空(またはその呼び出しの `beforeRun()` が書いたもの)から始まり、その呼び出しのシナリオで共有されます。ランナーを手で直接起動した実行は空の run メモから始まります。
- 確実な使い方は「**[`@RunHooks`](../testclass/creating_testclass_ja.md#run-全体の準備と片付けrunhooks--beforerun--afterrun) のクラスの `beforeRun()` で `writeRunMemo` し、各テストで `readRunMemo` する**」です。
  `beforeRun()` は1回の run でどのマシンのどのシナリオよりも前に1回だけ走るので、全テストが最初の行から値を読めます。アプリやそのマシンが要る値は、`@RunOnSingleMachine` を付けたクラスの `beforeAll()` でだけ書きます(`beforeAll()` はクラスごとに走り、マシンをまたぐ run ではマシンごとに1回走るので、別のマシンの `beforeAll()` が値を上書きすることがあります。run 全体の値は `beforeRun()` に置きます)。
  `beforeAll()` は、そのマシンのデバイスで走るそのクラスのどのシナリオよりも前に走り、他のデバイスは終わるまで待ちます。
  `beforeRun()` が走らない実行(デバッグ実行・プロファイルなしの run・dry-run)では、そのキーを `readRunMemo` で読むと失敗ではなく `""` が返るので、読んだ直後に確かめます(例: `readRunMemo("token").thisIsNotEmpty()`)。
- `afterRun()` も `afterAll()` と同じく、run メモを読めます(最終の値)が書けません。`beforeRun()` と `afterRun()` では、テスト単位のメモ(`writeMemo` など)も使えません。
- **ある `@Test` から別の `@Test` へ値を渡すなら、`@RunInOrder` のクラスにして、先のテストで `writeRunMemo` します。** それ以外のクラスは、順番も走るデバイスも決まっていません
  ([クラスのテストを1か所で・順番に流す](../testclass/creating_testclass_ja.md#クラスのテストを1か所で順番に流すrunonsinglemachine--runonsingledevice--runinorder))。
- **`setUpDevice()`・`tearDownDevice()`・`afterAll()`・`afterRun()` での run メモの書き込み(`writeRunMemo`・`runMemoTextAs`・`clearRunMemo`)は失敗になります。**(`beforeRun()` では書けます。)
  `setUpDevice()` の書き込みは他のデバイスの値で上書きされ、`tearDownDevice()`・`afterAll()`・`afterRun()` の書き込みはテストが終わった後で、読むテストがないためです。読むのはかまいません
  (`afterAll()` は全デバイスの仕事が終わった後に走るので、最後の値が見えます)。無いキーを `readRunMemo` で読むと `""` を返します。
- run メモは **run ごとに空から始まります**(前の run の値は残りません)。
- シナリオが受け取る run メモは**そのシナリオの開始時点のもの**(と、そのシナリオ自身の書き込み)で、走っている間に別のデバイスが書いた値は見えません。
- **マシンをまたぐと、書き込みは別のマシンへ少し遅れて届きます。** 書いたマシンは次のシナリオから自分の書き込みが見え、別のマシンは届いた後に始まるシナリオから見えます。
  最後はどのマシンも同じ履歴が同じ順にそろいます。
- **普通の run メモの書き込みは排他されません。** 書き込みは消えず、届いた順に追記されますが、読んでから書くまでの間に別のシナリオが書く割り込みや、同じキーへの同時の書き込みのどちらが最後になるかは保証しません。
  **1つのキーに書くのは1か所にします** —— キーをテストごとに分けてください(例: `"orderId_S0010"`)。排他が要るとき(カウンター・「この品を取る」の取り合い)は、軽いものは [run 全体のロック](#run-全体のロックwithexclusivelock)、重いもの・run をまたぐものはテスト用サーバーの DB を使います。
- `clearRunMemo()` は、その時点の run メモ(自分のまだ確定していない書き込みを含む)を消します。
- **複数のマシンのデバイスを持つ実行プロファイルで回す run**(デバイスの `machine` に別のマシンを書いた実行プロファイル。→ [リモート実行](../../fleet/remote_runners_ja.md)。`--runner` で別のマシンへ送る run も)では、run メモはマシンをまたいで1つです。
  **例外は `--fleet` の run** で、`--split` の有無に関わらず、run メモはマシンをまたがず、マシンごとの共有です(run の開始時にそのことを示す1行が出ます)。
- テストクラスのプロパティ(`var`)で値を渡そうとすると、ビルド時に警告が出ます。ある `@Test` で書いて別の `@Test` で読む、`beforeAll()` で書いて各テストで読む、のように、書いた側と読む側が別のプロセスで走る形です(`beforeEach()` で書いて同じテストの本体や `afterEach()` で読む形は正しく動くので出ません)。ヘルパー関数経由の書き込みや `x.append(…)` のような変更は検知しないので、警告が出ないことは安全の保証ではありません。
- `beforeAll()` が失敗すると、その run のそのクラスの残りのシナリオは実行されずに失敗として記録され、再試行しません。
  `setUpDevice()` が失敗すると、そのデバイスで同じクラスの残りのシナリオは実行されずに失敗として記録されます。

## run 全体のロック(`withExclusiveLock`)

1つしかない資源(例: ワンタイムパスワード(OTP)の受信箱が1つだけで、同時に2台が送ると受け取った値が取り違えになる)を、デバイスの操作をまたいで占有するときに使います。送信 → 受け取り → 入力までを1つのロックで包むと、他のシナリオは終わるまで待ちます。

```swift
withExclusiveLock("otp-inbox") {
    select("#send_otp").tap()
    let otp = readOtpFromInbox()   // 受信箱から最新の OTP を読む、利用者が書く関数
    select("#otp_input").tap()
    type(otp)
    select("#verify").tap()
}
```

データだけの排他(カウンタなど)なら、テスト用サーバーの DB でもできます。クラス単位で直列にすれば足りるなら `@RunOnSingleDevice` / `@RunInOrder` を使います。run メモのカウンタを足す例:

```swift
withExclusiveLock("counter") {
    let n = Int(readRunMemo("count")) ?? 0
    writeRunMemo("count", String(n + 1))
}
```

- `withExclusiveLock(キー..., waitSeconds:) { }` は、run の他のどのシナリオもそのキーを持っていない間だけブロックを実行します。
- キー: 1つ以上・空白だけはエラー・制御文字はエラー・1つ120バイトまで・1回の呼び出しに8個まで。1回に複数のキーを渡すと、名前の順(UTF-8のバイト列)に1つずつ取ります。
  **ロックの中でロックを呼ぶ(入れ子)とエラー**です(キーが同じでも別でも、競合が無くても、dry-run でも)。ロックを取るヘルパー関数を、ロックの中から呼ぶ(入れ子になる)書き方もできません。ロックの外から呼ぶのは問題ありません(共通の手順を関数にまとめてよい)。**要るキーは全部1回の呼び出しで渡してください。**
- 取れるまで待ちます。待った時間は `scenarioTimeout` に数えません(マシンをまたぐ run では、リモートのマシンの run の制限時間にも数えず、リモートの部分の制限時間を延ばせるのは、最大で元の制限時間と同じ長さまでです。1台のリモートへの `run --runner <マシン>` では延ばしません)。シナリオごとの待ち時間は結果 JSON の `lockWaitMs` に残り、並べ替えや分割の所要の見積りからも除かれます。1回の呼び出しの待ちは、その run の最も長い `scenarioTimeout`(`@Test(scenarioTimeout:)` を含む)までで、
  `waitSeconds:` は省略でき(省略時はその上限)、0 より大きくなければならず(0 や負の値は「1回だけ試す」ではなくエラー)、待ちを短くすることだけができます。時間切れはステップの失敗で、ブロックは実行しません。激しく取り合うとこの上限に当たりうるので、重い排他や run をまたぐ排他は DB を使ってください。
  **他のテストの完了待ちにロックを使わないでください**(1台と複数台でシナリオが配られる順が違います)。
- ロックの中の `writeRunMemo` / `clearRunMemo` / `runMemoTextAs` は、確定してから次のステップへ進み、`readRunMemo` は最新の値を返します(ロックを出た後もその値が見えます)。
  ロックの外の書き込みは今までどおり通ります。**ロックで守るキーは、ロックの中でだけ書いてください。** run メモの大きさの上限(エンコード後で約 1.4 MB)を超える値は、ロックの中ではエラー、ロックの外ではそのマシンの中だけに残って警告が1行出ます。

画面から読む値を **run の中で1回だけ**読み、全マシン・全クラスで共有するには(`beforeRun()` はデバイスを使えません)、各テストの先頭でロックの中で読みます。最初に着いた1本だけが読みます。

```swift
withExclusiveLock("shop") {
    if readRunMemo("shop").isEmpty { select("#shop_name").runMemoTextAs("shop") }
}
```

ロックの中の `readRunMemo` は最新の値を返すので、後のテストは値が入っているのを見て読みを飛ばします。
- シナリオが失敗していればブロックは実行しません。ブロックの中で失敗しても、残りの生の Swift のコードは走り続け、ロックはブロックを抜けたときに外れます。
  再実行されたシナリオはブロックをもう一度実行します(カウンタは二重に足されます)。
- **ロックの外で自分が書いた run メモ**は、ロックの中の読み・書きが答える前に適用されます(このシナリオが既に出した書き込みが適用されるまでロックの中の読み書きが待つので、消えたり上書きされたりしません)。他のシナリオの書き込みの順序はロックだけが決めます。
- dry-run はロックを取らずにブロックを通します(入れ子は dry-run でもエラーになります)。マシンをまたぐ run では、ssh で届くリモートのマシンを含む全マシンでロックが効きます(ロックのサーバーは fleetest を起動したマシンで動きます)。リモートのシナリオの接続がロックを持ったまま切れたら、そのキーは向こうの run の終わりを確かめるまで取れず(待っている要求も新しい要求も待たずに理由つきで失敗します)、外れた後に最初に取るステップには「前の持ち主の書き込みが欠けているかもしれない」という注記が付きます。`--fleet` の run では、ロックが黙って割れないよう、呼んだ時点で理由つきの失敗になります。
- ロックは `beforeRun()` / `afterRun()` の中とデバッグ実行では、排他せずにすぐ許可されます。
- ロックのサーバーは、プロジェクトの `scenarios/` フォルダの下(`_disabled/`・コメント・文字列の中は除く)に `withExclusiveLock` の呼び出しが見つかったときだけ起動します。無ければロックを呼んだ時点で理由つきの失敗になります。`Package.swift` で足した別のターゲットやパッケージにだけ呼び出しがある場合も失敗します。
- MCP では、同じ MCP サーバー上の同じプロジェクトの呼び出し同士は互いに排他されます。
- `ft_batch` は受けません。

## 例

```swift
@TestClass
class OrderFlow {
    func beforeAll() {
        launchApp()
        select("#shop_name").runMemoTextAs("shop")
    }

    @Test("レシートに店名が出る")
    func S0010() {
        scenario {
            scene(1, "確認する") {
                expectation { select("#receipt_shop").textIs(readRunMemo("shop")) }
            }
        }
    }

    @Test("メモで同じテストの中の値を持ち越す")
    func S0020() {
        scenario {
            scene(1, "覚える") {
                action { select("#order_no").memoTextAs("orderNo") }
            }
            scene(2, "確認する") {
                expectation { select("#receipt_order_no").textIs(readMemo("orderNo")) }
            }
        }
    }
}
```

この例では、どのマシンも `beforeAll()` から同じ店名を書くので、重複した書き込みは無害です。マシンごとに違う値は、クラスに `@RunOnSingleMachine` を付けるか `beforeRun()` で書きます。

## 注意点

- ロックで守るキーはロックの中でだけ書きます([run 全体のロック](#run-全体のロックwithexclusivelock)参照)。
- 再実行されたシナリオはロックのブロックをもう一度実行します(カウンタは二重に足されます)。
- run 全体のロックは `--fleet` では効きません。重い排他や run をまたぐ排他はテスト用サーバーの DB を使います。

### Link
- [index](../../index_ja.md)
