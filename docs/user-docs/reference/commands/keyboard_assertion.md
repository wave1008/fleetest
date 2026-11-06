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

- **How "shown" and "hidden" are decided.** The keyboard frame the bridge reports decides: a frame outside the bottom
  of the screen (a hidden or minimized keyboard) counts as hidden, a frame on the screen counts as shown. When the
  bridge reports no frame, its shown/hidden flag is used instead. With neither, the state is unknown, and unknown
  is never read as hidden, to avoid a false success: `keyboardIsNotShown` fails with "cannot determine the keyboard
  state". While the keyboard is visible it fails with "keyboard is still shown". In iOS xcuitest mode the bridge may
  not give an answer that confirms the keyboard is hidden, so `keyboardIsNotShown` can fail there with
  "cannot determine the keyboard state"; use inapp-boost mode (or Android) when the scenario must confirm it.

### Link
- [index](../../index.md)
