#!/usr/bin/env bash
# 手元の作業ツリー(未コミットを含む)を全リモートランナーへ揃える(「アラインして」の機械作業ぶん)。
#
# **なぜスクリプトなのか**: 手順そのものは短いが、**並列で撃つ**という一点が人の手だと必ず落ちる
# (2026-09-03 と 2026-09-04 に計3回、`remote align` を1機ずつ送って前の出力を読んでから次を
# 送っていた。うち1回は「並列で」と明示された直後)。台数ぶん待ち時間が伸びるだけの誤りなので、
# **判断の余地を無くして機械に持たせる**。
#
# やること: ①対象の機械を決める ②ロック・到達性の確認 ③各機へ `remote align` を**同時に**投げる
# ④`remote status --json` で各機の revisionCompatible(ツールの中身の要約の一致)が全部 true であることまで確かめる。
#
# 使い方: Scripts/align.sh [--force | --force-lock] [<machine>...]
#   機械を省くと登録簿のうち有効(enabled)なものすべて。
#   コミットも push もしない。`remote align` 自身が手元の作業ツリー(未コミット・未追跡を含む。.gitignore は効く)を
#   ランナーのクローンへ ssh で直送する。中身が同じ機は何もせずに終わる。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# `--force` は **preflight を飛ばさない**。飛ばしても `remote align` 自身が同じロックで止まるので
# 素通しにはならず、素通しにできてしまうと**走っている他人の run を殺す**(向こうで
# `git checkout` + `swift build` をするので、実行中のバイナリが差し替わって SIGKILL される。
# MN-4.1 と同じ事故がリモートで起きる)。
# 代わりに **`remote unlock` を試みてから測り直す** —— あれは「**自分の**死んだディスパッチの
# ロックだけ」を外すので、生きている run と他人のロックは残り、そのときは従来どおり落ちる。
# `--force-lock` は**持ち主を問わず奪う**(`remote unlock --force`)。その run が止まっていると
# 人が確かめたときだけ使う —— 動いていれば向こうのバイナリが差し替わってその run を壊す
FORCE=0
case "${1:-}" in
  --force) FORCE=1; shift ;;
  --force-lock) FORCE=2; shift ;;
esac
case "${1:-}" in -*) echo "usage: Scripts/align.sh [--force | --force-lock] [<machine>...]" >&2; exit 2 ;; esac

FLEETEST="${FLEETEST:-.build/debug/fleetest}"
[ -x "$FLEETEST" ] || { echo "❌ $FLEETEST が無い(swift build を先に)" >&2; exit 1; }

if [ $# -gt 0 ]; then
  MACHINES=$(printf '%s\n' "$@")
else
  # enabled が false のマシンは揃えない(キーが無ければ有効扱い)
  MACHINES=$("$FLEETEST" api remote-machines | python3 -c '
import json,sys
print("\n".join(h["machine"] for h in json.load(sys.stdin).get("hosts", []) if h.get("machine") and h.get("enabled", True)))')
fi
[ -n "$MACHINES" ] || { echo "❌ 揃える対象のリモート機が無い(登録簿が空か全部無効。fleetest remote setup)" >&2; exit 1; }

HOST_ARGS=""
for m in $MACHINES; do HOST_ARGS="$HOST_ARGS --runner $m"; done

# **押し込む前に、向こうが空いているかを見る**(dispatch.lock)。`remote align` 自身も
# ロックを取るので run を壊すことは無いが、**握られていれば align 段で1機ずつ ❌ になる**だけで、
# 「向こうで誰かの run が走っている」という肝心の事実が失敗文の中に埋もれる。
# **押す前に、理由を名指しして何もせずに落ちる**(2026-09-04 ユーザー指摘)
busy_hosts() {
  local raw
  raw=$("$FLEETEST" remote status $HOST_ARGS --json 2>/dev/null | grep '^{' || true)
  python3 - "$raw" <<'PYEOF'
import json, sys
raw = sys.argv[1]
if not raw:
    sys.exit(0)          # 読めないときは止めない(align 自身のロックが最後の砦)
for h in json.loads(raw).get("hosts", []):
    if not h.get("reachable", True):
        print(f"{h.get('host')}: 到達できない")
    elif h.get("lock", "free") != "free":
        print(f"{h.get('host')}: dispatch.lock が握られている({h.get('lock')})")
PYEOF
}

echo "==> preflight (ロック・到達性)"
BUSY=$(busy_hosts)
if [ -n "$BUSY" ] && [ "$FORCE" = 1 ]; then
  echo "$BUSY" | sed 's/^/   /'
  echo "==> --force: 自分の死んだロックだけ外して測り直す(生きている run は殺さない)"
  "$FLEETEST" remote unlock $HOST_ARGS 2>&1 | sed 's/^/   /' || true
  BUSY=$(busy_hosts)
elif [ -n "$BUSY" ] && [ "$FORCE" = 2 ]; then
  echo "$BUSY" | sed 's/^/   /'
  echo "==> --force-lock: 持ち主を問わずロックを奪って測り直す"
  "$FLEETEST" remote unlock --force $HOST_ARGS 2>&1 | sed 's/^/   /' || true
  BUSY=$(busy_hosts)
fi
if [ -n "$BUSY" ]; then
  echo "❌ 揃えられない機がある。何も送っていない:" >&2
  echo "$BUSY" | sed 's/^/   /' >&2
  if [ "$FORCE" = 1 ]; then
    echo "   --force でも外れなかった = 走っている run か、他人のロック。**待つ**か、止まっていると確かめたうえで --force-lock" >&2
  elif [ "$FORCE" = 2 ]; then
    echo "   --force-lock でも外れなかった(到達できない機か、unlock の失敗。上の出力を見る)" >&2
  else
    echo "   (走っている run が終わるのを待つ。自分の死んだロックなら --force。止まっていると確かめた他人のロックなら --force-lock)" >&2
  fi
  exit 1
fi

LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR"' EXIT

# **ここが要点**: 全機を同時に起こし、待つのは最後にまとめて。1機ずつ待たない
echo "==> align $(echo "$MACHINES" | tr '\n' ' ')(並列)"
PIDS=""
for m in $MACHINES; do
  ( "$FLEETEST" remote align "$m" > "$LOGDIR/$m.log" 2>&1; echo $? > "$LOGDIR/$m.code" ) &
  PIDS="$PIDS $!"
done
for pid in $PIDS; do wait "$pid" || true; done

FAILED=0
for m in $MACHINES; do
  code=$(cat "$LOGDIR/$m.code" 2>/dev/null || echo 1)
  # `|| true` は必須 —— grep が 1 件も拾えないと(errexit + pipefail で)この代入が失敗し、
  # 集計を出す前にスクリプトごと落ちて EXIT trap が LOGDIR を消す = ログが失われる
  line=$(grep -E "aligned to|❌|error" "$LOGDIR/$m.log" | tail -1 || true)
  if [ "$code" = 0 ]; then echo "  ✅ $m: ${line:-(出力なし)}"
  else echo "  ❌ $m: ${line:-(出力なし)} (exit=$code / log: $LOGDIR/$m.log)"; FAILED=1
       cp "$LOGDIR/$m.log" "/tmp/align-$m.log"; echo "     ログを /tmp/align-$m.log に残した"; fi
done

# **align の成功報告だけで終わらせない**: 中身が揃ったことは各機の revisionCompatible で確かめる
echo "==> verify"
"$FLEETEST" remote status $HOST_ARGS 2>&1 || true
RAW=$("$FLEETEST" remote status $HOST_ARGS --json 2>/dev/null | grep '^{' || true)
EXPECTED=$(wc -l <<< "$MACHINES" | tr -d ' ')
# 判定は stdin の JSON から python が出す1行(`ok/total`)だけを読む(grep と echo のパイプで SIGPIPE を踏まない)
MATCHED=$(python3 - "$RAW" <<'PYEOF'
import json, sys
raw = sys.argv[1]
hosts = json.loads(raw).get("hosts", []) if raw else []
print(sum(1 for h in hosts if h.get("revisionCompatible") is True))
PYEOF
)
if [ "$MATCHED" != "$EXPECTED" ]; then
  echo "❌ 中身が手元と一致した機は $MATCHED/$EXPECTED" >&2
  FAILED=1
fi
[ "$FAILED" = 0 ] && echo "✅ 全機 手元の内容に揃った"
exit "$FAILED"
