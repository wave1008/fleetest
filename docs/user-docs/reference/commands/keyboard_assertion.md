# Keyboard assertion (keyboardIsShown, keyboardIsNotShown)

[in Japanese(日本語)](keyboard_assertion_ja.md)

Checks whether the soft keyboard is shown. Opening and closing are animated, so both poll up to
`waitSeconds`. Omitted, it is the run profile's default wait (5 seconds as shipped).

## Functions

| function | description |
|---|---|
| `keyboardIsShown(waitSeconds:)` | Asserts the soft keyboard is shown. |
| `keyboardIsNotShown(waitSeconds:)` | Asserts the soft keyboard is hidden. |

## Example

```swift
tap("#email")
keyboardIsShown()
tap("#login_btn")
keyboardIsNotShown()
```

## Notes

- **"Hidden" is read differently per configuration.** iOS inapp-boost mode and Android report
  it directly. iOS xcuitest mode can only say "keyboard seen" or "unknown": there,
  `keyboardIsNotShown` passes once the screen has settled and no keyboard is in the tree
  (it does not pass while the screen is still changing, so a keyboard that is only now rising
  is not mistaken for a hidden one), and fails with "keyboard is still shown" while it is
  visible. On Android, unknown is never read as hidden: it fails with "cannot determine the
  keyboard state" to avoid a false success.

### Link
- [index](../../index.md)
