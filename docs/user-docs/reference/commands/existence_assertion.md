# exist, notExist, countIs

[in Japanese(日本語)](existence_assertion_ja.md)

Checks whether elements matched by a selector exist, are gone, or number a given count.

## Functions

| function | description |
|---|---|
| `exist(selector, requireVisible:, waitSeconds:, scroll:, maxSwipes:)` | Asserts existence and returns the matched element, so text/value/id checks can chain onto it. On a run with `fmTextVisibilityCheck` or `ocrTextVisibilityCheck` set to `true` in the run profile, also confirms the element is actually visible. |
| `notExist(selector, waitSeconds:, scroll:, maxSwipes:)` | Waits until the element is gone (already absent succeeds immediately). With `scroll:`, scrolls in that direction while searching, and finding the element fails the check; without a match while scrolling, falls back to waiting for disappearance on the current viewport. |
| `countIs(selector, count, waitSeconds:)` | Asserts the number of matching candidates in the tree. Visibility is not considered. `\|\|` counts the union (duplicates counted once). When counting by label, narrow by type first, e.g. `.button&&Add` — a button and its inner label are separate elements and both would match a bare label. |
| `exist(selector, scroll: .noScroll)` | Checks existence on the current screen even inside a `withScrollDown` / `withScrollUp` / `withScrollRight` / `withScrollLeft` block. |

`waitForDisplay` / `waitForClose` wait for an element to appear or disappear without scrolling —
see [wait](./wait.md).

## Example

```swift
expectation {
    exist("#welcome_text||Welcome")
    notExist("#loading_spinner")
    countIs("#cart_item", 3)
}
```

## Notes

- `exist`'s return value chains into text/value/id checks. See [Text Assertion](./text_assertion.md),
  [Value Assertion](./value_assertion.md), [idIs](./id_assertion.md).
- `exist` / `notExist` / `countIs` always take a selector — they are the commands that resolve
  more than one element, so there is no implicit form that operates on the last grabbed element.
- **`notExist` does not look at visibility.** It judges only whether the element is gone from the
  accessibility tree. An element that is merely covered by another modal but still in the tree
  counts as still present, and the check fails once the wait runs out (unlike `exist` / `select`,
  which by default also confirm that the element is visible).
- **An absence check that passes while a dialog in front hides what is behind it gets the note `absence-behind-modal`.** An in-screen modal or a separate window in front on iOS, and the app's own dialog on Android, can take the elements behind them out of the accessibility tree, and then `notExist` / `countIs(…, 0)` pass even when the element is behind the dialog (in some frameworks the elements behind stay in the tree and count as still present, as above). The result does not change, so close the dialog first when you want to check what is behind it. The note's text also appears in the step's line of the report.
- **On Android, an absence check that read another app's screen gets the note `absence-checked-on-another-app`.** If the app in front when `notExist` / `countIs(…, 0)` passes is not the app under test (another app launched by the scenario, or the launcher after the scenario stopped the app under test), the check says nothing about the app under test. The result does not change, because some scenarios mean to check another app; bring the app under test back first if it was the one meant.
- **A `countIs` that counts inside a scrolling list whose content continues past its edge gets the note `count-in-scrolling-list`.**
  How many rows are on the screen depends on the screen size and orientation, so the same count can differ on another
  device. The result does not change; count what does not depend on the screen (or scroll to each item and check it).
- The "actually visible" check compares the text drawn on screen with the expected text. When
  **only the beginning is drawn** (the same holds for text and value assertions):
  - an ellipsis (`…`) is drawn at the end → green, as truncation the app intended; the step gets
    the note `text-ellipsized`
  - no ellipsis, and more than half of the expected text is drawn → green; the step gets the note
    `text-partially-hidden` (part of the text is hidden)
  - no ellipsis, and half or less is drawn → failed (`most of the text is hidden`). For a screen
    that hides most of a text on purpose, use `requireVisible: false`
  - For examples with images, see [How the text visibility check decides](../testclass/text_visibility_check.md)
- **When several elements match the selector of `exist`, it passes if the text of any one of them is visible.** If the first match is judged not visible, the remaining matches are checked in order (for example, a product image whose description equals the product name and comes first). A selector with an index `[n]` or a relative selector checks only that one element (text assertions do the same, checking only matches whose value fits the expectation).
- **A step named `screen rendering check (…)` that fails is not a mistake in the scenario steps.** It is a screenshot showing that the iOS Simulator stopped drawing (the app area is one colour, or no text is drawn at all). Run the scenario again without rewriting it, and restart the app or the Simulator if it keeps failing. See [Screen rendering check](../testclass/text_visibility_check.md#screen-rendering-check-ios-simulator-only).
- **In an app that shows skeleton rows with the same `#id` as the real rows while loading, `exist` passes before loading finishes.** Do not use it as the completion check; use `enabledIsTrue()` (when the skeleton is exposed as disabled) or a count echo of the loaded rows. Verifying a transient state that ends quickly (`state=loading` and the like) splits into pass and fail depending on the device's speed ([UI component quirks](../writing/ui_component_patterns.md#loading-skeletons)).
- **Even when you target an element by `#id`, the text visibility check looks for its label drawn on screen.** On Android, an element whose label
  comes only from its spoken description (such as `No formula` on the empty formula field of the calculator, or an icon button) is not required to show
  that text when the element is known to be a View or Compose component. In Flutter apps, and on devices where the component kind cannot be told, an
  element whose label is only read aloud and never drawn fails. To check only that it exists, write `exist("#formula", requireVisible: false)`.
  The MCP check while writing does not run the visibility check, so this first fails in the real run.

### Link
- [index](../../index.md)
