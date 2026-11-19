# メモ(writeMemo, readMemo, clearMemo, memoTextAs)

[in English](memo.md)

シナリオ間で値を共有します。`@Test` は1本ずつ別プロセスで動くので Swift の変数は引き継がれませんが、
メモは**1つのマシンの run の中で、すべてのシナリオ(どのデバイスでも)**共有されます(下の「共有の範囲」)。

## 関数

| 関数 | 説明 |
|---|---|
| `writeMemo(key, text)` | キーの履歴に `text` を追記します。 |
| `readMemo(key) -> String` | キーの**最後の値**を返します。無ければ `""`(失敗にはしません。ステップに注記 `memo-key-not-found` が付きます)。 |
| `clearMemo()` | メモを全部消します。 |
| `element.memoTextAs(key)` | 取得した要素のテキスト(ラベル → 値のうち空でない最初のもの)を書き、要素を返します。要素を取得できていなければ失敗します。 |
| `string.memoTextAs(key)` | 文字列を書き、その文字列を返します。 |

## 共有の範囲

- メモは**1つのマシンの run の中で、すべてのシナリオ(どのデバイスでも)**共有されます。次の run へは持ち越しません。マシンをまたぐ run ではマシンごとに分かれます(下の「マシンをまたぐ run」の項目)。
- 単発の呼び出し(MCP や、ランナーを手で直接起動した実行)は空のメモから始まります。
- 確実な使い方は「**`beforeAll()` で書き、各テストで読む**」です。`beforeAll()` は1回の run でクラスごとに1回、
  そのクラスのどのシナリオよりも前に(どのデバイスでも)走り、他のデバイスは終わるまで待つので、
  シナリオがどこに配られても値が存在します。
- `beforeAll()` が失敗すると、その run のそのクラスの残りのシナリオは実行されずに失敗として記録され、再試行しません。
  `setUpDevice()` が失敗すると、そのデバイスで同じクラスの残りのシナリオは実行されずに失敗として記録されます。
- **`setUpDevice()`・`tearDownDevice()`・`afterAll()` でのメモの書き込み(`writeMemo`・`memoTextAs`・`clearMemo`)は失敗になります。**
  `setUpDevice()` の書き込みは他のデバイスの値で上書きされ、`tearDownDevice()` と `afterAll()` の書き込みは読む人がいないためです
  (ヘルパー関数を経由しても止まります)。読むのはかまいません。無いキーを `readMemo` で読むと、今まで通り `""` を返します。
- **マシンをまたぐ run では、メモも `beforeAll()` もマシンごとに別になります。** そのクラスのテストに同じメモを見せたいときは、クラスに `@RunOnSingleMachine` を付けて1台のマシンに寄せます
  ([クラスのテストを1か所で・順番に流す](../testclass/creating_testclass_ja.md#クラスのテストを1か所で順番に流すrunonsinglemachine--runonsingledevice--runinorder))。
- **ある `@Test` から別の `@Test` へ値を渡せるのは `@RunInOrder` のクラスだけです**(`beforeAll()` で書いて各テストで読むのはどのクラスでもできます)。それ以外のクラスは、順番も走るデバイスも決まっていません。
- 制約: シナリオが受け取るメモは**そのシナリオの開始時点のもの**で、走っている間に別のデバイスが書いた値は見えません。
  複数のデバイスからの同時書き込みは直列化しません(ロックなし)。`clearMemo()` は(そのマシンの)メモを全部消します。
- `tearDownDevice()` と `afterAll()` もメモを読めます(`afterAll()` は全デバイスの仕事が終わった後に走るので、最後の値が見えます)。
- テストクラスのプロパティ(`var`)で値を渡そうとすると、ビルド時に警告が出ます。ある `@Test` で書いて別の `@Test` で読む、`beforeAll()` で書いて各テストで読む、のように、書いた側と読む側が別のプロセスで走る形です(`beforeEach()` で書いて同じテストの本体や `afterEach()` で読む形は正しく動くので出ません)。ヘルパー関数経由の書き込みや `x.append(…)` のような変更は検知しないので、警告が出ないことは安全の保証ではありません。

## 例

```swift
@TestClass
class OrderFlow {
    func beforeAll() {
        launchApp()
        select("#shop_name").memoTextAs("shop")
    }

    @Test("レシートに店名が出る")
    func S0010() {
        scenario {
            scene(1, "確認する") {
                expectation { select("#receipt_shop").textIs(readMemo("shop")) }
            }
        }
    }
}
```

### Link
- [index](../../index_ja.md)
