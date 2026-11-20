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
- **Reading and writing it outside a test fails** — in `beforeAll()`, `setUpDevice()`, `tearDownDevice()`, `afterAll()`, `beforeRun()` and `afterRun()` (it is stopped even when made through a helper function).
  The error tells you to use `writeRunMemo` / `readRunMemo` to share a value across the run.

### The run memo (`writeRunMemo` etc.)

- It is shared by **every scenario of the run, on every device and, in a run that spans machines, across the machines too**. Nothing carries over to the next run.
  A single invocation (an MCP call, or running the scenario runner by hand) starts with an empty run memo.
- The reliable pattern is **write with `writeRunMemo` in `beforeRun()` of an [`@RunHooks`](../testclass/creating_testclass.md#run-wide-preparation-and-cleanup-runhooks--beforerun--afterrun) class, read with `readRunMemo` in each test**:
  `beforeRun()` runs once per run, before any scenario on any machine, so every test sees the value from its first line. For a value that needs the app or the machine, write it in `beforeAll()` instead (it is per class, and once per machine in a run that spans machines, so do not use it for a run-wide value):
  it runs once per run per class (once per machine in a run that spans machines), before any scenario of that class on that machine's devices (other devices wait until it finishes).
- `afterRun()` can read the run memo (the final values) but cannot write it, like `afterAll()`. `beforeRun()` and `afterRun()` cannot use the per-test memo (`writeMemo` etc.) either.
- **To pass a value from one `@Test` to another, use a `@RunInOrder` class and `writeRunMemo` in the earlier test.** In any other class neither the order nor the device is
  fixed ([Running a class in one place or in order](../testclass/creating_testclass.md#running-a-class-in-one-place-or-in-order-runonsinglemachine--runonsingledevice--runinorder)).
- **Writing the run memo (`writeRunMemo`, `runMemoTextAs`, `clearRunMemo`) in `setUpDevice()`, `tearDownDevice()`, `afterAll()` or `afterRun()` fails.** (`beforeRun()` can write.) A write in
  `setUpDevice()` is overwritten by other devices' values, and a write made in `tearDownDevice()`, `afterAll()` or `afterRun()` comes after the tests have finished, so no test reads it. Reading is fine
  (`afterAll()` runs after every device has finished the run, so it sees the final values). `readRunMemo` on a missing key still returns `""`.
- The run memo **starts empty in every run** (values from a previous run are not kept).
- A scenario sees the run memo as it was **when the scenario started** (plus what it writes itself) — values another device writes while it runs are not visible to it.
- **Across machines a write reaches the other machines a little later.** A machine sees its own write from the next scenario on; the other machines see it
  from a scenario that starts after it arrives. In the end every machine holds the same history in the same order.
- **Plain run memo writes are not locked.** Writes are never lost and are appended in the order they arrive, but the run memo does not guarantee anything about another scenario writing
  between your read and your write, or about which of two simultaneous writes to one key comes last. **Write each key from one place** — make the key per test
  (for example `"orderId_S0010"`). When you need exclusion (a counter, a "claim this item" step), use [run-wide locks](#run-wide-locks-withexclusivelock-withsharedlock) for light cases, or the database of your test server for heavy or run-spanning ones.
- `clearRunMemo()` clears the run memo as it stands at that point, including your own writes not yet confirmed.
- **In a run whose run profile has devices on several machines** (and a run sent to another machine with `--runner`), the run memo is one memo across the machines.
  **The exception is a `--fleet` run**: with or without `--split`, its run memo is shared per machine, not across machines (the run prints one line at the start saying so).
- Trying to pass a value through a test-class property (`var`) produces a build warning when the writer
  and the reader run in different processes — written in one `@Test` and read in another, or written in
  `beforeAll()` and read in the tests. Writing in `beforeEach()` and reading in the same test or
  `afterEach()` works and is not flagged. Writes through helper functions and mutations such as
  `x.append(…)` are not detected, so no warning is not a guarantee.
- If `beforeAll()` fails, the remaining scenarios of that class in the run are recorded as failed
  without running; it is never re-run. If `setUpDevice()` fails, the remaining
  scenarios of that class on that device are recorded as failed without running.

## Run-wide locks (`withExclusiveLock`, `withSharedLock`)

```swift
withExclusiveLock("counter") {
    let n = Int(readRunMemo("count")) ?? 0
    writeRunMemo("count", String(n + 1))
}
```

- `withExclusiveLock(keys..., waitSeconds:) { }` runs the block while no other scenario of the run holds any of the keys; `withSharedLock` lets
  several scenarios hold the same keys at once but keeps exclusive holders out. **Use a shared lock only to read.**
- Keys: one or more, not blank, no control characters, at most 120 bytes each and 8 per call. Several keys in one call are taken one by one in
  the order of their names (UTF-8 bytes). A nested call may only take keys that sort after every key you hold, otherwise it is an error even
  when nothing contends: **take all the keys in one call instead of nesting**. Taking a key again that you already hold does nothing
  (exclusive in exclusive, shared in exclusive, shared in shared); taking it exclusively inside a shared lock on it is an error.
- It waits until the keys are free. The wait is not counted in `scenarioTimeout`. One call waits at most the longest `scenarioTimeout` of the
  run (including `@Test(scenarioTimeout:)`); `waitSeconds:` makes it shorter. On timeout the step fails and the block does not run.
  Under heavy contention the wait can reach this cap, so use a database for heavy or cross-run exclusion. **Do not use a lock to wait for
  another test to finish** (the order scenarios are handed out differs between one machine and many).
- Inside a lock, `writeRunMemo` / `clearRunMemo` / `runMemoTextAs` are committed before the next step and `readRunMemo` returns the latest
  value (the value stays visible after the lock). Writing needs an exclusive lock on some key: inside shared locks only it is an error.
  **Write a key that a lock guards only inside the lock.** A value over the run memo size limit is an error.
- If the scenario fails, the block is skipped; once the scenario is aborted inside the block the rest of your plain Swift code still runs, and the
  lock is released when the block exits. A scenario that is requeued runs the block again (a counter is added twice).
- **Your own run memo writes outside the lock** are applied before a read or write inside the lock answers (the lock waits for the writes this scenario already made, so they are neither lost nor overwritten); writes of other scenarios are ordered only by the locks. Use shared locks only for reading. A retried scenario runs the block again. With many devices, heavy contention can reach the wait cap.
- A dry-run runs the block without locking (order violations are still reported). In a run that spans several machines, the lock works for scenarios running on the machine that started the run;
  on machines reached over ssh, and in an entry of `--fleet`, the call fails with an explanation instead of splitting the lock silently. Not accepted by `ft_batch`.

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

## Notes

- Write a key that a run-wide lock guards only inside the lock (see [Run-wide locks](#run-wide-locks-withexclusivelock-withsharedlock)).
- Use `withSharedLock` only to read; a retried scenario runs the lock block again.
- Run-wide locks do not work on machines reached over ssh or in `--fleet`; use the test server's database for heavy or run-spanning exclusion.

### Link
- [index](../../index.md)
