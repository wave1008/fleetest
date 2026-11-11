#!/usr/bin/env python3
# 検証済みの印(.fleetest/<mode>-<suite>-verified)の条件から外す赤の一覧と判定。regress.py と e2ex.sh が共有する(片方で持たない)。
# 外すのは「原因を観測し、ツールでは直せないと決めた赤」だけ。シナリオは回し続け、外した赤は回すたびに名指して出す(黙らせない)。
# 終了コードは変えない(赤は赤)。変わるのは印を書くかだけ。行ごとに台帳(docs/open-issues.md)の項目を理由に持ち、項目が閉じたら行を消す。
# 行を足すスイートは、その印を書くスクリプトがこの判定を呼んでいること(regressPlan.test.mjs が E2EX = e2ex.sh を固定)。
#
# 使い方(スクリプトから): python3 Scripts/mark_exclusions.py <プロジェクト> <プロファイル> <開始の epoch 秒>
#   exit 0 = その回の赤が全部この表の行(1本以上)。外した赤を1行ずつ出す / exit 1 = 言えない(表に無い赤・記録の欠け・赤の記録が無い)
import glob, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (プロジェクト, プロファイル, シナリオ ID) → 台帳の項目
EXCLUSIONS = {
    # 塗り順の無い木で見出しの下の行を撃つ(探索の止まる位置しだい)。見分ける材料が木にも isHittable にも無い
    ("E2EX-Flutter", "ios-xcuitest", "貼り付く見出しのリストを扱えること.S0010"): "OI-216",
    ("E2EX-RN", "ios-xcuitest", "貼り付く見出しのリストを扱えること.S0010"): "OI-216",
    ("E2EX-iOS", "ios-xcuitest", "貼り付く見出しのリストを扱えること.S0010"): "OI-216",
}


def failures_since(project, profile, since, root=ROOT):
    """since(epoch 秒)以後に終わったそのプロジェクト・プロファイルの run の、赤のシナリオ ID(同じシナリオが複数台なら複数)。
    run が1本も無い・run.json の failed とシナリオの記録の赤の数が合わない(記録が欠けた)なら None = 言えない"""
    runs = [p for p in glob.glob(os.path.join(root, "TestProjects", project, "results", "runs", "*", "*", "run.json"))
            if os.path.getmtime(p) >= since]
    found, failed = False, []
    for path in runs:
        try:
            with open(path) as f:
                run = json.load(f)
        except (OSError, ValueError):
            return None
        if run.get("profile") != profile:
            continue
        found = True
        reds = []
        for scenario_path in glob.glob(os.path.join(os.path.dirname(path), "scenarios", "*.json")):
            try:
                with open(scenario_path) as f:
                    scenario = json.load(f)
            except (OSError, ValueError):
                return None
            if scenario.get("passed") is not True:
                reds.append(scenario.get("scenarioID"))
        if len(reds) != run.get("failed"):
            return None
        failed += reds
    return failed if found else None


def excluded_reds(pairs, since, root=ROOT):
    """pairs = [(プロジェクト, プロファイル)]。赤が全部この表の行なら [(プロジェクト, プロファイル, シナリオ ID, 項目)](1本以上)。
    1つでも言えない組・表に無い赤があれば None。赤が1本も無ければ None(失敗の理由がシナリオの外 = 外せない)"""
    out = []
    for project, profile in pairs:
        reds = failures_since(project, profile, since, root)
        if reds is None:
            return None
        for sid in reds:
            reason = EXCLUSIONS.get((project, profile, sid))
            if reason is None:
                return None
            out.append((project, profile, sid, reason))
    return out or None


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: mark_exclusions.py <project> <profile> <since-epoch>")
    reds = excluded_reds([(sys.argv[1], sys.argv[2])], float(sys.argv[3]))
    if reds is None:
        sys.exit(1)
    for project, profile, sid, reason in reds:
        print(f"{project} / {profile}: {sid}({reason})")
