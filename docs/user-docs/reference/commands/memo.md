# Memo (writeMemo, readMemo, clearMemo, memoTextAs, writeRunMemo, readRunMemo, clearRunMemo, runMemoTextAs)

[in Japanese(日本語)](memo_ja.md)

Pass values around. Every `@Test` runs as its own process, so a Swift variable does not carry over. There are two memos:

- **The memo (`writeMemo` etc.)** lives only inside **one test function** (its `beforeEach()`, body and `afterEach()`). Use it to carry a value from one step to another of the same test.
- **The run memo (`writeRunMemo` etc.)** is shared by **every scenario of the run, on every device and every machine**. Use it to hand a value to other tests.

## Functions

| function | description |
|---|---|
| `writeMemo(key, text)` | Appends `text` to the key's history (this test only). |
| `readMemo(key) -> String` | Returns the **last** value written under the key in this test, or `""` when there is none (not a failure; the step carries the note `memo-key-not-found`). |
| `clearMemo()` | Clears the whole memo of this test. |
| `element.memoTextAs(key)` | Writes the grabbed element's text (the first non-empty of label and value) and returns the element. Fails if no element was grabbed. |
| `string.memoTextAs(key)` | Writes the string and returns it. |
| `writeRunMemo(key, text)` | Appends `text` to the key's history in the run memo. |
| `readRunMemo(key) -> String` | Returns the **last** value written under the key in the run memo, or `""` when there is none (not a failure; the step carries the note `run-memo-key-not-found`). |
| `clearRunMemo()` | Clears the whole run memo. |
| `element.runMemoTextAs(key)` | Writes the grabbed element's text to the run memo and returns the element. Fails if no element was grabbed. |
| `string.runMemoTextAs(key)` | Writes the string to the run memo and returns it. |

## Scope

### The memo (`writeMemo` etc.)

- It exists only inside one test function: `beforeEach()`, the body and `afterEach()` share it, and the next test starts with an empty memo. It is never passed to another scenario.

### The run memo (`writeRunMemo` etc.)

- It is shared by every scenario of the run (on any device, across machines). It starts empty in each run and is not carried over to the next run.
- When `fleetest run --target` runs several run profiles of the same project in one go (for example Android and iOS), they all share one run memo. To keep values apart per profile, put the OS or similar into the key (decide the key inside `ios { }` / `android { }`).
- The reliable pattern is **write with `writeRunMemo` in `beforeRun()` of an [`@RunHooks`](../testclass/creating_testclass.md#run-wide-preparation-and-cleanup-runhooks--beforerun--afterrun) class, and read with `readRunMemo` in each test**.
- A scenario reads **the run memo as it was when the scenario started** (plus its own writes); values that other scenarios write while it runs are not visible.
- `afterRun()` can read the run memo but not write it. To leave one combined line at the end of a run, have the tests write a combined key (inside `withRunLock` when several scenarios update it) and read that one key in `afterRun()`.
- **Writes are not exclusive.** When you need exclusion, use a [run-wide lock](run_lock.md).

## Example

```swift
import FTDSL

@RunHooks
class RunSetup {
    func beforeRun() {
        writeRunMemo("shop", data("[shop1].name"))
    }
}

@TestClass
class OrderFlow {
    @Test("the receipt shows the shop")
    func S0010() {
        scenario {
            scene(1, "Check") {
                expectation {
                    select("#receipt_shop").textIs(readRunMemo("shop"))
                }
            }
        }
    }

    @Test("the memo carries a value within one test")
    func S0020() {
        scenario {
            scene(1, "Remember") {
                action {
                    select("#order_no").memoTextAs("orderNo")
                }
            }
            scene(2, "Check") {
                expectation {
                    select("#receipt_order_no").textIs(readMemo("orderNo"))
                }
            }
        }
    }
}
```

### Link
- [index](../../index.md)
