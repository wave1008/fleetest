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
- **テストの外での読み書きは失敗になります。** `beforeAll()`・`setUpDevice()`・`tearDownDevice()`・`afterAll()` が対象で、ヘルパー関数を経由しても止まります。
  エラーには「run 全体で共有するなら `writeRunMemo` / `readRunMemo` を使う」と出ます。

### run メモ(`writeRunMemo` など)

- **run のすべてのシナリオ(どのデバイスでも。マシンをまたぐ run ではマシンをまたいで)**共有されます。次の run へは持ち越しません。
  単発の呼び出し(MCP や、ランナーを手で直接起動した実行)は空の run メモから始まります。
- 確実な使い方は「**`beforeAll()` で `writeRunMemo` し、各テストで `readRunMemo` する**」です。`beforeAll()` は1回の run でクラスごとに1回(マシンをまたぐ run ではマシンごとに1回)、
  そのマシンのデバイスで走るそのクラスのどのシナリオよりも前に走り、他のデバイスは終わるまで待つので、
  シナリオがどこに配られても値が存在します。
- **ある `@Test` から別の `@Test` へ値を渡すなら、`@RunInOrder` のクラスにして、先のテストで `writeRunMemo` します。** それ以外のクラスは、順番も走るデバイスも決まっていません
  ([クラスのテストを1か所で・順番に流す](../testclass/creating_testclass_ja.md#クラスのテストを1か所で順番に流すrunonsinglemachine--runonsingledevice--runinorder))。
- **`setUpDevice()`・`tearDownDevice()`・`afterAll()` での run メモの書き込み(`writeRunMemo`・`runMemoTextAs`・`clearRunMemo`)は失敗になります。**
  `setUpDevice()` の書き込みは他のデバイスの値で上書きされ、`tearDownDevice()` と `afterAll()` の書き込みは読む人がいないためです。読むのはかまいません
  (`afterAll()` は全デバイスの仕事が終わった後に走るので、最後の値が見えます)。無いキーを `readRunMemo` で読むと `""` を返します。
- シナリオが受け取る run メモは**そのシナリオの開始時点のもの**(と、そのシナリオ自身の書き込み)で、走っている間に別のデバイスが書いた値は見えません。
- **マシンをまたぐと、書き込みは別のマシンへ少し遅れて届きます。** 書いたマシンは次のシナリオから自分の書き込みが見え、別のマシンは届いた後に始まるシナリオから見えます。
  最後はどのマシンも同じ履歴が同じ順にそろいます。
- **排他はありません。** 書き込みは消えず、届いた順に追記されますが、読んでから書くまでの間に別のシナリオが書く割り込みや、同じキーへの同時の書き込みのどちらが最後になるかは保証しません。
  **1つのキーに書くのは1か所にします** —— キーをテストごとに分けてください(例: `"orderId_S0010"`)。本当に排他が要るとき(カウンター・「この品を取る」の取り合い)は、テスト用サーバーの DB を使います。
- `clearRunMemo()` は、その時点の run メモ(自分のまだ確定していない書き込みを含む)を消します。
- **`--fleet`(`--split` なし)の run メモは、マシンをまたがず、マシンごとの共有です。** run の開始時にそのことを示す1行が出ます。
- テストクラスのプロパティ(`var`)で値を渡そうとすると、ビルド時に警告が出ます。ある `@Test` で書いて別の `@Test` で読む、`beforeAll()` で書いて各テストで読む、のように、書いた側と読む側が別のプロセスで走る形です(`beforeEach()` で書いて同じテストの本体や `afterEach()` で読む形は正しく動くので出ません)。ヘルパー関数経由の書き込みや `x.append(…)` のような変更は検知しないので、警告が出ないことは安全の保証ではありません。
- `beforeAll()` が失敗すると、その run のそのクラスの残りのシナリオは実行されずに失敗として記録され、再試行しません。
  `setUpDevice()` が失敗すると、そのデバイスで同じクラスの残りのシナリオは実行されずに失敗として記録されます。

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

### Link
- [index](../../index_ja.md)
