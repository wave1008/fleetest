# Creating a test class

[in Japanese(日本語)](creating_testclass_ja.md)

A test scenario is a Swift file that describes a `@TestClass` with one or more `@Test`
methods. This page covers where to put the file and the minimal shape it needs.

## Where the file goes

Place `.swift` files under `TestProjects/<project>/scenarios/` (any subfolder is fine,
e.g. `scenarios/Login/`). Running `swift build` (or any `fleetest run`) auto-discovers new
files — there is no registration step.

## Minimal example

```swift
import FTDSL

@TestClass                                      // target app is resolved from the run profile
class LoginTest {

    @Test("Can log in with a valid email and password")
    func S0010() {
        scenario {
            scene(1, "Log in") {
                condition {
                    launchApp()
                }.action {
                    type("#email", "test@example.com")
                    type("#password", account("[user1].password"))
                    tap("#login_btn||Log In")
                }.expectation {
                    exist("#welcome_text||Welcome")
                }
            }
        }
    }
}
```

Account values live in `dataset/accounts.json` — see [Test data and accounts](../commands/dataset.md).

- `import FTDSL` is required.
- `@TestClass` marks the class. **`@TestClass` takes no `app:`** — the target app is resolved
  from the run profile (app profile → running platform's `ios.app`/`android.app`), which is
  what lets the same scenario run against different bundle IDs on iOS and Android (without a profile, pass `--app-id`). Add
  `@TestClass(platform: "ios")` (or `"android"`) only when the class only makes sense on one
  OS; a run that doesn't cover that OS records it as skipped, not failed.
- `@Test("description")` marks a test method. **Method names follow `S0010`, `S0020`, …**
  (increments of 10, so a step can be inserted later without renaming everything). The
  scenario ID used everywhere (reports, `--scenario`, CI) is `ClassName.MethodName`.
- The body is `scenario { scene(n, "title") { condition { }.action { }.expectation { } } }`
  — see [Test code structure](./testcode_structure.md) for what each block means and how
  chaining works.
- Commands (`tap`, `type`, `exist`, …) are **synchronous, non-throwing free functions**. No
  `try`/`await` and no closure argument (`{ it in }`) are needed — they implicitly act on the
  current execution context.

## beforeEach / afterEach

```swift
@TestClass
class LoginTest {
    func beforeEach() {
        irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
    }
    func afterEach() {
        // cleanup that must always run
    }

    @Test("...")
    func S0010() { scenario { /* ... */ } }
}
```

`beforeEach()` and `afterEach()` run automatically around every `@Test` in the class.
**`afterEach()` still runs even after a failure** — it is the place to put cleanup that must
not be skipped when a scenario is aborted mid-way.

`func beforeAll()` (optional) runs **once per run, per class** (in a run that spans machines, once per machine), before any scenario of that class on
any device — for per-class preparation (for example creating the test data of that class; values it
writes with `writeRunMemo` are shared, see [memo](../commands/memo.md)). In a run that spans machines, another machine's `beforeAll()` can overwrite a value this one wrote, so pass a value made by the app or by one machine from `beforeAll()` only in a class with `@RunOnSingleMachine`. Preparation that must happen once for the whole run goes in
[`beforeRun()`](#run-wide-preparation-and-cleanup-runhooks--beforerun--afterrun). Other devices that
pick up a scenario of that class wait until it finishes. If it fails, the remaining scenarios of
that class in the run are recorded as failed without running.

`func afterAll()` (optional) runs **once per run, per class** (in a run that spans machines, once per machine), after every device has finished the
run, in a process of its own — for run-wide cleanup such as deleting the test data `beforeAll()`
created. It runs whether or not `beforeAll()` passed and can read the run memo. It does not run in an
interrupted run.

`func setUpDevice()` (optional) runs **at most once per run, per device, per class**, before
`beforeEach()` of the first scenario of that class that lands on the device — for preparation that
should not repeat for every test but is needed on each device (for example switching the app's language). Each scenario is
its own process, so instance properties set there are visible only to that first scenario; `setUpDevice()` cannot write the run memo (it can only read it); pass values by writing them with `writeRunMemo` in `beforeAll()` of a class with `@RunOnSingleMachine`, or in `beforeRun()` for a run-wide value (see [memo](../commands/memo.md)).

`func tearDownDevice()` (optional) runs **once, after the device has finished all of its scenarios
in the run**, if at least one scenario of that class ran on the device — for cleaning up what
`setUpDevice()` prepared (it runs even if `setUpDevice()` failed). It does not run on a device that
dropped out mid-run or when the run is interrupted. Its result is written to the execution log and a
report, but it does not count toward the test results.

## Run-wide preparation and cleanup (@RunHooks / beforeRun / afterRun)

`beforeAll()` runs once per class (once per machine in a run that spans machines). When you need something done **once for the whole run**, before any
scenario of any machine and after all of them (for example resetting a server that every machine shares, or writing a value that every test reads), put it in a class marked `@RunHooks`.

```swift
import FTDSL   // required: without it, a class in a separate file fails with `unknown attribute 'RunHooks'`

@RunHooks
class RunWide {
    func beforeRun() {
        let response = httpRequest("https://test-server.example.com/login")
        response.status.thisIs(200)
        writeRunMemo("token", response.text)
    }

    func afterRun() {
        // reads the final run memo; it cannot write it
        let response = httpRequest("https://test-server.example.com/cleanup?token=\(readRunMemo("token"))")
        response.status.thisIs(200)
    }
}
```

- You can write `beforeRun()`, `afterRun()` or both (a phase you do not write does nothing). They take no arguments and must be neither `async` nor `throws` (`func beforeRun()`; anything else is a compile error). A project can have **one** `@RunHooks` class (two or more is an error before the run starts, dry-run included), and it cannot also be a `@TestClass`.
- **Where and how often**: once per run per project, on the machine where you started fleetest (for `run --runner <machine>`, the runner machine). A run that spans several machines still runs them once.
  The run prints one line saying which machine ran it. `beforeRun()` finishes before any scenario starts on any machine.
  **They do not run** in a debug run, in a run without a profile, or in a dry-run (a dry-run does run `beforeAll()`, but not `beforeRun()` / `afterRun()`). They run in `fleetest run --profile ...`, `fleetest api run --profile ...` and every call of MCP `ft_run_scenario`.
  Each of them runs in a process of its own, so **a value cannot be passed from `beforeRun()` to `afterRun()` through a `var` of the class** — use the run memo.
  When `beforeRun()` does not run, `readRunMemo` of the keys it would have written returns `""` (not a failure), so check right after reading, for example `readRunMemo("token").thisIsNotEmpty()`. **A dry-run does not run `beforeRun()`, so this guard does not work in a dry-run either (it shows ✅) and value assertions are not compared. Check anything that depends on the run memo in a run.**
- **What you can use**: the run memo (`writeRunMemo` / `readRunMemo`; values written in `beforeRun()` are visible to every test from its first line), `httpRequest`, `data()` / `account()`, `wait`, and value assertions (`thisIs` etc.).
  `httpRequest` is refused unless the host is in `allowedDomains` of the machine that ran the hook ([Sandbox](../../security/sandbox.md); check `response.status` as in the example).
  **Commands that operate a device fail** (the message names the command), and **the servers of compose.yaml are not reachable** (they are per machine).
  Allowed domains (`allowedDomains`) and the per-machine override of the dataset are those of **the machine that ran it** and can differ from the machines that run the tests.
- **A failing `beforeRun()` stops the run**: no scenario runs, the run ends with exit code 1 and the reason in the run's result, and it is not recorded as a failed test. With `--target` over several projects, only the scenarios of that project stop; the other projects continue, the exit code is 1, and the JUnit report gets a failed `beforeRun` testcase for each failing project.
- **Time limit**: `beforeRun()` and `afterRun()` are cut off at the run profile's `scenarioTimeout` (the longest among the profiles; `@Test(scenarioTimeout:)` does not count) and then count as failed.
- **`afterRun()` runs when it can**: after every machine has finished its work (including each `afterAll()`), even if `beforeRun()` failed or tests failed (a red run) — so it can clean up what a half-done `beforeRun()` created. It is skipped **only** in
  an interrupted run or when a machine's run ended abnormally (the run prints "afterRun did not run: ..."). Its result is written to the log and a report but is not counted in the test results.
  Do not make cleanup a precondition of a pass.
- **To record a value the run used**, call `readRunMemo("key")` in `afterRun()`. The value it reads is written as a step line (`readRunMemo "key" → "value"`)
  in the run log and the report. You do not need a value assertion (such as `thisIsNotEmpty`) just to leave the record.
- **A run with no scenarios, and a `--fleet` run, are not supported**: nothing runs when no scenario runs, and `--fleet` is refused at the start when the project has `@RunHooks`.
- **MCP**: `ft_run_scenario` is a run too, so `beforeRun()` and `afterRun()` run once per call (a value written in `beforeRun()` is new on every call). The run memo of a call starts empty or with what that call's `beforeRun()` wrote, and is shared by the scenarios of that call. Calls running at the same time on one MCP server have separate run memos, but [run-wide locks](../commands/memo.md) are shared within a project, and `beforeRun()` / `afterRun()` are not protected by locks (they can clean up state another call is using inside an exclusive lock).
- **A `beforeRun()` that resets a shared server can break another run that is using the same server at the same time** (another terminal, the extension, MCP). A run in progress elsewhere is not protected.
- **Order with `run-setup.sh` / `run-teardown.sh`**: in a run on one machine, `run-setup.sh` finishes first, then `beforeRun()` runs just before the first scenario; `afterRun()` runs after the tests and `afterAll()`, then `run-teardown.sh` runs.
  In a run that spans machines, `beforeRun()` runs while the other machines are still preparing, so the order against their `run-setup.sh` is not fixed; `afterRun()` runs after every machine's `run-teardown.sh` has finished.

Which one to use:

| | `beforeRun()` / `afterRun()` | `beforeAll()` / `afterAll()` | `setUpDevice()` / `tearDownDevice()` | `run-setup.sh` / `run-teardown.sh` |
|---|---|---|---|---|
| How often | once per run per project | once per run per class (per machine in a multi-machine run) | once per run per device per class | once per machine |
| Runs on | the machine where you started fleetest (the runner machine for `run --runner`) | each machine that runs a scenario of the class | the device | each machine |
| Device commands | no | yes | yes | no (a script) |
| compose.yaml servers | no | yes | yes | before / after they start (see [services](../writing/services.md)) |
| Use it for | a server shared by every machine; values for the run memo | per-class preparation that needs the app or this machine's servers | per-device preparation (language, permissions) | per-machine preparation |

## Running a class in one place or in order (@RunOnSingleMachine / @RunOnSingleDevice / @RunInOrder)

By default the tests of a class are spread over the devices of the run (which may span several machines), run in parallel, in no
particular order. If the tests are independent, that is the fastest and you add nothing. **Only when you really need it**, put exactly one
of the following on the class (on a line of its own, apart from `@TestClass`). The reason string (for example `@RunInOrder("the order flow")`)
can be left out in all three.

```swift
@RunInOrder("the order flow")
@TestClass
class OrderFlow {
    @Test("add to the cart")
    @Order(10)
    func S0010() { scenario { /* ... */ } }

    @Test("place the order")
    @Order(20)
    func S0020() { scenario { /* ... */ } }

    @Test("it shows in the order history")
    @Order(30)
    func S0030() { scenario { /* ... */ } }
}
```

| | `@RunOnSingleMachine` | `@RunOnSingleDevice` | `@RunInOrder` |
|---|---|---|---|
| Runs on | one machine | one device | one device |
| Inside the class | parallel (over that machine's devices) | one at a time, no other class in between | one at a time, no other class in between |
| Order | not defined | not defined (tests cannot rely on each other) | the `@Order` order (guaranteed) |
| After a failure | continues | continues | the rest is not run and is recorded as failed |
| `--failed` | only what failed | only what failed | from the first test of the class |

- **`@RunOnSingleMachine`** keeps every test of the class on one machine. A test on another machine cannot see the data `beforeAll()` created
  or the data of the compose.yaml server of this machine, so use it for a class whose tests must see the same ones (for example
  tests that all read the data `beforeAll()` created in the compose.yaml server). The load can no longer be split between machines.
  If a run uses only one machine, it has no effect.
- **`@RunOnSingleDevice`** runs the tests of the class one at a time on one device. The class loses its parallelism, so use it only for tests
  that collide when they run at the same time. **First ask whether separate accounts can keep them apart; add it only when they cannot**
  (for example tests that switch a setting of the whole server, something shared that accounts cannot split). The order is not defined (the tests
  must not rely on each other's results). It prevents only simultaneous runs **inside that class**: if another class uses the same account,
  they still collide (use a separate account per scenario).
- **`@RunInOrder`** runs the tests on one device in `@Order` order. It hinders parallelism, the rest of the class is not run once a test
  fails, and a retest starts from the first test of the class. Use it only when needed — **first ask whether the flow can be folded into a
  single `@Test`**. The tests of the class run on one device in turn, so unless a later test calls `launchApp()` / `clearAppData()`, the app screen the earlier test left behind carries over into it as it is.

The flow in this example is normally folded into one `@Test`. Split it only when it is too long and you want to see a failure in the middle separately.

`@Order(n)` goes on a `@Test` method. In a `@RunInOrder` class it is **required on every `@Test`**, with an integer written directly (gaps such as
10, 20, 30 are fine; constant names and expressions are not accepted); a value cannot repeat within a class. Using it in a class without `@RunInOrder` is a compile error.

You cannot write which machine or device the class is kept on: it is kept where the first test of the class was handed out. In a run that
is divided over several machines, one line in the execution log says where. If the device of a device-bound class (`@RunOnSingleDevice` / `@RunInOrder`) drops out, fleetest waits for it to come
back and reruns the interrupted test; if it cannot come back, the remaining tests are recorded as failed instead of moving to another device.

**What is an error**

- Two or more of the three attributes on one class, or one on a class without `@TestClass` or on a `@Test` method (compile error).
- `@Order` in a class without `@RunInOrder`, a `@Test` without `@Order` in a `@RunInOrder` class, a repeated `@Order` value, or a constant name or expression instead of an integer in `@Order` (compile error).
  `@Order` on a method without `@Test`, or on something that is not a method, is a compile error too. A `@Draft` / `@Deleted` test also needs
  `@Order`; it is left out of the run, and "from the first test" is counted over the sequence without it.
- In a `@RunOnSingleDevice` / `@RunInOrder` class, tests whose OS declarations (`@TestClass(platform:)` / `@Test(platform:)`) are not uniform
  (all undeclared, or all the same OS; compile error). `@Test(platform: nil)` is treated the same as not writing it.
- Selecting a `@RunInOrder` class in any form other than the whole class or a range from its first test (for example running one test from the
  middle with `--scenario`, or a debug run from the extension's tree). The run is refused at start. To check a middle test, run the whole class (with MCP `ft_run_scenario`, pass the class name alone as the id: its tests run in `@Order` order, and the app state carries over between them unless a test calls `launchApp()` / `clearAppData()`); mark the
  later tests you are still writing with `@Draft`.
- A `@RunInOrder` class in a [response-measurement](../running/response_measurement.md) run (refused at start).
- A `@RunOnSingleMachine` class with tests for both OSes when no machine has devices of both OSes (refused at start; split the class by OS
  with `@TestClass(platform:)`, or give one machine devices of both OSes).

With `--broadcast`, and in a run that runs the same thing on several machines (`--fleet` without `--split`; see [Remote runs](../../fleet/remote_runners.md)), the attribute has no effect (the class runs on several
devices or machines). `--broadcast` prints one line saying so; `--fleet` does not. See [Where to put test data](../writing/test_data_placement.md) and [Memo](../commands/memo.md) (the run memo is shared across machines, except in `--fleet` without `--split`).

## Marking work in progress or retired tests

- `@Draft("reason")` marks a test as not yet finished. It stays visible in listings as
  "in progress" but is excluded from full runs, folder runs, and class-name runs; it can
  still be run by its exact ID.
- `@Deleted("reason")` marks a test as retired the same way (excluded from bulk runs, still
  runnable by exact ID). The code stays in the file, so un-deleting is just removing the
  annotation.

Both can be attached to the class or to an individual `@Test` method.

## Notes

- `@RunOnSingleMachine` stops the load from being split between machines. Use it only to gather `beforeAll()` or data on one machine; you cannot write which machine (it is the one that received the first test).
- `@RunOnSingleDevice` removes the class's parallelism and defines no order. It prevents only simultaneous runs inside that class; another class using the same account still collides.
- `@RunInOrder` hinders parallelism, the rest of the class is not run after a failure, and a retest starts from the class's first test. First ask whether the flow fits in one `@Test`; `@Order` is required on every test (integer, no repeats), and only the whole class or a range from the first test can be selected. The app screen state carries over between its tests unless a later test calls `launchApp()` / `clearAppData()`.
- `beforeRun()` / `afterRun()` do not run in a debug run, a run without a profile or a dry-run, and cannot pass a value to each other through a class `var` (separate processes); use the run memo.
- `beforeRun()` cannot use the device or the servers of compose.yaml, and the allowed domains and dataset overrides are those of the machine it ran on; per-machine preparation goes in `run-setup.sh` / `beforeAll()`.
- `afterRun()` also runs after failed tests; it is skipped only in an interrupted run or after an abnormal end, and it is not counted in the results; do not make it a precondition of a pass. A `--fleet` run with `@RunHooks` is refused.
- A `beforeRun()` that resets a shared server can break another run using the same server at the same time (MCP runs `beforeRun()` on every `ft_run_scenario` call); make it safe to run while other runs are in progress.

### Link
- [index](../../index.md)
