# メモ(writeMemo, readMemo, clearMemo, memoTextAs, writeRunMemo, readRunMemo, clearRunMemo, runMemoTextAs)

[in English](memo.md)

値を受け渡します。`@Test` は1本ずつ別プロセスで動くので Swift の変数は引き継がれません。メモは2種類あります。

- **メモ(`writeMemo` など)**は、**テスト関数の中**(`beforeEach()`・本体・`afterEach()`)だけで使えます。同じテストの中で、ある手順から別の手順へ値を持ち越すときに使います。
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

- 範囲はテスト関数の中だけです。`beforeEach()`・本体・`afterEach()` で共有され、次のテストは空のメモから始まります。他のシナリオへは渡りません。

### run メモ(`writeRunMemo` など)

- run メモは run の中のすべてのシナリオで共有されます(デバイスやマシンが違っても同じです)。run を始めるたびに初期化され、前の run の値は残りません。
- おすすめの使い方は、**[`@RunHooks`](../testclass/creating_testclass_ja.md#run-全体の準備と片付けrunhooks--beforerun--afterrun) を付けたクラスの `beforeRun()` で `writeRunMemo` を使って値を書き、各テストで `readRunMemo` を使って読む**方法です。
- シナリオが読めるのは、**そのシナリオが始まった時点の run メモ**と、そのシナリオ自身が書いた値です。テストの実行中に別のシナリオが書いた値は読めません。
- **書き込みは排他されません。** 排他が必要な場合は、[run 全体のロック](run_lock_ja.md)を使います。

## 例

```swift
import FTDSL

@RunHooks
class RunSetup {
    func beforeRun() {
        writeRunMemo("shop", data("[shop1].name"))
    }
}

@TestClass
class OrderFlow {
    @Test("レシートに店名が出る")
    func S0010() {
        scenario {
            scene(1, "確認する") {
                expectation {
                    select("#receipt_shop").textIs(readRunMemo("shop"))
                }
            }
        }
    }

    @Test("メモで同じテストの中の値を持ち越す")
    func S0020() {
        scenario {
            scene(1, "覚える") {
                action {
                    select("#order_no").memoTextAs("orderNo")
                }
            }
            scene(2, "確認する") {
                expectation {
                    select("#receipt_order_no").textIs(readMemo("orderNo"))
                }
            }
        }
    }
}
```

### Link
- [index](../../index_ja.md)
