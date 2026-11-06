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

- **「表示」「非表示」の決め方。** ブリッジが申告するキーボードの枠で決めます。枠が画面の下端の外にある
  (隠れた・最小化したキーボード)なら非表示、枠が画面の中にあれば表示と読みます。枠の申告が無いときは、
  ブリッジの表示/非表示のフラグを使います。どちらも無ければ不明で、不明を非表示と読んで嘘の成功にはしません:
  `keyboardIsNotShown` は「cannot determine the keyboard state」で失敗し、キーボードが見えている間は
  「keyboard is still shown」で失敗します。iOS の xcuitest モードでは、ブリッジが非表示を確定できる答えを返さない
  ことがあり、その場合 `keyboardIsNotShown` は「cannot determine the keyboard state」で失敗します。
  キーボードが閉じたことを確かめたいシナリオは、inapp-boost モード(または Android)で書いてください。

### Link
- [index](../../index_ja.md)
