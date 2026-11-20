# Where to put test data

[日本語](test_data_placement_ja.md)

Even on one machine, if it has several devices, the tests run in parallel on those devices and in no fixed order.

When a run uses several machines, `beforeAll()` and the [servers of compose.yaml](services.md) are
also split **once per machine** (a setup in which every machine connects to one shared server is also possible; then all machines
touch the same database at the same time). The [run memo](../commands/memo.md) is one per run, shared across machines (except in a `--fleet` run without `--split`). Write the scenarios by these three rules so that they pass in either setup.

## Rules

1. **A test does not rely on data another test created.** Prepare the data it changes in its own `beforeEach()` or `condition`,
   with an account of its own and data created under unique names, so that it only touches what it made itself
   (the exception is a [`@RunInOrder`](../testclass/creating_testclass.md#running-a-class-in-one-place-or-in-order-runonsinglemachine--runonsingledevice--runinorder) class, which can pass values along in order).
2. **Per-machine preparation (`run-setup.sh` and `beforeAll()`) must be safe to run repeatedly and at the same time.**
   "Create it if it is missing" is fine; "delete everything and load it again" is not. If a shared server has to be reset as
   a whole, do that once per run in the `beforeRun()` of an [`@RunHooks`](../testclass/creating_testclass.md#run-wide-preparation-and-cleanup-runhooks--beforerun--afterrun) class (or before the run, outside fleetest, for example in an earlier CI step) —
   but a reset in `beforeRun()` breaks another run that is using the same server at the same time.
3. **Do not make cleanup (`afterEach()`, `afterAll()`, `run-teardown.sh`) a precondition of a pass.** Delete only what you
   created, and make sure the data left behind does not affect the result when cleanup did not run.

When tests really must share one value (a counter), use the [run-wide locks](../commands/memo.md#run-wide-locks-withexclusivelock-withsharedlock) for light cases and the test server's database for heavy or run-spanning exclusion.

Named volumes remain between runs, so a test prepares its own range on the assumption that data from an earlier run is still there.

## Examples

An `accounts.json` with a separate key per test (the format is in [Test data and accounts](../commands/dataset.md)):

```json
{
  "[order_S0010]": { "id": "order-s0010@example.com", "password": "..." },
  "[order_S0020]": { "id": "order-s0020@example.com", "password": "..." }
}
```

```swift
type("#login_id", account("[order_S0010].id"))
```

A unique name for the data a test creates:

```swift
let itemName = "order-" + UUID().uuidString.prefix(8)
```

To prepare the data, see [Test data and accounts](../commands/dataset.md) and [http_request](../commands/http_request.md).

With `--broadcast`, and with `--fleet` without `--split`, the same test runs on several devices at the same time, so even an account of its own per test collides.

## When you need an order or one group

If a flow needs an order, first fold it into a single `@Test`. Only when that is impossible, put
[`@RunInOrder`](../testclass/creating_testclass.md#running-a-class-in-one-place-or-in-order-runonsinglemachine--runonsingledevice--runinorder) (run in order), `@RunOnSingleDevice` (never at the same time) or `@RunOnSingleMachine` (keep on one machine) on the class.

## Notes

- A test prepares the data it changes itself, with an account of its own and unique names; only a `@RunInOrder` class can pass values in order.
- Write `run-setup.sh` and `beforeAll()` so they are safe to repeat and to run at the same time ("delete everything and reload" erases the data of other machines on a shared server). Work that must happen once for the whole run goes in `beforeRun()`.
- Do not make cleanup a precondition of a pass: delete only what you created.

### Link
- [index](../../index.md)
