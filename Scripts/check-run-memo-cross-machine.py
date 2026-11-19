#!/usr/bin/env python3
# run メモ(DR-208)がマシンをまたいで届いたかを、run の後に結果から確かめる陽性対照の判定。
# 対になるシナリオは TestProjects/E2E-CMP/scenarios/28_runメモをマシンをまたいで共有する.swift
# (各テストが `writeMemo "readWriterHost" = "<読んだ書き手>"` と `writeMemo "ownHost" = "<自分のホスト>"` を記述に残す)。
#
# 判定: 2つ以上のホストで走った run なら「読んだ書き手 ≠ 自分のホスト」のテストが1本以上あること。
# 1つのホストだけの run は判定できない(exit 2)。中継が効かないと、どのテストも自分のマシンのテストが書いた値しか読めない
#
# 使い方: check-run-memo-cross-machine.py <run の置き場>...
#   run が複数のマシンに分かれると、マシンごとに別の run ディレクトリになる(同じ runGroup)。全部を渡す

import json
import re
import sys
import unicodedata
from pathlib import Path

CLASS = "runメモをマシンをまたいで共有する"
PATTERN = re.compile(r'^writeMemo "(readWriterHost|ownHost)" = "(.*)"$')


def observations(run_dir: Path):
    # ファイル名は NFD で返ることがある(「で」等の濁点が分かれる)ので、正規化してから比べる
    for events in sorted((run_dir / "events").glob("*.ndjson")):
        if not unicodedata.normalize("NFC", events.name).startswith(CLASS + "."):
            continue
        seen = {}
        for line in events.read_text(encoding="utf-8").splitlines():
            try:
                event = json.loads(line).get("event", {})
            except json.JSONDecodeError:
                continue
            if event.get("kind") != "step" or event.get("status") != "passed":
                continue
            match = PATTERN.match(event.get("description", ""))
            if match:
                seen[match.group(1)] = match.group(2)
        if "readWriterHost" in seen and "ownHost" in seen:
            yield events.stem, seen["ownHost"], seen["readWriterHost"]


def main(argv):
    if len(argv) < 2:
        print(__doc__ or "usage: check-run-memo-cross-machine.py <run dir>...", file=sys.stderr)
        return 64
    rows = [row for path in argv[1:] for row in observations(Path(path))]
    if not rows:
        print("no observation: the run did not run the class", CLASS, file=sys.stderr)
        return 2
    for scenario, own, read in rows:
        print(f"{scenario}: ran on {own}, read writer {read}{'  <- crossed machines' if read and own != read else ''}")
    hosts = {own for _, own, _ in rows}
    if len(hosts) < 2:
        print(f"cannot judge: the class ran on one host only ({', '.join(sorted(hosts))})", file=sys.stderr)
        return 2
    crossed = [row for row in rows if row[2] and row[1] != row[2]]
    if not crossed:
        print("FAIL: tests ran on several hosts but none read a value written on another machine", file=sys.stderr)
        return 1
    print(f"OK: {len(crossed)} of {len(rows)} test(s) read a value written on another machine")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
