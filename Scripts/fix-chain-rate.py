#!/usr/bin/env python3
"""直し系コミットが「直しの直し」になっている割合を週ごとに出す(デバイス不要・git を読むだけ)。

  python3 Scripts/fix-chain-rate.py                  # 直近12週
  python3 Scripts/fix-chain-rate.py --weeks 26 --baseline
  python3 Scripts/fix-chain-rate.py --since 2026-11-01 --list   # 直しの直しの組を1行ずつ

- 直し系 = 件名が FIX_SUBJECT に当たるコミット(マージは除く)。件名の語の一致なので「振り直し」等の複合語も拾う
  (誤差。経緯は docs/verification/judgment.md「直しの連鎖を測る」)
- 各直し系コミットが Sources/ で消した・変えた行を `git blame -w -M -C <commit>^` で出どころまで辿る。
  **chain** = 出どころが直し系コミットで、かつ RECENT_DAYS 以内の行の割合(行の加重。上限は1コミット MAX_FILES ファイル・MAX_LINES 行)
- **--baseline** は直し系でないコミットで同じ値を測る比較列。直し系でないコミットも若い行をよく触るので、chain は比較列との差で読む
- 1コミットに複数の所見を束ねた回は1件に数える(件数は不具合数ではない)
"""
import argparse, datetime, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                      cwd=__import__("os").path.dirname(__import__("os").path.abspath(__file__))).stdout.strip()
FIX_SUBJECT = re.compile(r"直す|直し|修正|誤った|退行|戻す|Revert")
RECENT_DAYS = 7      # 「入れたばかり」の窓(日)。分類の手判定で (自) の直すまでの日数は中央値0日・36件中35件が8日以内
MAX_FILES = 8        # 1コミットあたり blame するファイル数の上限(実行時間の枠。大きい束ねコミットを代表値で済ませる)
MAX_LINES = 300      # 1コミットあたり blame する行数の上限(同上)


def git(*args):
    r = subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True, errors="replace")
    if r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args[:2])} failed: {r.stderr.strip()[:200]}")
    return r.stdout


def commits(since):
    out = git("log", "--no-merges", f"--since={since}", "--format=%H%x09%ct%x09%s")
    rows = []
    for line in out.splitlines():
        h, ct, s = line.split("\t", 2)
        rows.append((h, int(ct), s))
    return rows


def changed_ranges(h):
    diff = git("diff", "-U0", "--no-renames", h + "^", h, "--", "Sources/")
    ranges, cur = {}, None
    for line in diff.splitlines():
        if line.startswith("--- "):
            cur = line[6:] if line.startswith("--- a/") else None
        elif line.startswith("@@") and cur:
            m = re.match(r"@@ -(\d+)(?:,(\d+))? ", line)
            a = int(m.group(1)); n = int(m.group(2)) if m.group(2) is not None else 1
            if n > 0:
                ranges.setdefault(cur, []).append((a, a + n - 1))
    return ranges


def origins(h):
    """消した・変えた行の出どころ [(origin_sha, origin_time)]。初回コミットは親が無いので空。"""
    try:
        ranges = changed_ranges(h)
    except RuntimeError:
        return []
    result, budget = [], MAX_LINES
    for path, rs in list(ranges.items())[:MAX_FILES]:
        args = []
        for a, b in rs:
            if budget <= 0:
                break
            b = min(b, a + budget - 1); budget -= b - a + 1
            args += ["-L", f"{a},{b}"]
        if not args:
            break
        out = git("blame", "-w", "-M", "-C", "--porcelain", *args, h + "^", "--", path)
        times, cur, lines = {}, None, []
        for line in out.splitlines():
            m = re.match(r"^([0-9a-f]{40}) \d+ \d+", line)
            if m:
                cur = m.group(1); lines.append(cur)
            elif line.startswith("committer-time ") and cur:
                times[cur] = int(line.split()[1])
        result += [(c, times[c]) for c in lines if c in times]
    return result


def week_of(ts):
    d = datetime.date.fromtimestamp(ts)
    return d - datetime.timedelta(days=d.weekday())


def main():
    ap = argparse.ArgumentParser(description="Weekly share of fix commits that re-fix recent fixes.")
    ap.add_argument("--weeks", type=int, default=12)
    ap.add_argument("--since", help="YYYY-MM-DD (overrides --weeks)")
    ap.add_argument("--baseline", action="store_true", help="also measure non-fix commits for comparison")
    ap.add_argument("--list", action="store_true", help="print each fix commit whose majority origin is a recent fix")
    a = ap.parse_args()
    since = a.since or (datetime.date.today() - datetime.timedelta(weeks=a.weeks)).isoformat()

    # 出どころが直し系かは、窓より前のコミットの件名も要る(窓の頭の直しの出どころは窓の外にある)
    subjects = {h: s for h, _, s in commits("2000-01-01")}
    rows = commits(since)
    fixes = [r for r in rows if FIX_SUBJECT.search(r[2])]
    others = [r for r in rows if not FIX_SUBJECT.search(r[2])] if a.baseline else []

    with ThreadPoolExecutor(10) as ex:
        fix_orig = dict(zip([r[0] for r in fixes], ex.map(origins, [r[0] for r in fixes])))
        base_orig = dict(zip([r[0] for r in others], ex.map(origins, [r[0] for r in others])))

    def chain_share(sel, orig):
        lines = chained = recent = 0
        for h, ct, _ in sel:
            for c, t in orig.get(h, []):
                lines += 1
                young = (ct - t) / 86400 <= RECENT_DAYS
                recent += young
                chained += young and bool(FIX_SUBJECT.search(subjects.get(c, "")))
        return lines, recent, chained

    weeks = sorted({week_of(ct) for _, ct, _ in rows})
    hdr = f"{'week':<11}{'commits':>8}{'fixes':>7}{'fix%':>7}{'lines':>7}{'recent%':>9}{'chain%':>8}"
    if a.baseline:
        hdr += f"{'base_chain%':>13}"
    print(hdr)
    for w in weeks:
        wr = [r for r in rows if week_of(r[1]) == w]
        wf = [r for r in fixes if week_of(r[1]) == w]
        n, rec, ch = chain_share(wf, fix_orig)
        line = (f"{w.isoformat():<11}{len(wr):>8}{len(wf):>7}{100 * len(wf) / max(len(wr), 1):>6.1f}%"
                f"{n:>7}{(100 * rec / n if n else 0):>8.1f}%{(100 * ch / n if n else 0):>7.1f}%")
        if a.baseline:
            bn, _, bch = chain_share([r for r in others if week_of(r[1]) == w], base_orig)
            line += f"{(100 * bch / bn if bn else 0):>12.1f}%"
        print(line)
    n, rec, ch = chain_share(fixes, fix_orig)
    print(f"total: fixes={len(fixes)}/{len(rows)} blamed_lines={n} recent={100 * rec / max(n, 1):.1f}% chain={100 * ch / max(n, 1):.1f}%")

    if a.list:
        print("\nfix commits whose majority origin is a fix within %d days:" % RECENT_DAYS)
        for h, ct, s in fixes:
            o = fix_orig.get(h, [])
            if not o:
                continue
            counts = {}
            for c, t in o:
                counts[c] = counts.get(c, 0) + 1
            top = max(counts, key=counts.get)
            t = dict(o)[top]
            if (ct - t) / 86400 <= RECENT_DAYS and FIX_SUBJECT.search(subjects.get(top, "")):
                print(f"  {h[:9]} <- {top[:9]} ({(ct - t) / 86400:.1f}d)  {s[:70]}")


if __name__ == "__main__":
    sys.exit(main())
