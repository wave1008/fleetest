#!/usr/bin/env python3
# 低頻度の台帳項目(docs/open-issues.md「低頻度」)の再現シナリオを回し続けて、赤の出た回の材料を貯める(docs/verification/operations.md「低頻度の項目の反復」)。
# 対象の表は Scripts/soak-targets.json(OI の ID → project / profile / scenario / watch)。
# 1周 = 各対象を `fleetest run --project … --profile … --scenario …` で1回。終了コードを見て、run の結果 JSON
# (TestProjects/<project>/results/runs/、docs/results-json.md)から失敗ステップの事実を拾い、<out>/ledger.ndjson へ1行ずつ足す。
# 周ごとに <out>/summary.md を書き直す(対象ごとの回数・赤の署名ごとの件数・台帳の watch)。ツールは赤の原因を言わない —— 事実だけ貯める。
#
# 使い方:
#   Scripts/soak.py --dry-run                                  # 全対象の撃つコマンドだけ出す(デバイスを使わない)
#   Scripts/soak.py --check                                    # 対象表の project / profile / シナリオの実在だけ確かめる
#   Scripts/soak.py --targets OI-315,OI-325 --rounds 20        # 手元の Mac で 20 周
#   Scripts/soak.py --runner M1Max --hours 8                   # ランナー機へディスパッチして 8 時間(開始前に align.sh <機> を1回)
# 長時間は成果物で待つ(CLAUDE.md「長時間ジョブ」。プロセスの生死で待たない):
#   out=~/github/wave1008/_work/soak-$(date +%Y%m%d-%H%M%S); mkdir -p $out
#   nohup bash -c "Scripts/soak.py --runner M1Max --hours 8 --out $out > $out/log 2>&1; echo exit=\$? > $out/log.done" &
#   起動を報告する前に $out/log の実在を確かめる。終わると $out/done(reason と終了コード)が書かれる。
# 前提: SUT のアプリは各 SUT の scripts/build-ios.sh / build-android.sh で手元と対象の機械の両方にビルド済み・
#   リモートはアライン済み(このスクリプトも開始前に1回撃つ。失敗したら止める = 手元だけで続けない)。
# 中断: SIGINT / SIGTERM は走っている fleetest run へ SIGINT を1回だけ伝え、周を終えずに summary を書いて終わる(130)。
#   子は別のプロセスグループで起こす。`nohup … &` は bash が SIGINT を無視に設定して Python へ継がせるので自前で受ける(regress.py と同じ)。
# 終了コード: 0 = 回し切った(赤があっても 0。赤は ledger と summary の中身)/ 1 = 準備の失敗 / 2 = 引数 / 130 = 中断。
import argparse, glob, json, os, re, shlex, signal, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGETS_FILE = os.path.join(ROOT, "Scripts", "soak-targets.json")
FLEETEST = os.environ.get("FLEETEST") or os.path.join(ROOT, ".build", "debug", "fleetest")
# 秒。1回の fleetest run の上限。尽きたら SIGINT → KILL_GRACE 秒後に SIGKILL して「timeout」として台帳へ書く
# (根拠: 1シナリオの run は供給込みで通常 1〜5 分。ディスパッチの待機列 --wait-lock の上限は別に持つ)
RUN_TIMEOUT = 2700
# 秒。SIGINT の後に子が後始末(ブリッジの返却・結果の書き出し・リモートのロックの解放)を終えるのを待つ上限。尽きたら SIGKILL
# (根拠: 中断の後始末は通常 10 秒台。リモートの ssh 越しの片付けの遅れを見込んだ余裕)
KILL_GRACE = 60
# 秒。--wait-lock の既定。1マシン1 run の不変条件(DR-97)で他人の run を待つ上限。尽きたら run は断られ「no-record」になる
WAIT_LOCK = 1800
DETAIL_LIMIT = 400   # 文字。失敗ステップの detail を台帳へ写す上限(全文は結果 JSON にある)

_interrupted = False
_child = None


def _on_signal(signum, _frame):
    global _interrupted
    _interrupted = True
    if _child is not None and _child.poll() is None:
        _child.send_signal(signal.SIGINT)


def load_targets(selected):
    with open(TARGETS_FILE, encoding="utf-8") as f:
        table = {k: v for k, v in json.load(f).items() if not k.startswith("_")}
    if selected:
        unknown = [k for k in selected if k not in table]
        if unknown:
            sys.exit(f"❌ soak-targets.json に無い対象: {unknown}(有る対象: {', '.join(table)})")
        table = {k: table[k] for k in selected}
    return table


def scenarios_of(target):
    s = target["scenario"]
    return [s] if isinstance(s, str) else list(s)


def check_target(oid, target):
    """対象の実在(project・profile・クラス・メソッド)を確かめる。問題の一覧を返す"""
    problems = []
    project_dir = os.path.join(ROOT, "TestProjects", target["project"])
    if not os.path.isdir(project_dir):
        return [f"{oid}: プロジェクト TestProjects/{target['project']} が無い"]
    profile = os.path.join(project_dir, "profiles", "runs", target["profile"] + ".json")
    if not os.path.isfile(profile):
        problems.append(f"{oid}: プロファイル {os.path.relpath(profile, ROOT)} が無い")
    files = glob.glob(os.path.join(project_dir, "scenarios", "**", "*.swift"), recursive=True)
    for sid in scenarios_of(target):
        cls, _, method = sid.partition(".")
        pat = re.compile(r"^\s*(?:final\s+)?(?:public\s+)?class\s+" + re.escape(cls) + r"\b", re.M)
        hit = None
        for path in files:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
            if pat.search(text):
                hit = text
                break
        if hit is None:
            problems.append(f"{oid}: クラス「{cls}」が {target['project']} の scenarios/ に無い")
        elif method and not re.search(r"func\s+" + re.escape(method) + r"\s*\(", hit):
            problems.append(f"{oid}: {cls} にメソッド {method} が無い")
    return problems


def run_args(target, opts):
    args = [FLEETEST, "run", "--project", target["project"], "--profile", target["profile"]]
    for sid in scenarios_of(target):
        args += ["--scenario", sid]
    if opts.runner != "local":
        args += ["--runner", opts.runner]
    if opts.broadcast or target.get("broadcast"):
        args.append("--broadcast")
    if opts.skip_build:
        args.append("--skip-build")
    for kv in target.get("set", []):
        args += ["--set", kv]
    # 結果 JSON は常に書かれる。録画は貯めない(容量)。順番待ち: 他の run が終わるまで待つ
    return args + ["--set", "record=false", "--wait-lock", str(opts.wait_lock)]


def run_child(cmd, log_path, timeout):
    """fleetest run を別のプロセスグループで起こして終わりまで待つ。(終了コード, timeout したか)"""
    global _child
    with open(log_path, "w") as log:
        _child = subprocess.Popen(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                  process_group=0)
        try:
            try:
                return _child.wait(timeout=timeout), False
            except subprocess.TimeoutExpired:
                _child.send_signal(signal.SIGINT)
                try:
                    _child.wait(timeout=KILL_GRACE)
                except subprocess.TimeoutExpired:
                    _child.kill()
                    _child.wait()
                return _child.returncode, True
        finally:
            _child = None


def first_lines_tail(path, n=12):
    try:
        with open(path, errors="replace") as f:
            return [l.rstrip() for l in f.readlines()[-n:]]
    except OSError:
        return []


def step_row(step):
    row = {k: step.get(k) for k in ("index", "section", "description", "command", "failureKind", "notes", "at")
           if step.get(k) is not None}
    if step.get("trace"):   # 判定の足跡(新しい欄。無い run は無視)
        row["trace"] = step["trace"]
    if step.get("detail"):
        row["detail"] = step["detail"][:DETAIL_LIMIT]
    return row


def evidence_of(record, scenario_path):
    """失敗時の証跡のパス(リポジトリ相対)。ある物だけ"""
    ev = {"scenarioJson": os.path.relpath(scenario_path, ROOT)}
    events = os.path.join(os.path.dirname(os.path.dirname(scenario_path)), "events",
                          os.path.basename(scenario_path))
    events = events[:-len(".json")] + ".ndjson"
    if os.path.isfile(events):
        ev["events"] = os.path.relpath(events, ROOT)
    report = record.get("reportPath")
    if report:
        ev["report"] = report
        absolute = report if os.path.isabs(report) else os.path.join(ROOT, report)
        stem = absolute[:-3] if absolute.endswith(".md") else absolute
        extra = [os.path.relpath(p, ROOT) for p in sorted(glob.glob(glob_escape(stem) + "*"))
                 if not p.endswith(".md")]
        if extra:
            ev["files"] = extra
    return ev


def glob_escape(s):
    return glob.escape(s)


def run_meta_paths(target):
    """今ある run.json のパスの集合。新しい run は「起こす前に無かったパス」で見分ける —— mtime の窓で見分けると、
    直前の周の run.json が窓に入って同じ赤を二度数え、リモートの時計のずれ(rsync は向こうの mtime を保つ)で取りこぼす"""
    runs = os.path.join(ROOT, "TestProjects", target["project"], "results", "runs")
    return set(glob.glob(os.path.join(runs, "*", "*", "run.json")))


def gather(target, before):
    """起こす前(before = run_meta_paths の控え)に無かった run の、この対象のシナリオ記録(run.json が profile 一致のものだけ)"""
    found = []
    wanted = scenarios_of(target)
    for meta_path in sorted(run_meta_paths(target) - before):
        try:
            with open(meta_path, encoding="utf-8") as f:
                meta = json.load(f)
        except (OSError, ValueError):
            continue
        if meta.get("profile") != target["profile"]:
            continue
        for path in sorted(glob.glob(os.path.join(os.path.dirname(meta_path), "scenarios", "*.json"))):
            try:
                with open(path, encoding="utf-8") as f:
                    rec = json.load(f)
            except (OSError, ValueError):
                continue
            sid = rec.get("scenarioID", "")
            if not any(sid == w or sid.startswith(w + ".") or sid.startswith(w + "@") for w in wanted):
                continue
            found.append((meta, rec, path))
    return found


def signature(rec):
    """赤の署名 = 最初の失敗ステップの 段・コマンド・failureKind・注記。言えない欄は - (推測で埋めない)"""
    steps = rec.get("failedSteps") or []
    if not steps:
        why = rec.get("skipKind") or ("timedOut" if rec.get("timedOut") else "no-failed-step")
        return f"- / - / - / {why}"
    s = steps[0]
    return " / ".join([f"#{s.get('index', '-')} {s.get('section') or '-'}", s.get("command") or "-",
                       s.get("failureKind") or "-", ",".join(sorted(s.get("notes") or [])) or "-"])


def append_ledger(out, rows):
    with open(os.path.join(out, "ledger.ndjson"), "a", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def play_target(oid, target, round_no, opts, out, stats):
    """1対象を1回回して台帳へ書く"""
    started = time.time()
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(started))
    before = run_meta_paths(target)
    log = os.path.join(out, "logs", f"r{round_no:04d}-{oid}.log")
    cmd = run_args(target, opts)
    print(f"[{stamp}] 周 {round_no} {oid} {target['project']}:{target['profile']} {' '.join(scenarios_of(target))}", flush=True)
    code, timed_out = run_child(cmd, log, opts.run_timeout)
    base = {"time": stamp, "round": round_no, "target": oid, "runner": opts.runner, "exit": code,
            "log": os.path.relpath(log, out)}
    if _interrupted:
        print(f"   ⛔ 中断(exit {code})。この回は数えません", flush=True)
        return False
    records = gather(target, before)
    rows = []
    for meta, rec, path in records:
        row = {**base, "runID": meta.get("runID"), "scenarioID": rec.get("scenarioID"), "worker": rec.get("worker"),
               "host": rec.get("host"), "durationMs": rec.get("durationMs"), "passed": bool(rec.get("passed"))}
        if not row["passed"]:
            row["failedSteps"] = [step_row(s) for s in rec.get("failedSteps") or []]
            if rec.get("errorLogs"):
                row["errorLogs"] = [e[:DETAIL_LIMIT] for e in rec["errorLogs"][:3]]
            if rec.get("skipKind"):
                row["skipKind"] = rec["skipKind"]
            row["signature"] = signature(rec)
            row["evidence"] = evidence_of(rec, path)
            wa = meta.get("workerAnomalies")
            if wa:
                row["workerAnomalies"] = wa   # デバイスの事象(run.json)。赤と同じ run に起きた事実
        rows.append(row)
    if not rows:
        # 結果の記録が1つも出ない = ステップに到達していない(断られた・ビルドの失敗・timeout)。ログの末尾が材料
        rows.append({**base, "passed": None, "signature": f"no-record / exit {code}" + (" / timeout" if timed_out else ""),
                     "logTail": first_lines_tail(log)})
    append_ledger(out, rows)
    for row in rows:
        stats.note(oid, row)
        mark = "✅" if row["passed"] else ("❌" if row["passed"] is False else "⚠️")
        print(f"   {mark} {row.get('scenarioID') or '(記録なし)'} {row.get('worker') or ''} "
              f"{'' if row['passed'] else row['signature']}", flush=True)
    return True


class Stats:
    def __init__(self, targets):
        self.targets = targets
        self.by = {oid: {"runs": 0, "red": 0, "norecord": 0, "sigs": {}} for oid in targets}

    def note(self, oid, row):
        s = self.by[oid]
        if row["passed"] is None:
            s["norecord"] += 1
            key = row["signature"]
        elif row["passed"]:
            s["runs"] += 1
            return
        else:
            s["runs"] += 1
            s["red"] += 1
            key = row["signature"]
        sig = s["sigs"].setdefault(key, {"count": 0, "last": None, "evidence": None, "step": None})
        sig["count"] += 1
        sig["last"] = row["time"]
        sig["evidence"] = (row.get("evidence") or {}).get("report") or row.get("log")
        steps = row.get("failedSteps") or []
        sig["step"] = steps[0].get("description") if steps else None


def write_summary(out, opts, stats, started, rounds_done, state):
    lines = [f"# soak の経過", "",
             f"- 開始: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(started))} / 経過 {(time.time() - started) / 60:.0f} 分 / "
             f"完了した周 {rounds_done} / 実行機 {opts.runner} / 状態 {state}",
             f"- 台帳: ledger.ndjson(1行 = 1シナリオ記録。赤は失敗ステップ・証跡のパス付き)/ 各回のログ: logs/", ""]
    for oid, target in stats.targets.items():
        s = stats.by[oid]
        lines += [f"## {oid} {target['project']} : {target['profile']} : {' + '.join(scenarios_of(target))}",
                  f"- 回数 {s['runs']} / 赤 {s['red']} / 記録なし {s['norecord']}(記録なし = 結果 JSON が出なかった run。断られた・ビルド失敗・timeout)"
                  + (f" / 形 {target['mode_note']}" if target.get("mode_note") else ""),
                  f"- 台帳の watch: {target['watch']}"]
        if s["sigs"]:
            lines.append("- 赤の署名(最初の失敗ステップの #index 段 / command / failureKind / notes)ごとの件数:")
            for key, sig in sorted(s["sigs"].items(), key=lambda kv: -kv[1]["count"]):
                step = f" — {sig['step'][:80]}" if sig["step"] else ""
                lines.append(f"  - {sig['count']} 回: `{key}`{step}(最後 {sig['last']}・証跡 {sig['evidence'] or '-'})")
        else:
            lines.append("- 赤なし")
        lines.append("")
    tmp = os.path.join(out, "summary.md.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    os.replace(tmp, os.path.join(out, "summary.md"))


def prepare_remote(opts):
    """リモートで回すなら開始前に align.sh を1回。失敗したら止める(手元だけで続けない)"""
    if opts.runner == "local":
        return True
    print(f"==> Scripts/align.sh {opts.runner}", flush=True)
    code = subprocess.run([os.path.join(ROOT, "Scripts", "align.sh"), opts.runner], cwd=ROOT,
                          stdin=subprocess.DEVNULL).returncode
    if code != 0:
        print(f"❌ align.sh {opts.runner} が失敗しました(exit {code})。揃っていない機械で回さず、手元だけで続けることもしません")
        return False
    return True


def main():
    sys.stdout.reconfigure(line_buffering=True)
    ap = argparse.ArgumentParser(description="低頻度の台帳項目の再現シナリオを回し続けて、赤の出た回の材料を貯める")
    ap.add_argument("--targets", default="", help="OI の ID をカンマ区切り(例 OI-315,OI-325)。省略で soak-targets.json の全部")
    ap.add_argument("--hours", type=float, help="この時間を過ぎたら次の周を始めない(走っている周は終える)")
    ap.add_argument("--rounds", type=int, help="周の数")
    ap.add_argument("--runner", default="local", help="実行機 = fleetest remote machines の名前、または local(この Mac。既定)")
    ap.add_argument("--out", default="", help="成果物の置き場(既定 ~/github/wave1008/_work/soak-<時刻>/)")
    ap.add_argument("--broadcast", action="store_true", help="全対象を各デバイスで1回ずつ回す(表の broadcast: true の対象はこれ無しでも)")
    ap.add_argument("--skip-build", action="store_true", help="fleetest run に --skip-build を渡す(周の間にツールの Sources を変えないとき)")
    ap.add_argument("--wait-lock", type=int, default=WAIT_LOCK, help=f"dispatch.lock の待ち上限の秒(既定 {WAIT_LOCK})")
    ap.add_argument("--run-timeout", type=int, default=RUN_TIMEOUT, help=f"1回の fleetest run の上限の秒(既定 {RUN_TIMEOUT})")
    ap.add_argument("--check", action="store_true", help="対象表の project / profile / シナリオの実在だけ確かめて終わる")
    ap.add_argument("--dry-run", action="store_true", help="撃つコマンドだけ出す(デバイスを使わない)")
    opts = ap.parse_args()

    targets = load_targets([t for t in opts.targets.split(",") if t])
    problems = [p for oid, t in targets.items() for p in check_target(oid, t)]
    if opts.check or opts.dry_run:
        for p in problems:
            print(f"❌ {p}")
        if opts.check:
            print(f"{'❌ 実在しない対象があります' if problems else '✅ 全対象の project / profile / シナリオが実在します'}({len(targets)} 対象)")
            return 1 if problems else 0
    elif problems:
        for p in problems:
            print(f"❌ {p}")
        return 1
    if opts.dry_run:
        if opts.runner != "local":
            print(f"+ Scripts/align.sh {opts.runner}   # 開始前に1回")
        for oid, t in targets.items():
            print(f"{oid}: " + " ".join(shlex.quote(a) for a in run_args(t, opts)))
        print(f"# 1周 = 上の {len(targets)} コマンドを順に1回ずつ。--rounds / --hours で周数を決める。成果物: ledger.ndjson・summary.md・done")
        return 1 if problems else 0
    if opts.rounds is None and opts.hours is None:
        ap.error("--rounds か --hours のどちらかが要ります")
    if not os.access(FLEETEST, os.X_OK):
        print(f"❌ {FLEETEST} が無い(swift build --product fleetest を先に)")
        return 1

    out = os.path.expanduser(opts.out) if opts.out else os.path.expanduser(
        os.path.join("~/github/wave1008/_work", "soak-" + time.strftime("%Y%m%d-%H%M%S")))
    os.makedirs(os.path.join(out, "logs"), exist_ok=True)
    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)
    started = time.time()
    stats = Stats(targets)
    rounds_done, state, code = 0, "running", 0
    try:
        print(f"==> 成果物: {out} / 対象: {', '.join(targets)} / 実行機: {opts.runner}", flush=True)
        if not prepare_remote(opts):
            state, code = "align-failed", 1
        else:
            write_summary(out, opts, stats, started, rounds_done, state)
            while not _interrupted:
                if opts.rounds is not None and rounds_done >= opts.rounds:
                    break
                if opts.hours is not None and time.time() - started >= opts.hours * 3600:
                    break
                for oid, target in targets.items():
                    if _interrupted or not play_target(oid, target, rounds_done + 1, opts, out, stats):
                        break
                    write_summary(out, opts, stats, started, rounds_done, state)
                if _interrupted:
                    break
                rounds_done += 1
            state, code = ("interrupted", 130) if _interrupted else ("finished", 0)
    finally:
        write_summary(out, opts, stats, started, rounds_done, state)
        with open(os.path.join(out, "done"), "w") as f:
            f.write(f"{state} exit={code} rounds={rounds_done}\n")
        print(f"==> {state}(周 {rounds_done})。summary: {os.path.join(out, 'summary.md')}", flush=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
