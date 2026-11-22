# 画像で探す(findImage, findImages, existImage)

[in English](find_image.md)

画面の中から、テンプレート画像に最も近い見た目の要素を探します。
id もラベルも持たないアイコンのように、セレクタで指せない要素を取得するときに使います。
`existImage` は同じ探し方で、画像が画面にあることを検証します。

## 関数

| 関数 | 説明 |
|---|---|
| `findImage(label, threshold:, aspectRatioTolerance:, waitSeconds:, scroll:, maxSwipes:)` | テンプレート画像に最も近い要素を1つ取得します。見つからなくても失敗せず、空の要素を返します(`.isEmpty` で分岐します)。既定では今の画面を1回だけ見ます(`waitSeconds` 既定 0)。出るのを待つときは `waitSeconds` に秒数を渡します。 |
| `findImages(label, threshold:, aspectRatioTolerance:)` | `threshold` を下回る要素を、近い順にすべて返します(`[FTElement]`)。今の画面を1回だけ見ます(待たない・スクロールしない)。`threshold: nil` なら絞りません。 |
| `existImage(label, threshold:, aspectRatioTolerance:, waitSeconds:, scroll:, maxSwipes:)` | テンプレート画像が画面にあることを検証します。探し方は `findImage` と同じで、**見つからなければ失敗**します。見つけた要素を返します。`waitSeconds` を省くと、実行プロファイルの既定の待ち時間まで、出るのを待ちます(`exist` と同じ)。 |
| `element.tap(holdSeconds:, maxGestureSeconds:, settle:)` | 取得した要素をタップします。`findImage` / `findImages` で取得した要素は、見つけた枠の中心を座標でタップします。`holdSeconds` を 0 より大きくすると長押しになります(上限は既定 10 秒で、`maxGestureSeconds:` を渡すとこの1回だけ最大 60 秒まで上げられます)。 |

## 例

```swift
findImage("[Camera Icon]").tap()

let icon = findImage("[Camera Icon]", waitSeconds: 3)
if icon.isEmpty {
    // 見つからなかったとき
}

findImage("[Share Icon]", scroll: .down).tap()

let stars = findImages("[Star Icon]")
stars.first?.tap()

existImage("[Camera Icon]")
existImage("[Share Icon]", scroll: .down).tap()
```

## 注意点

- 記録には距離と比べた候補の数が出ます(見つからなかったときは最も近かった距離)。`threshold` を決めるときの目安にしてください。
- **文字だけが違う同じ形の部品(リストの行など)は見分けにくい**です。距離が既定の `threshold`(0.15)を下回って
  別の行を取得することがあります。こうした部品を探すときは、記録の距離を見て `threshold` を絞ってください(例: `threshold: 0.03`)。
- **テンプレート画像は、テストを回す端末の OS の版・画面の倍率ごとに採ってください。** 同じ行でも OS の版が違うと、文字の
  描き方の違いで距離が離れます(見た目では分からない差でも離れます)。同じ OS の版の端末どうしなら距離はほぼ0です。
  `findImage` / `existImage` はラベルのフォルダのテンプレート画像を全部試すので、版ごとのテンプレート画像を同じフォルダへ足すだけで
  両方の端末で取得できます(`threshold` を絞ったまま使えます)。`findImages` も同じです。
  オン / オフのように状態で見た目が変わる部品も、両方のテンプレート画像を置けば両方を返します。
- **バリアントの run では、そのバリアントで撮ったテンプレート画像も同じラベルのフォルダへ足します。** 外観や文字サイズが変わると
  同じ部品の見た目も変わります。照合に使った(見つからなければ最も近かった)テンプレート画像のファイル名は、実行ログと結果の注記に出ます。
  バリアントの run で `existImage` が失敗したときは、失敗の文言が「そのバリアントで撮った画像(ファイル名に `-variant-<名前>` が付いたもの)があるかどうか」を示します。`findImage` / `findImages` は示さないので、記録の注記(`nearest template …`)に出る使ったテンプレート画像のファイル名を見てください。
  無いときは AI アシスタントが MCP の `ft_capture_element` に `variant` を付けて撮り足せます(端末をそのバリアントの表示条件にして撮り、終わりに元へ戻します)。
  既にあって合わないときは撮り足さず、画面が崩れていないかを確かめてください(崩れた画面を正解として取り込まないため)。
- `waitSeconds` の既定は 0 で、今の画面を1回だけ見ます(実行プロファイルの既定の待ち時間には従いません)。画面が切り替わった直後など、
  画像が出るのを待つときは `waitSeconds: 3` のように秒数を渡してください。スクロールしながら探すときは、位置ごとに1回だけ見ます。
- `existImage` が失敗したときは、失敗の文言に最も近かった距離と `threshold` が出て、判定に使ったスクリーンショットがレポートの
  そのステップに添えられます。待っている間は、スクリーンショットを撮り直して比べます。
- `withScrollDown { }` などの中では、`findImage` も `existImage` もスクロールしながら探します。今の画面だけを見るときは
  `scroll: .noScroll` を渡します(`existImage("[Icon]", scroll: .noScroll)`)。
- スクロールしながら探すときは `scroll:` を渡します(`findImage("[Icon]", scroll: .down)`)。`exist` や `select` と同じ書き方です。
  `findImageWithScrollDown` や `tapWithScrollDown` のような関数名の別名は、どのコマンドにもありません(書くとコンパイルエラーが正しい書き方を示します)。
- テンプレート画像が1枚も無いときは、設定の誤りとして失敗します。
- まれに、Mac の画像処理(Vision)が一時的におかしな特徴量を返し、距離を信用できなくなることがあります
  (Mac の負荷が高いときに出ます)。検知すると、待ってから探し直します(デバイスへの操作は繰り返しません。
  ステップには注記 `vision-anomaly-retried` が残ります)。待っても戻らないときだけ失敗し、文言は
  `Vision returned the same image feature print for different images` または
  `Vision returned a different image feature print for the same image` で始まります。
  run をやり直し、続くなら Mac を再起動してください。
- スクリーンショットのアプリの部分が一色(真っ黒・真っ白)のときは、撮れていないとみなして比べません。
  待ってから撮り直し(注記 `blank-screenshot-retaken`)、それでも一色なら失敗します。
- iOS の既定のモード(inapp-boost)で比べる絵の撮り方は、テキストの可視性検証と同じです(キーボードかシステムアラートが
  出ているときだけ画面全体を撮ります。[テキストの可視性検証の判定](../testclass/text_visibility_check_ja.md) の「制限」)。
  覆われた要素は、画面全体の絵では覆いの絵として比べられます。
- 見つけた要素に書けるセレクタ(id か一意なラベル)があれば、`textIs` などの検証をつなげられます。
- 見つけてから画面を動かすと、`tap()` は古い座標をタップします。見つけた直後にタップしてください。
- 候補の切り出しはアクセシビリティ要素の枠です。アクセシビリティに
  出てこない部品は探せません。

## 探し方

1. テンプレート画像を DefaultClassifier のテンプレート画像から探します。ラベル(フォルダ)が `label` で終わるフォルダの画像を使い、
   `@i`(iOS)/ `@a`(Android)の付いた、実行中の OS 向けのものを先に試します。
2. 画面のアクセシビリティ要素を、要素の枠でスクリーンショットから切り出します。テンプレート画像と**アスペクト比が近い**要素
   (許容幅 `aspectRatioTolerance`、既定 0.2)だけを、近い順に候補にします。
3. 候補ごとに、テンプレート画像との**画像特徴量の距離**(Vision の FeaturePrint。小さいほど似ている)を測ります。
4. `findImage` は最も近い1件が `threshold`(既定 0.15)以下なら取得します。超えたときは、その1件を
   DefaultClassifier に掛けます([imageIs](image_assertion_ja.md) と同じ分類器)。ラベルが一致し、さらにそのラベルの
   テンプレート画像のどれかとの距離が `threshold` 以下(または分類の確信度が `threshold` 以下)のときだけ取得します。
   分類器はテンプレート画像のどれかのラベルを必ず答えるので、ラベルの一致だけでは取得しません。

## テンプレート画像の置き場所

[imageIs](image_assertion_ja.md) と同じテンプレート画像を使います。

```
<プロジェクト>/vision/classifiers/DefaultClassifier/
  @i/Home/[Camera Icon]/   テンプレート画像(png / jpg)
  @a/Home/[Camera Icon]/
```

- テンプレート画像は、探したい要素の**枠そのもの**を切り出したものを置きます(`fleetest vision capture` で切り出せます。
  MCP からの使い方は [MCP サーバー](../tools/mcp_server_ja.md))。
- `findImages` もラベルのフォルダのテンプレート画像を全部使います。同じ要素に複数のテンプレート画像が当たったときは、最も近い距離で1件にまとめます。

### Link
- [index](../../index_ja.md)
