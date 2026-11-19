# Memo (writeMemo, readMemo, clearMemo, memoTextAs, writeRunMemo, readRunMemo, clearRunMemo, runMemoTextAs)

[in Japanese(日本語)](memo_ja.md)

Pass values around. Every `@Test` runs as its own process, so a Swift variable does not carry over. There are two memos:

- **The memo (`writeMemo` etc.)** lives only inside **one test** (its `beforeEach()`, body and `afterEach()`). Use it to carry a value from one step to another of the same test.
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

- It exists only in one test: `beforeEach()`, the body and `afterEach()` share it, and the next test starts with an empty memo. It is never passed to another scenario.
- **Reading and writing it outside a test fails** — in `beforeAll()`, `setUpDevice()`, `tearDownDevice()` and `afterAll()` (it is stopped even when made through a helper function).
  The error tells you to use `writeRunMemo` / `readRunMemo` to share a value across the run.

### The run memo (`writeRunMemo` etc.)

- It is shared by **every scenario of the run, on every device and, in a run that spans machines, across the machines too**. Nothing carries over to the next run.
  A single invocation (an MCP call, or running the scenario runner by hand) starts with an empty run memo.
- The reliable pattern is **write with `writeRunMemo` in `beforeAll()`, read with `readRunMemo` in each test**: `beforeAll()` runs once per
  run per class (once per machine in a run that spans machines), before any scenario of that class on that machine's devices (other devices wait until it
  finishes), so the value exists wherever the scenarios land.
- **To pass a value from one `@Test` to another, use a `@RunInOrder` class and `writeRunMemo` in the earlier test.** In any other class neither the order nor the device is
  fixed ([Running a class in one place or in order](../testclass/creating_testclass.md#running-a-class-in-one-place-or-in-order-runonsinglemachine--runonsingledevice--runinorder)).
- **Writing the run memo (`writeRunMemo`, `runMemoTextAs`, `clearRunMemo`) in `setUpDevice()`, `tearDownDevice()` or `afterAll()` fails.** A write in
  `setUpDevice()` is overwritten by other devices' values, and nobody reads a write made in `tearDownDevice()` or `afterAll()`. Reading is fine
  (`afterAll()` runs after every device has finished the run, so it sees the final values). `readRunMemo` on a missing key still returns `""`.
- A scenario sees the run memo as it was **when the scenario started** (plus what it writes itself) — values another device writes while it runs are not visible to it.
- **Across machines a write reaches the other machines a little later.** A machine sees its own write from the next scenario on; the other machines see it
  from a scenario that starts after it arrives. In the end every machine holds the same history in the same order.
- **There is no locking.** Writes are never lost and are appended in the order they arrive, but the run memo does not guarantee anything about another scenario writing
  between your read and your write, or about which of two simultaneous writes to one key comes last. **Write each key from one place** — make the key per test
  (for example `"orderId_S0010"`). When you need real exclusion (a counter, a "claim this item" step), use the database of your test server.
- `clearRunMemo()` clears the run memo as it stands at that point, including your own writes not yet confirmed.
- **In a `--fleet` run (without `--split`) the run memo is shared per machine, not across machines.** The run prints one line at the start saying so.
- Trying to pass a value through a test-class property (`var`) produces a build warning when the writer
  and the reader run in different processes — written in one `@Test` and read in another, or written in
  `beforeAll()` and read in the tests. Writing in `beforeEach()` and reading in the same test or
  `afterEach()` works and is not flagged. Writes through helper functions and mutations such as
  `x.append(…)` are not detected, so no warning is not a guarantee.
- If `beforeAll()` fails, the remaining scenarios of that class in the run are recorded as failed
  without running; it is never re-run. If `setUpDevice()` fails, the remaining
  scenarios of that class on that device are recorded as failed without running.

## Example

```swift
@TestClass
class OrderFlow {
    func beforeAll() {
        launchApp()
        select("#shop_name").runMemoTextAs("shop")
    }

    @Test("the receipt shows the shop")
    func S0010() {
        scenario {
            scene(1, "Check") {
                expectation { select("#receipt_shop").textIs(readRunMemo("shop")) }
            }
        }
    }

    @Test("the memo carries a value within one test")
    func S0020() {
        scenario {
            scene(1, "Remember") {
                action { select("#order_no").memoTextAs("orderNo") }
            }
            scene(2, "Check") {
                expectation { select("#receipt_order_no").textIs(readMemo("orderNo")) }
            }
        }
    }
}
```

### Link
- [index](../../index.md)
