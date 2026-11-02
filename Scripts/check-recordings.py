#!/usr/bin/env python3
"""
Scripts/e2e.sh --record が各 run 後に呼ぶ録画パイプラインの整合チェック。
<project>/results/runs/ 配下の最新 runDir を検査する:
  (a) recordings/index.json が schemaVersion 2
  (b) クリップの無いシナリオ記録が、切り出しの下限(MIN_CLIP_MS)未満の短いものだけであること
      (VideoRecordingCoordinator.makeClips は実長 500ms 未満の区間を黙って捨てる。クリップ数 == シナリオ数と比べると、
       148〜412ms の短いシナリオの回が赤になる)。クリップがシナリオ記録より多いのは常に不一致
  (c) 各クリップの segments 合計 durationMs が対応するシナリオの durationMs と ±2秒以内
  (d) 参照先 mp4 が存在し 0 バイトでない
不一致は詳細を stderr に出し、exit 非0で終える(e2e.sh 側がこれを FAILED 扱いにする)。
record:false の run には使わない(index.json 自体が存在しないため常に失敗する)。
"""
import argparse
import json
import sys
from pathlib import Path

DURATION_TOLERANCE_MS = 2000
# VideoRecordingCoordinator.makeClips の `>= 0.5`(秒)と同期。これ未満のシナリオはクリップが作られないのが正常
MIN_CLIP_MS = 500


def unexplained_missing_clips(recordings: list[dict], scenario_records: dict[str, list[dict]]) -> list[str]:
    """クリップの数が合わない理由を、短いシナリオで説明できない分だけ返す(空なら整合)。
    シナリオID ごとに、クリップを長いほうの記録から割り当て、余った記録がすべて MIN_CLIP_MS 未満であることを見る。
    リトライ等で同じ ID の記録が複数ある回にも効く。"""
    problems: list[str] = []
    clips_by_id: dict[str, int] = {}
    for entry in recordings:
        key = entry.get("scenarioID", "")
        clips_by_id[key] = clips_by_id.get(key, 0) + 1
    for scenario_id, count in clips_by_id.items():
        have = len(scenario_records.get(scenario_id, []))
        if count > have:
            problems.append(f"{scenario_id}: クリップ({count})がシナリオ記録({have})より多い")
    for scenario_id, records in scenario_records.items():
        ordered = sorted(records, key=lambda r: r.get("durationMs", 0), reverse=True)
        leftover = ordered[clips_by_id.get(scenario_id, 0):]
        too_long = [r for r in leftover if r.get("durationMs", 0) >= MIN_CLIP_MS]
        if too_long:
            problems.append(f"{scenario_id}: クリップが無い記録が {len(too_long)} 件あります"
                            f"(実行時間 {[r.get('durationMs', 0) for r in too_long]}ms は下限 {MIN_CLIP_MS}ms 以上)")
    return problems


def find_latest_run_dir(project_root: Path) -> Path | None:
    runs_root = project_root / "results" / "runs"
    if not runs_root.is_dir():
        return None
    # runID(<YYYY-MM>/<runID>)は先頭 yyyyMMdd-HHmmss なので辞書順=時系列順(RunResultsStore と同じ規則)
    candidates = sorted(
        (p for p in runs_root.glob("*/*") if (p / "run.json").is_file()),
        key=lambda p: p.name,
    )
    return candidates[-1] if candidates else None


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True, help="TestProjects/<name> の <name>")
    parser.add_argument("--repo-root", default=None,
                        help="省略時はこのスクリプト(Scripts/)の1階層上をリポジトリルートとみなす")
    args = parser.parse_args()

    repo_root = Path(args.repo_root) if args.repo_root else Path(__file__).resolve().parent.parent
    project_root = repo_root / "TestProjects" / args.project

    run_dir = find_latest_run_dir(project_root)
    if run_dir is None:
        print(f"❌ [check-recordings] {args.project}: results/runs/ に実行結果がありません", file=sys.stderr)
        return 1

    index_path = run_dir / "recordings" / "index.json"
    if not index_path.is_file():
        print(f"❌ [check-recordings] {run_dir}: recordings/index.json がありません"
              "(record:true の run のはずが録画が1件も残らなかった可能性)", file=sys.stderr)
        return 1

    try:
        index = load_json(index_path)
    except (json.JSONDecodeError, OSError) as e:
        print(f"❌ [check-recordings] {index_path}: 読み込めません: {e}", file=sys.stderr)
        return 1

    errors: list[str] = []

    # (a) schemaVersion
    schema_version = index.get("schemaVersion")
    if schema_version != 2:
        errors.append(f"schemaVersion が 2 ではありません: {schema_version!r}")

    recordings = index.get("recordings", [])

    # scenarios/*.json を集計(scenarioID → レコード群。freeze retry 等で複数ありうる)
    scenarios_dir = run_dir / "scenarios"
    scenario_records: dict[str, list[dict]] = {}
    if scenarios_dir.is_dir():
        for f in sorted(scenarios_dir.glob("*.json")):
            try:
                record = load_json(f)
            except (json.JSONDecodeError, OSError) as e:
                errors.append(f"{f.name}: 読み込めません: {e}")
                continue
            scenario_records.setdefault(record.get("scenarioID", ""), []).append(record)

    # (b) クリップの無い記録は、切り出しの下限未満の短いシナリオだけ
    errors.extend(unexplained_missing_clips(recordings, scenario_records))

    for entry in recordings:
        scenario_id = entry.get("scenarioID", "<unknown>")
        file_rel = entry.get("file")
        segments = entry.get("segments", [])
        clip_duration_ms = sum(s.get("durationMs", 0) for s in segments)

        # (c) durationMs の突き合わせ(同一 scenarioID が複数あれば最も近いものと比較する)
        candidates = scenario_records.get(scenario_id, [])
        if candidates:
            best = min(candidates, key=lambda r: abs(r.get("durationMs", 0) - clip_duration_ms))
            scenario_duration_ms = best.get("durationMs", 0)
            diff = abs(scenario_duration_ms - clip_duration_ms)
            if diff > DURATION_TOLERANCE_MS:
                errors.append(
                    f"{scenario_id}: クリップ長({clip_duration_ms}ms)とシナリオ実行時間"
                    f"({scenario_duration_ms}ms)の差が {diff}ms(許容 {DURATION_TOLERANCE_MS}ms を超過)")
        else:
            errors.append(f"{scenario_id}: 対応する scenarios/*.json が見つかりません")

        # (d) mp4 の存在・非0バイト
        if not file_rel:
            errors.append(f"{scenario_id}: index.json に file フィールドがありません")
            continue
        mp4_path = run_dir / file_rel
        if not mp4_path.is_file():
            errors.append(f"{scenario_id}: 参照先 mp4 が存在しません: {file_rel}")
        elif mp4_path.stat().st_size == 0:
            errors.append(f"{scenario_id}: 参照先 mp4 が 0 バイトです: {file_rel}")

    if errors:
        print(f"❌ [check-recordings] {run_dir}: 録画整合チェックで {len(errors)} 件の不一致", file=sys.stderr)
        for e in errors:
            print(f"   - {e}", file=sys.stderr)
        return 1

    print(f"✅ [check-recordings] {run_dir}: 録画整合チェック OK({len(recordings)} クリップ)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
