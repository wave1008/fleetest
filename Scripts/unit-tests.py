#!/usr/bin/env python3
# 単体テストの全体を、テストクラスごとに1プロセスで並列に回す(`swift test --parallel` の代わり。常に全体なので
# test-scope-guard.py が FT_FULL_TEST=1 を求める。絞った実行は従来どおり `swift test --filter <Class>`)。
# なぜ: `swift test --parallel` はテストケース1件ごとに xctest を起動する。起動だけで 1 回 0.10〜0.14 秒(空回しの実測)×
#   12,585 件で、中身の大半が起動だった(全体 313 秒 → この形で約 120 秒。2026-11-06)。逆にバンドルを1プロセスにすると
#   待つテストが1列に詰まって 1,150 秒。中間のクラス単位が最短。
# 契約:
#   - 前回の所要時間(.fleetest/unit-test-durations.json。テストケースごと・xctest の自己申告)で、理想の所要
#     (全体の和 ÷ 並列数)を1本で超えるクラスだけ1件ごとに分け、長いものから投入する(LPT)。記録が無ければ全部クラス単位
#   - 同じプロセスの中で前のテストの状態が残る(1件1プロセスでは見えなかった)。クラス単位で落ちるテストは
#     テスト側で状態を捨てて直す(例: CheckStateClassifierTests の invokeTest)
#   - 一覧(swiftpm-xctest-helper)にあって終わった行が出ないテストは失敗に数える(プロセスが途中で落ちた等を黙って緑にしない)
#   - Swift Testing(`import Testing`)は xctest では回らないので、Tests に現れたら断る
#   - 毎回の所要・合否は .fleetest/unit-test-history.ndjson に1行ずつ追記する(ビルドの失敗も1行)
# 使い方: FT_FULL_TEST=1 Scripts/unit-tests.py [--jobs N] [--skip-build]
import argparse, concurrent.futures as cf, glob, json, os, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DURATIONS = os.path.join(ROOT, ".fleetest", "unit-test-durations.json")
LOG_DIR = os.path.join(ROOT, ".fleetest", "unit-tests")
# 毎回の所要を1行ずつ追記する(LOG_DIR は毎回消すので外に置く)。欄は append_history の dict
HISTORY = os.path.join(ROOT, ".fleetest", "unit-test-history.ndjson")
CASE_END = re.compile(r"^Test Case '-\[(\w+)\.(\w+) (\w+)\]' (passed|failed|skipped) \(([0-9.]+) seconds\)", re.M)


def run(cmd, **kw):
    return subprocess.run(cmd, cwd=ROOT, **kw)


def toolchain_path(relative):
    swift = run(["xcrun", "-f", "swift"], capture_output=True, text=True, check=True).stdout.strip()
    return os.path.normpath(os.path.join(os.path.dirname(swift), relative))


def list_bundle(helper, bundle, out_dir):
    """{"Mod.Class": [testName, ...]}"""
    out = os.path.join(out_dir, os.path.basename(bundle) + ".list.json")
    r = run([helper, bundle, out], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"listing failed for {bundle}:\n{r.stderr}")
    found = {}

    # 入れ子は All Tests > <bundle>.xctest > <Mod.Class> > test。クラスは「子が葉(tests を持たない)」の節
    def walk(node):
        children = node.get("tests", [])
        if children and all("tests" not in c for c in children):
            found[node["name"]] = [c["name"] for c in children]
        else:
            for c in children:
                walk(c)
    walk(json.load(open(out)))
    return found


def append_history(record):
    record = {"startedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"), **record}
    head = run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
    dirty = run(["git", "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True)
    if head.returncode == 0:
        record["head"] = head.stdout.strip()
    if dirty.returncode == 0:
        record["dirty"] = bool(dirty.stdout.strip())
    os.makedirs(os.path.dirname(HISTORY), exist_ok=True)
    with open(HISTORY, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def build_jobs(classes, bundles_of, durations, workers):
    """[(見込み秒, bundle, xctest の -XCTest 引数, 期待するケース名の集合)] を長い順に。
    分ける閾値は理想の所要(記録の和 ÷ 並列数): それを1本で超えるクラスは、それだけで全体を理想より長くする"""
    # クラスの見込みは「そのクラスを1プロセスで回したときの実時間」(鍵 = クラス名)を優先する。各テストの自己申告の和は
    # プロセスの外の時間(子プロセスの後片付け等)を含まず、負荷の下で大きく下回る
    # (IOSSimulatorVideoRecorderStartTests: 和 < 閾値なのに実時間 95 秒で、分けられないまま全体を決めていた)
    def class_estimate(k, tests):
        times = [durations.get(f"{k}/{t}") for t in tests]
        summed = sum(times) if all(x is not None for x in times) else None
        wall = durations.get(k)
        if summed is None:
            return wall, times
        return max(summed, wall or 0), times

    estimates = {k: class_estimate(k, ts) for k, ts in classes.items()}
    known = [e for e, _ in estimates.values() if e is not None]
    ideal = sum(known) / workers if known else None
    jobs = []
    for k, tests in classes.items():
        bundle = bundles_of[k]
        total, times = estimates[k]
        if ideal is not None and total is not None and total > ideal and len(tests) > 1 \
                and all(x is not None for x in times):
            jobs += [(d, bundle, f"{k}/{t}", {f"{k}/{t}"}) for d, t in zip(times, tests)]
        else:
            # 記録の無いクラスは件数を見込みの代わりにする(新しいクラスを後回しにしない程度の順序付け)
            jobs.append((total if total is not None else len(tests) * 0.5, bundle, k, {f"{k}/{t}" for t in tests}))
    jobs.sort(key=lambda j: j[0], reverse=True)
    return jobs, ideal


def main():
    ap = argparse.ArgumentParser()
    # 既定はコア数 - 2(ユーザー決定 2026-11-06)。全コアを埋めると時間の予算を持つテストが間に合わず赤になる
    # (FMServeAlignmentTests の 50 ms)・同じ機械のモニターや Simulator も遅くする
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 1) - 2))
    ap.add_argument("--skip-build", action="store_true")
    args = ap.parse_args()

    swift_testing = [p for p in glob.glob(os.path.join(ROOT, "Tests", "**", "*.swift"), recursive=True)
                     if re.search(r"^\s*(@testable\s+)?import\s+Testing\b", open(p, encoding="utf-8", errors="replace").read(), re.M)]
    if swift_testing:
        sys.exit("Swift Testing (import Testing) is not run by this runner: " + ", ".join(
            os.path.relpath(p, ROOT) for p in swift_testing[:5]))

    t0 = time.time()
    started = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    if not args.skip_build:
        if run(["swift", "build", "--build-tests"]).returncode != 0:
            append_history({"startedAt": started, "jobs": args.jobs, "result": "build-failed",
                            "buildSeconds": round(time.time() - t0, 1)})
            sys.exit("build failed")
    t_build = time.time() - t0

    debug = os.path.realpath(os.path.join(ROOT, ".build", "debug"))
    bundles = sorted(glob.glob(os.path.join(debug, "*.xctest")))
    if not bundles:
        sys.exit(f"no test bundles in {debug}")
    os.makedirs(LOG_DIR, exist_ok=True)
    for old in glob.glob(os.path.join(LOG_DIR, "*")):
        os.remove(old)
    helper = toolchain_path("../libexec/swift/pm/swiftpm-xctest-helper")
    xctest = run(["xcrun", "-f", "xctest"], capture_output=True, text=True, check=True).stdout.strip()

    classes, bundles_of = {}, {}
    for b in bundles:
        for k, tests in list_bundle(helper, b, LOG_DIR).items():
            classes[k] = tests
            bundles_of[k] = b
    try:
        durations = json.load(open(DURATIONS))
    except (OSError, ValueError):
        durations = {}
    jobs, ideal = build_jobs(classes, bundles_of, durations, args.jobs)
    expected_total = sum(len(t) for t in classes.values())
    print(f"{expected_total} tests in {len(classes)} classes from {len(bundles)} bundles -> {len(jobs)} processes"
          f" on {args.jobs} workers" + (f" (classes over {ideal:.1f}s run one test per process)" if ideal else
                                        " (no recorded durations: one process per class)"), flush=True)

    def execute(job):
        _, bundle, selector, expected = job
        started = time.time()
        r = subprocess.run([xctest, "-XCTest", selector, bundle], cwd=ROOT, capture_output=True, text=True)
        return job, r.returncode, time.time() - started, r.stdout + r.stderr

    t1 = time.time()
    new_durations, failed, missing, crashed, slow = {}, [], [], [], []
    executed = set()
    done = 0
    with cf.ThreadPoolExecutor(args.jobs) as pool:
        for future in cf.as_completed([pool.submit(execute, j) for j in jobs]):
            job, rc, wall, out = future.result()
            _, bundle, selector, expected = job
            done += 1
            seen = set()
            bad = []
            for mod, cls, name, status, secs in CASE_END.findall(out):
                key = f"{mod}.{cls}/{name}"
                seen.add(key)
                new_durations[key] = float(secs)
                executed.add(key)
                if status == "failed":
                    bad.append(key)
            lost = sorted(expected - seen)
            slow.append((wall, selector))
            if "/" not in selector:
                new_durations[selector] = wall  # クラス丸ごとの実時間(build_jobs の見込み)
            if bad or lost or rc != 0:
                log = os.path.join(LOG_DIR, selector.replace("/", "__") + ".log")
                open(log, "w").write(out)
                failed += bad
                missing += lost
                if rc != 0 and not bad and not lost:
                    crashed.append(selector)
                errors = [l for l in out.splitlines() if " error: " in l][:5]
                print(f"FAIL {selector} (exit {rc}) log: {os.path.relpath(log, ROOT)}", flush=True)
                for l in errors:
                    print("  " + l[:400], flush=True)
                for l in lost[:5]:
                    print(f"  did not finish: {l}", flush=True)
            if done % 200 == 0:
                print(f"  {done}/{len(jobs)} processes, {time.time() - t1:.0f}s", flush=True)

    # 記録は上書きでなく併合する(消えたテストの行は残っても害が無い = 見込みに使われない)
    durations.update(new_durations)
    os.makedirs(os.path.dirname(DURATIONS), exist_ok=True)
    tmp = DURATIONS + ".tmp"
    json.dump(durations, open(tmp, "w"), sort_keys=True)
    os.replace(tmp, DURATIONS)

    slow.sort(reverse=True)
    print("slowest processes: " + ", ".join(f"{s} {w:.1f}s" for w, s in slow[:5]))
    print(f"executed {len(executed)}/{expected_total} tests, {len(failed)} failed, {len(missing)} did not finish,"
          f" {len(crashed)} processes exited non-zero without a failed test;"
          f" build {t_build:.1f}s, tests {time.time() - t1:.1f}s, total {time.time() - t0:.1f}s")
    ok = not failed and not missing and not crashed and len(executed) == expected_total
    append_history({"startedAt": started, "jobs": args.jobs, "skipBuild": args.skip_build,
                    "result": "passed" if ok else "failed",
                    "buildSeconds": None if args.skip_build else round(t_build, 1),
                    "testSeconds": round(time.time() - t1, 1), "totalSeconds": round(time.time() - t0, 1),
                    "tests": expected_total, "executed": len(executed), "processes": len(jobs),
                    "failed": len(failed), "didNotFinish": len(missing), "crashedProcesses": len(crashed),
                    "slowest": [[s, round(w, 1)] for w, s in slow[:5]]})
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
