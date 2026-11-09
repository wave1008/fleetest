# clearInput

[in Japanese(日本語)](clear_input_ja.md)

Empties an input field.

## Functions

| function | description |
|---|---|
| `clearInput(settle:)` | Empties the currently focused input field. When no element in the screen's element list reports focus, it cannot check that the field was emptied, so it passes with the note `clear-input-unverified` (check the value with `valueIs`). |
| `clearInput(sel, settle:waitSeconds:scroll:maxSwipes:)` | Empties the specified input field. |

## Example

```swift
tap("#note")
clearInput()
type("new content")

clearInput("#note")
type("#note", "new content")

// one step instead of clearInput + type
type("#note", "new content", replace: true)
```

## Notes

- **On Android, a field whose centre is under a popup window (such as autocomplete suggestions) is not touched.** The tap that focuses the field would
  select the suggestion and change another field, so the step fails before anything is cleared. Close the popup first.
- **Pointing it at a button or another non-input element fails before anything is cleared.** `clearInput` taps its
  target first, so clearing a button would press it (a submit or a purchase). It refuses whatever the UI framework (Compose and Flutter
  included), only when the element's type is a button, switch, link and so on. Pointing at an
  element that wraps exactly one input field is not refused (it runs as before).
- **Fields whose value does not mirror the input** (the iOS Material 3 SearchBar reports a fixed hint text as its value) look
  like "the value remained" after clearing. When the value is unchanged, the tool reads the field on screen (OCR); if
  nothing but the field's placeholder (or other text the screen's element tree places inside the field) is drawn there, the step passes with the note `clear-residual-not-drawn`. If any other
  text is drawn, the field is masked, the keyboard covers it or OCR is unavailable, the step fails as before.
- **Whitespace cannot be verified.** Whitespace-only content is invisible to accessibility, so the tool cannot verify that it was cleared, and a lost trailing/middle space after `type` is not detected either — assert values where whitespace matters with `valueIs`.

- `type` appends rather than overwrites, so clear the field first when you need to replace its
  contents. If you only want to save a selector resolution, `type(sel, "some text", replace: true)`
  folds the clear and the type into a single command. See [type](./type.md).
- On the Flutter iOS build, the in-app bridge cannot clear the field itself and automatically
  falls back to the XCUITest bridge for this one command (adds roughly one to two seconds).
- **`settle: false`** skips this command's post-action wait for the screen to settle (the next step may see a moving screen). See [tap](./tap.md) for details.

### Link
- [index](../../index.md)
