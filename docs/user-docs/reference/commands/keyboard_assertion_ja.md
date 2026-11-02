# キーボードの検証(keyboardIsShown, keyboardIsNotShown)

[in English](keyboard_assertion.md)

ソフトキーボードの表示/非表示を検証します。開閉はアニメーションを伴うため、どちらも `waitSeconds` までポーリングします。省略すると実行プロファイルの既定の待ち時間(標準 5 秒)です。

## 関数

| 関数 | 説明 |
|---|---|
| `keyboardIsShown(waitSeconds:)` | ソフトキーボードが表示されていることを検証します。 |
| `keyboardIsNotShown(waitSeconds:)` | ソフトキーボードが非表示であることを検証します。 |

## 例

```swift
tap("#email")
keyboardIsShown()
tap("#login_btn")
keyboardIsNotShown()
```

## 注意点

- **「非表示」の読み方は構成で違います。** iOS の inapp-boost モードと Android は非表示を直接申告します。
  iOS の xcuitest モードは「キーボードを見た」か「不明」しか言えないので、
  `keyboardIsNotShown` は、画面が落ち着いたあとにキーボードが木に無ければ通ります
  (画面が動いている間は通しません。上がり始めたキーボードを非表示と取り違えないためです)。
  見えている間は「keyboard is still shown」で失敗します。Android の不明は非表示と読みません
  — 「cannot determine the keyboard state」で失敗します(嘘の成功にしない設計です)。

### Link
- [index](../../index_ja.md)
