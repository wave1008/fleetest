# shellcheck shell=bash
# ジョブ(run の上の1階層。DS-18.11)の始めと終わり。e2e.sh / e2ex.sh / e2ey.sh が source する。
# 予定の run を先に宣言しておくと、中で打った `fleetest run` が環境変数 FT_JOB_ID を見て自分の行を
# 実行中 → 成功/失敗にする(行の照合は project:profile)。run ボードに「あと何本控えているか」が出る。
# **ベストエフォート**: 宣言に失敗してもスクリプトは止めない(見える化だけの機能)。
# 呼び手は EXIT の trap で job_end を呼ぶこと(中断でも台帳を残さない。残っても持ち主の pid が死ねば読み手は無視する)。

FT_JOB_ID=""

# $1 = 題名, 以降 = "project:profile" の並び(宣言順に表示される)
job_begin() {
  local title="$1"; shift
  local args=() row
  for row in "$@"; do args+=(--run "$row"); done
  local id
  # ${a[@]+…}: macOS の bash 3.2 は set -u の下で空配列の "${a[@]}" を unbound で落とす
  if id="$("$FLEETEST" job begin --title "$title" --owner-pid $$ ${args[@]+"${args[@]}"} 2>/dev/null)" && [ -n "$id" ]; then
    FT_JOB_ID="$id"
    export FT_JOB_ID
    # 外から継いだ「祖先が行を受け持っている」印を外す(残すと中の run が自分の行を印付けしない)
    unset FT_JOB_MARKED
  else
    echo "⚠️ ジョブを宣言できませんでした(run ボードに待機中の run が出ません。実行は続けます)" >&2
  fi
}

job_end() {
  [ -n "$FT_JOB_ID" ] || return 0
  "$FLEETEST" job end --id "$FT_JOB_ID" >/dev/null 2>&1 || true
  FT_JOB_ID=""
}
