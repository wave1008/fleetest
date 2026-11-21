# Run-wide lock (withRunLock)

[in Japanese(日本語)](run_lock_ja.md)

Use it to occupy a resource that exists only once across device operations. Wrap the work that needs the resource in one lock, and the other scenarios wait until it ends.

<img src="../../images/run_lock/en/run_lock_sequence.png" width="720" alt="Sequence diagram. The machine that started the run has Device 1, Device 2 and the lock server; the remote machine has Device 3. Three scenarios call withRunLock with the same key resource1. Device 1 requests the lock; it is free, so the server grants it at once and Device 1 runs its block. Device 2 then requests it; Device 1 holds it, so the server puts Device 2 in the queue and Device 2 waits. Device 3 requests it from the same server over ssh and waits behind Device 2 in the queue. When Device 1 leaves the block and returns it, the server grants the lock to the head of the queue, Device 2, and when Device 2 returns it, to Device 3. Time spent waiting is not counted in scenarioTimeout">

Locks are told apart by the name you pass (the key). Only scenarios that pass the same key exclude each other; with different keys they run at the same time. Only scenarios within one run exclude each other (a run profile that lists devices on several machines is still one run). Another run going on at the same time (someone else's run or a CI run) is not excluded, so protect a resource across runs with the test server's database or the like. Waiting scenarios take it in the order they requested it (first come, first served). The lock server runs on the machine that started the run, and scenarios on remote machines request it from the same server over ssh. Time spent waiting is not counted in `scenarioTimeout`.

## Functions

| Function | Description |
|---|---|
| `withRunLock(keys..., waitSeconds:) { }` | Runs the block while no other scenario of the run holds any of the keys. It waits until it can take them: at most the run's longest `scenarioTimeout`, which `waitSeconds:` can shorten (if it cannot take them, the step fails). |

## Example

```swift
withRunLock("resource-name") {
    // work that needs the lock
}
```

To read a value from the screen **once per run** and share it across all machines and classes (`beforeRun()` cannot use the device), read it under a lock at the top of each test, so only the first test to get there reads it:

```swift
withRunLock("shop") {
    if readRunMemo("shop").isEmpty { select("#shop_name").runMemoTextAs("shop") }
}
```

Inside the lock `readRunMemo` returns the latest value, so every later test finds it filled and skips the read.

When you need several resources at once, pass the keys in one call. The keys are taken in a fixed order, so two scenarios that take the same keys cannot deadlock.

```swift
withRunLock("resource-a", "resource-b") {
    // work that uses both resources
}
```

`withRunLock` can be written in any of condition, action and expectation. To keep an assertion inside the exclusive section, put the lock where the assertion is (for example in expectation), wrapping both the operation and the check. It returns nothing: to take a value out, assign it to a local `var` inside the block, or read it with `readRunMemo`. Outside the lock `readRunMemo` returns the run memo as it was when the scenario started (except the scenario's own writes); inside it returns the latest value (see [Memo](memo.md#scope)).

## Notes

- You cannot call a lock inside the block of a lock (nest it).
- If the tests do not need to run at the same time and you want to avoid the complexity of locks, consider running the tests one after another with `@RunInOrder`.

### Link
- [index](../../index.md)
