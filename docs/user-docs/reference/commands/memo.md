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
  Each MCP `ft_run_scenario` call is one run: its run memo starts empty (or with what that call's `beforeRun()` wrote) and is shared by the scenarios of that call. Running the scenario runner by hand starts with an empty run memo.
- The reliable pattern is **write with `writeRunMemo` in `beforeRun()` of an [`@RunHooks`](../testclass/creating_testclass.md#run-wide-preparation-and-cleanup-runhooks--beforerun--afterrun) class, read with `readRunMemo` in each test**:
  `beforeRun()` runs once per run, before any scenario on any machine, so every test sees the value from its first line. For a value that needs the app or the machine, write it in `beforeAll()` only in a class with `@RunOnSingleMachine`: `beforeAll()` runs once per class per run, but once per machine in a run that spans machines, so another machine's `beforeAll()` can overwrite the value (put a run-wide value in `beforeRun()`).
  It runs before any scenario of that class on that machine's devices (other devices wait until it finishes).
  If `beforeRun()` did not run (a debug run, a run without a profile, a dry-run), `readRunMemo` of its keys returns `""` instead of failing; check right after reading, for example `readRunMemo("token").thisIsNotEmpty()`.
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
  (for example `"orderId_S0010"`). When you need exclusion (a counter, a "claim this item" step), use [run-wide locks](#run-wide-locks-withrunlock) for light cases, or the database of your test server for heavy or run-spanning ones.
- `clearRunMemo()` clears the run memo as it stands at that point, including your own writes not yet confirmed.
- **In a run whose run profile has devices on several machines** (a run profile whose devices name another machine in `machine`; see [remote runners](../../fleet/remote_runners.md); and a run sent to another machine with `--runner`), the run memo is one memo across the machines.
  **The exception is a `--fleet` run**: with or without `--split`, its run memo is shared per machine, not across machines (the run prints one line at the start saying so).
- Trying to pass a value through a test-class property (`var`) produces a build warning when the writer
  and the reader run in different processes — written in one `@Test` and read in another, or written in
  `beforeAll()` and read in the tests. Writing in `beforeEach()` and reading in the same test or
  `afterEach()` works and is not flagged. Writes through helper functions and mutations such as
  `x.append(…)` are not detected, so no warning is not a guarantee.
- If `beforeAll()` fails, the remaining scenarios of that class in the run are recorded as failed
  without running; it is never re-run. If `setUpDevice()` fails, the remaining
  scenarios of that class on that device are recorded as failed without running.

## Run-wide locks (`withRunLock`)

Use it to occupy a resource that exists only once across device operations (for example, there is a single one-time-password (OTP) inbox, and two devices sending at the same time would pick up each other's value). Wrap sending, receiving and typing in one lock, and the other scenarios wait until it ends.

```swift
withRunLock("otp-inbox") {
    select("#send_otp").tap()
    let otp = readOtpFromInbox()   // your own function that reads the latest OTP from the inbox
    select("#otp_input").tap()
    type(otp)
    select("#verify").tap()
}
```

Exclusion of data only (a counter, for example) can also be done with the test server's database. If serializing by class is enough, use `@RunOnSingleDevice` / `@RunInOrder`. An example that adds to a run memo counter:

```swift
withRunLock("counter") {
    let n = Int(readRunMemo("count")) ?? 0
    writeRunMemo("count", String(n + 1))
}
```

- `withRunLock(keys..., waitSeconds:) { }` runs the block while no other scenario of the run holds any of the keys.
- Keys: one or more, not blank, no control characters, at most 120 bytes each and 8 per call. Several keys in one call are taken one by one in
  the order of their names (UTF-8 bytes). **Calling a lock inside a lock (nesting) is an error**, whether the key is the same or different, even when nothing contends and in a dry-run; a helper function that takes a lock cannot be called from inside a lock (that is nesting too), but calling it from outside a lock is fine (you may put a shared procedure in a function). **Pass all the keys you need in one call.**
- It waits until the keys are free. The wait is not counted in `scenarioTimeout` (in a run that spans several machines it is also excluded from the time limit of the remote parts of the run, which can be extended by at most the length of that limit; a single `run --runner <machine>` does not extend it), and the time each scenario waited is recorded in the results JSON as `lockWaitMs` (the time estimates for ordering and splitting leave it out). One call waits at most the longest `scenarioTimeout` of the
  run (including `@Test(scenarioTimeout:)`). `waitSeconds:` is optional (default: that cap), must be greater than 0 (0 or a negative value is an error, not "try once"), and can only make the wait shorter. On timeout the step fails and the block does not run.
  Under heavy contention the wait can reach this cap, so use a database for heavy or cross-run exclusion. **Do not use a lock to wait for
  another test to finish** (the order scenarios are handed out differs between one machine and many).
- Inside a lock, `writeRunMemo` / `clearRunMemo` / `runMemoTextAs` are committed before the next step and `readRunMemo` returns the latest
  value (the value stays visible after the lock). A write outside any lock works as before.
  **Write a key that a lock guards only inside the lock.** A value over the run memo size limit (about 1.4 MB encoded) is an error inside a lock; outside a lock it stays on its own machine with one warning line.

To read a value from the screen **once per run** and share it across all machines and classes (`beforeRun()` cannot use the device), read it under a lock at the top of each test, so only the first test to get there reads it:

```swift
withRunLock("shop") {
    if readRunMemo("shop").isEmpty { select("#shop_name").runMemoTextAs("shop") }
}
```

Inside the lock `readRunMemo` returns the latest value, so every later test finds it filled and skips the read.
- If the scenario fails, the block is skipped; once the scenario is aborted inside the block the rest of your plain Swift code still runs, and the
  lock is released when the block exits. A scenario that is run again (requeued or retried) runs the block again (a counter is added twice).
- **Your own run memo writes outside the lock** are applied before a read or write inside the lock answers (the lock waits for the writes this scenario already made, so they are neither lost nor overwritten); writes of other scenarios are ordered only by the locks.
- A dry-run runs the block without locking (nesting is still an error). In a run that spans several machines, the lock works on every machine, including machines reached over ssh (the lock server runs on the machine where you started fleetest).
  If the connection of a remote scenario breaks while it holds a key, that key stays unavailable (waiting and new requests fail at once with an explanation) until the run on that machine is confirmed to have ended; the next step that takes it carries a note that the previous holder's writes may be missing. In a `--fleet` run the call fails with an explanation instead of silently splitting the lock.
- Locks are granted at once, without exclusion, inside `beforeRun()` / `afterRun()` and in debug runs.
- The lock server starts only when a `withRunLock` call is found under the project's `scenarios/` folder (not in `_disabled/`, comments or strings). Otherwise a lock call fails at once with a reason; calls that exist only in another target or package added in `Package.swift` fail too.
- In MCP, calls of the same project on one MCP server exclude each other.
- Not accepted by `ft_batch`.

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

In this example every machine writes the same shop name from `beforeAll()`, so the duplicate write is harmless. A value that differs per machine needs `@RunOnSingleMachine` on the class, or `beforeRun()`.

## Notes

- Write a key that a run-wide lock guards only inside the lock (see [Run-wide locks](#run-wide-locks-withrunlock)).
- A scenario that is run again (requeued or retried) runs the lock block again (a counter is added twice).
- Run-wide locks do not work in `--fleet`; use the test server's database for heavy or run-spanning exclusion.

### Link
- [index](../../index.md)
