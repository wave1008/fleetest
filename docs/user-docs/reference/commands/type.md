# type

[in Japanese(日本語)](type_ja.md)

Types text into a field, either the currently focused one or a specified element.

## Functions

| function | description |
|---|---|
| `type("some text", replace: false, settle:)` | Types into the **currently focused** element (focus it first with `tap(inputField)`). The argument is text, not a selector — passing something that looks like a selector (starts with `#`, or contains `\|\|` / `>>`) fails before execution rather than silently typing the literal string. To actually type such a string, use the two-argument form `type("#field", "#email")`. `replace: true` clears the field (like `clearInput`) before typing. It reads the field back after typing and fixes dropped characters, the same as `type(sel, "some text")` (when the focused field cannot be told apart in the screen, or it is a password field, it types once without checking). |
| `type(sel, "some text", replace:settle:waitSeconds:scroll:maxSwipes:)` | Resolves the element, then types into it. Japanese text is typed as-is (no IME switching needed). `replace: true` clears the field before typing. After clearing, it finds the same field again before typing, and fails without typing if it cannot (so it never types into a different field). |
| `select(sel).type("some text", replace:settle:waitSeconds:)` | Types into the grabbed element. It resolves the grabbed selector again, so it behaves exactly like `type(sel, "some text")`. It fails on an element that was not found. Elements found by `findImage` / `findImages` cannot be typed into this way (call `.tap()` first, then `type("some text")`). **To just type, write `type(sel, "some text")`** — `select` only adds a step. |

## Example

```swift
tap("#field")
type("abc")                        // tap first to focus, then type

type("#email", "test@example.com") // selector form: resolve + focus + type in one step
type("#note", "new contents", replace: true)

let field = select("#login_id")    // only when the grabbed element is used later
field.type("alice")                // same as type("#login_id", "alice")
```

## Notes

- **Pointing it at a button or another non-input element fails before anything is typed.** `type` taps its target
  first, so typing into a button would press it (a submit or a purchase). It refuses whatever the UI framework (Compose and Flutter
  included), only when the element's type is a button, switch, link and so on. Pointing at an
  element that wraps exactly one input field types into it with a warning.
- **Typing into a field that already has a value appends; the step does not fail** (it only gets a
  note that the field already held a value). To replace the contents, use
  `type(sel, "some text", replace: true)` or call `clearInput(sel)` first. See
  [clearInput](./clear_input.md).
- **Line breaks (`\n`) follow the OS default.** On iOS this arrives as a Return key press: it
  inserts a newline in a multi-line field, or fires the field's commit action (search, done, …)
  in a single-line field — which one happens depends on the field, not on `type`. On Android, a
  trailing newline is likewise sent as Enter, but a newline in the middle of the text is written into the field as a character
  (a single-line field keeps it and its action does not fire). The step's note says that the newline was written as a character, and suggests splitting the text with `pressEnter()` only when the field is known to be single-line. If the intent is to commit (search/submit), use
  [`pressEnter()`](./press_enter_hide_keyboard.md) instead — `type("watch\n")` does not tell the
  reader whether a newline or a submit was intended.
  On iOS in the `xcuitest` mode (where the XCUITest bridge types), text with a newline in the middle is typed in one go
  and is not read back; the step's note says so. To have each line checked, split it: `type("a")`, `pressEnter()`, `type("b")`.
- **The next action waits for the soft keyboard, on Android and also on iOS.** `type` can return before the keyboard is shown, so the
  next action waits up to 1.5 seconds for it to appear before resolving its target (otherwise the layout can move
  after the target was resolved). On Android this is every `type` that started with no keyboard showing; on iOS it is only while the keyboard is reported below the
  screen's bottom edge (it is still rising), or when no keyboard has been reported and none has been seen to fail to appear on
  that device. If it does not appear, the action proceeds as usual and the step gets the note `keyboard-not-shown-after-type`
  (after a `tap` on an Android field, `keyboard-not-shown-after-tap`). The wait is skipped when the typed text ends with a newline.
- **`tap(inputField)` → `type("some text")` is supported.** On Android, input fields are often a
  container (Material's `TextInputLayout`) wrapping the actual field (`TextInputEditText`), and
  the `#id` frequently resolves to the container. Tapping the container does not always move
  focus into the field inside it. When `type` finds that focus did not land in a field after the
  preceding `tap`, it locates the field by name and types into it instead:

  ```
  ✅ type "abc"(typed into textField (the tree showed no focused field after the preceding tap))
  ```

  This recovery only looks at the tree immediately after the tap, only targets the tapped
  element itself or the single input field inside it (nothing is guessed when there are two or
  more candidate fields), and is recorded as the note `type-focus-recovered`. If it cannot
  recover (the field is ambiguous), write the selector form instead —
  `type(sel, "some text")` resolves, focuses, and reads the value back in one step.

- **On Android, `type("some text")` without a selector checks where the text went.** After typing, if no element in the screen reports input focus, the step still passes but gets the note `type-focus-not-reported`: where the text went could not be confirmed (a full-screen keyboard in landscape, a field inside a WebView, or a hidden input may not show focus in the tree; otherwise the text may have gone nowhere). Check the screen, or write the selector form `type(sel, "some text")`.

- **On Android, typing without a selector while another app is in front is noted.** If the app in
  front is not the one started with `launchApp` / `restartApp`, the step still sends the text but
  gets the note `ref-less-input-on-other-app`: the focused field belongs to that other app, and the
  text may have gone there. `clearInput()` and `pressEnter()` without a selector are noted the same
  way. Pass the field's selector to make sure the text goes to your app.

- **The typed value is read back and repaired.** A missing tail is re-sent, a doubled value is
  trimmed, and **a character dropped mid-string (`hello123` → `hllo123`) clears the field and
  retypes the whole text** (note `type-retyped`). It retypes at most once — if the same
  characters go missing again, the app itself is transforming the input (a digits-only field
  discarding letters, for example), so verification is abandoned and the value is accepted
  (note `type-retype-abandoned`; check the value separately with `valueIs`).
- **On Android, when the end of the typed text did not stay in the field, the step description
  says so** (for example, typing 7 characters into a field limited to 6 digits shows "the field did
  not keep the last 1 character(s) written"). The result does not change, so check the value with
  `textIs` / `valueIs` when every character must be there.
- **If the value does not move at all, the screen is checked first**, because some fields do
  not reflect the input in their value (a Material3 SearchBar on iOS reports a description).
  If the typed text is drawn in the field (OCR, macOS 27+ only; on macOS 26 the screen is not read and the input is not re-sent), it is accepted without retyping (note
  `type-readback-unchanged`). If not, the input is treated as lost and re-sent. **The re-send
  happens at most once**; if the value still does not move, the step fails (repeating the
  re-send could duplicate the input).
- **`settle: false`** skips this command's post-action wait for the screen to settle (the next step may see a moving screen). See [tap](./tap.md) for details.

### Link
- [index](../../index.md)
