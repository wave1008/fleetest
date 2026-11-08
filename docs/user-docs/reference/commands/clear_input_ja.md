# clearInput

[in English](clear_input.md)

入力欄を空にします。

## 関数

| 関数 | 説明 |
|---|---|
| `clearInput(settle:)` | フォーカス中の入力欄を空にします。焦点のある欄が画面の要素一覧に無いときは、消えたかを確かめられないので、成功のまま注記 `clear-input-unverified` を付けます(値は `valueIs` で確かめてください)。 |
| `clearInput(sel, settle:waitSeconds:scroll:maxSwipes:)` | 要素を指定して入力欄を空にします。 |

## 例

```swift
tap("#note")
clearInput()
type("new content")

clearInput("#note")
type("#note", "new content")

// clearInput + type を1コマンドに畳む
type("#note", "new content", replace: true)
```

## 注意点

- **ボタンなど入力欄でない要素を指すと、消す前に失敗します。** `clearInput` は消す前に対象をタップするので、
  そのまま撃つと送信・購入などのボタンを押してしまいます。UI フレームワークを問わず(Compose・Flutter でも)、
  要素の型がボタン・スイッチ・リンクなどのときだけ断ります。入力欄を1つだけ包む要素を指したときは、
  断らずに従来どおり実行します。
- **値が入力を映さない欄**(iOS の Material 3 の SearchBar は固定の案内文を値に出します)は、消した後も「値が残った」ように見えます。
  値が変わらないときは、ツールが画面上の欄を読み取り(OCR)、残りの文字がそこに描かれていなければ、注記 `clear-residual-not-drawn` 付きで通します。
  描かれている・伏せ字の欄・キーボードが重なる・OCR が使えないときは、従来どおり失敗します。
- **空白は検証できません。** 空白だけの内容はアクセシビリティの値に載らないため、消えたことをツールは検証できません。`type` の後で末尾・途中の空白が欠けても検出できないので、空白が意味を持つ値は `valueIs` で確かめてください。

- `type` は追記なので、書き換えたいときはまずクリアします。セレクタ解決を1回で済ませたい
  だけなら `type(sel, "文字列", replace: true)` でクリアと入力を1コマンドに畳めます。
  詳細は [type](./type_ja.md) 参照。
- **Flutter の iOS ビルド**では in-app ブリッジでは欄を消せず、この1コマンドだけ自動で
  XCUITest ブリッジへフォールバックします(1〜2秒ほど余分にかかります)。
- **`settle: false`** を渡すと、このコマンドの操作後の「画面が落ち着くまでの待ち」を省きます(次のステップは動いている最中の画面を見ることがあります)。詳細は [tap](./tap_ja.md) 参照。

### Link
- [index](../../index_ja.md)
