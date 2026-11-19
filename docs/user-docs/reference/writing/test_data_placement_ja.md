# テストデータの置き方

[in English](test_data_placement.md)

1台のマシンでも、デバイスが複数あればテストはそのデバイスへ分かれて並列に走り、走る順番も決まりません。

複数のマシンで run を回すと、さらに `beforeAll()`・[メモ](../commands/memo_ja.md)・[compose.yaml のサーバー](services_ja.md)が
**マシンごとに1組**に分かれます(全マシンが1台の共有サーバーへ繋ぐ構成もありえます。その場合は同じデータベースを全マシンが同時に触ります)。
どちらの構成でも同じシナリオが通るように、次の3つの規則で書きます。

## 規則

1. **テストは、他のテストが作ったデータに頼りません。** 書き換えるデータは、テスト自身の `beforeEach()` や `condition` で、
   自分専用のアカウントと、一意な名前で作ったデータだけを用意します
   (例外は [`@RunInOrder`](../testclass/creating_testclass_ja.md#クラスのテストを1か所で順番に流すrunonsinglemachine--runonsingledevice--runinorder) のクラスで、順番に値を渡せます)。
2. **マシン単位の準備(`run-setup.sh` と `beforeAll()`)は、何度走っても・同時に走っても壊れない形で書きます。** 「無ければ作る」は良く、
   「全部消して入れ直す」は駄目です。共有サーバーを全体で戻したいときは、fleetest の外(CI の前段など)で run の前に1回だけ行います。
3. **片付け(`afterEach()`・`afterAll()`・`run-teardown.sh`)を合否の前提にしません。** 自分が作ったものだけを消し、
   片付けが走らなくてもデータが残るだけで合否に響かないようにします。

名前付きボリュームは run をまたいで残るので、前の run のデータが残っている前提で、テストが自分の範囲を用意します。

## 例

テストごとにキーを分けた `accounts.json`(書式は[テストデータ・アカウント](../commands/dataset_ja.md))。

```json
{
  "[order_S0010]": { "id": "order-s0010@example.com", "password": "..." },
  "[order_S0020]": { "id": "order-s0020@example.com", "password": "..." }
}
```

```swift
type("#login_id", account("[order_S0010].id"))
```

テストが作るデータの一意な名前:

```swift
let itemName = "order-" + UUID().uuidString.prefix(8)
```

データを用意する手段は[テストデータ・アカウント](../commands/dataset_ja.md)と [http_request](../commands/http_request_ja.md) を参照してください。

`--broadcast` と、`--split` の無い `--fleet` では、同じテストが複数のデバイスで同時に走るので、テストごとのアカウントでもぶつかります。

## 順番や1つのまとまりが要るとき

それでも順番が要る流れは、まず1つの `@Test` にまとめます。それができないときだけ、
クラスに [`@RunInOrder`](../testclass/creating_testclass_ja.md#クラスのテストを1か所で順番に流すrunonsinglemachine--runonsingledevice--runinorder)(順番に流す)・`@RunOnSingleDevice`(同時に走らせない)・`@RunOnSingleMachine`(1台のマシンにまとめる)を付けます。

## 注意点

- テストは書き換えるデータを自分専用のアカウント・一意な名前で自分で用意します。順番に渡せるのは `@RunInOrder` のクラスだけです。
- `run-setup.sh` と `beforeAll()` は何度走っても・同時に走っても壊れない形で書きます(「全部消して入れ直す」は共有サーバーで他のマシンのデータを消します)。
- 片付けを合否の前提にしません。自分が作ったものだけを消します。

### Link
- [index](../../index_ja.md)
