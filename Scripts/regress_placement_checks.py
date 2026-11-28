# regress.py の後段の検査: クラスの寄せ方(RR-8.3)と run メモのマシン間の共有(DR-208)が、回帰の実際の run で効いたか。
# どちらもシナリオの中からは自分の走った場所が見えないので、結果(scenarios/*.json の host・worker と events)を run の後に読む。
# 対になるシナリオは E2E-CMP だけに置く: 27_クラスの寄せ方.swift(3クラス)・28_runメモをマシンをまたいで共有する.swift

import glob
import json
import os
import subprocess
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = "E2E-CMP"
# クラス名 → 寄せる単位。"device" = (host, worker) が1つ・"machine" = host が1つ
PLACED_CLASSES = {
    "順に流すクラス": "device",
    "一台で流すクラス": "device",
    "一台のマシンで流すクラス": "machine",
}
RUN_MEMO_CLASS = "runメモをマシンをまたいで共有する"
CROSS_MACHINE_CHECKER = os.path.join(ROOT, "Scripts", "check-run-memo-cross-machine.py")


def _nfc(text):
    return unicodedata.normalize("NFC", text)


def recent_run_files(project, pattern, since, until=None):
    """`results/runs/<月>/<runID>/` の下の `pattern`("run.json" か "scenarios/*.json")のうち、mtime が窓に入るもの。
    **run のフォルダを先に絞る**(全履歴を再帰の glob で舐めると手元の 49 万件で 35 秒かかった)。絞りは「中身を足した・置き換えた
    フォルダの mtime は窓より古くならない」ことに頼る(書き手は新規作成か rename で置く。その場の上書きだけは拾えない)"""
    runs = os.path.join(ROOT, "TestProjects", project, "results", "runs")
    inner = os.path.dirname(pattern)   # "" か "scenarios"
    for month in sorted(os.listdir(runs)) if os.path.isdir(runs) else []:
        month_dir = os.path.join(runs, month)
        if not os.path.isdir(month_dir) or os.path.getmtime(month_dir) < since:
            continue
        for run_id in sorted(os.listdir(month_dir)):
            folder = os.path.join(month_dir, run_id, inner)
            try:
                if os.path.getmtime(folder) < since:
                    continue
            except OSError:
                continue
            for path in glob.glob(os.path.join(month_dir, run_id, pattern)):
                if since <= os.path.getmtime(path) and (until is None or os.path.getmtime(path) <= until):
                    yield path


def _recent(pattern, since, until):
    return recent_run_files(PROJECT, pattern, since, until)


def placement_findings(since, until=None):
    """散っていたクラスの1行ずつ(空 = 全部寄っていた・または走っていない)。
    **プロファイルごとにまとめるので、窓の中でそのプロファイルが1回だけ走っている前提**(回帰の1回 = 各対象を1回)。
    複数の run を跨ぐ窓で呼ぶと別々の run の居場所を「散った」と数える"""
    seen = {}  # (profile, class) → {単位の値}
    for path in _recent(os.path.join("scenarios", "*.json"), since, until):
        class_name = _nfc(os.path.basename(path)).split(".", 1)[0]
        unit = PLACED_CLASSES.get(class_name)
        if unit is None:
            continue
        try:
            with open(path, errors="replace") as f:
                result = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        where = (result.get("host"), result.get("worker")) if unit == "device" else result.get("host")
        seen.setdefault((result.get("profile"), class_name), set()).add(where)
    return [f"{PROJECT} / {profile}: {class_name} ran on {len(places)} {PLACED_CLASSES[class_name]}s: {sorted(map(str, places))}"
            for (profile, class_name), places in sorted(seen.items(), key=lambda item: str(item[0]))
            if len(places) > 1]


def run_memo_findings(since, until=None):
    """(失敗の行, 判定できなかった行)。プロファイルごとに、その回帰で 28_ を走らせた run ディレクトリを全部渡す
    (マシンをまたぐ run はマシンごとに別の run ディレクトリになる)"""
    by_profile = {}
    for run_json in _recent("run.json", since, until):
        run_dir = os.path.dirname(run_json)
        events = os.path.join(run_dir, "events")
        if not os.path.isdir(events) or not any(_nfc(name).startswith(RUN_MEMO_CLASS + ".") for name in os.listdir(events)):
            continue
        try:
            with open(run_json, errors="replace") as f:
                profile = json.load(f).get("profile")
        except (OSError, json.JSONDecodeError):
            continue
        by_profile.setdefault(profile, []).append(run_dir)
    failures, unjudged = [], []
    for profile, run_dirs in sorted(by_profile.items(), key=lambda item: str(item[0])):
        result = subprocess.run(["python3", CROSS_MACHINE_CHECKER, *sorted(run_dirs)], capture_output=True, text=True)
        last = (result.stderr.strip() or result.stdout.strip()).splitlines()[-1:] or [""]
        if result.returncode == 1:
            failures.append(f"{PROJECT} / {profile}: {last[0]}")
        elif result.returncode != 0:
            unjudged.append(f"{PROJECT} / {profile}: {last[0]}")
    return failures, unjudged
