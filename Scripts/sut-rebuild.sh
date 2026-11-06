# shellcheck shell=bash
# SUT の成果物を作り直すかの判定。e2e.sh / e2ex.sh / e2ey.sh / e2e-devices.sh が source する
# (呼び手は FORCE_REBUILD を先に定義しておく):
#   needs_rebuild <成果物> <監視するソース>...   # 真 = 作り直す
#   record_sdk <成果物>                           # ビルドが成功した直後に呼ぶ
#
# 軸は2つ: ①監視するソースが成果物より新しい(mtime)②成果物を作った外部 SDK の版が今と違う
#   (Flutter SDK = Flutter の SUT・Xcode = iOS の成果物すべて。iOS は作ったときの SDK で OS の挙動が変わる)。
# - ②はリポジトリの外にあるので mtime に出ない。SDK だけ上げると古い版で作ったアプリのまま黙って回り、
#   「新しい版で緑」と誤って読む(2026-10-13 に M1Ultra の E2EX-Flutter で踏んだ)
# - 控えは成果物の隣の `<成果物>.sdk`(dist/ は gitignore)。**書くのはビルドが成功した後だけ** ——
#   先に書くと、失敗したビルドの古い成果物が新しい版の印を持ち、以後作り直されない
# - 版を読めないとき(SDK が無い・出力が壊れた)は②を見ない = ①だけで判定する。ビルド自体がそこで落ちる

# $1 = 成果物。外部 SDK の版を控えない成果物(Flutter 以外の Android)は空を返す
sut_sdk_stamp() {
  local app="${1%%/dist/*}"
  if [ -f "$app/pubspec.yaml" ]; then
    # --machine は JSON。ツールの作り直し直後は前に案内行が混ざるので最初の { から読む
    flutter --version --machine 2>/dev/null | python3 -c '
import json, sys
s = sys.stdin.read()
try:
    d = json.loads(s[s.index("{"):])
    print("flutter", d["frameworkRevision"], d["engineRevision"])
except (ValueError, KeyError):
    pass' 2>/dev/null || true
  fi
  case "$1" in
    # ビルド番号(27A266a 等)。同じ版名のベータ違いも区別する
    *.app) xcodebuild -version 2>/dev/null | sed -n 's/^Build version /xcode /p' || true ;;
  esac
}

# RN の SUT の codegen 生成物 `ios/build/generated/ios/ReactCodegen/RCTThirdPartyComponentsProvider.mm` の登録表が
# 空(または無い)= 真。空だと react-native-screens 等の Fabric 部品が登録されず、アプリが起動直後に JS の致命的エラーで
# 毎回落ちる。mtime は変わらないので壊れたビルドが使われ続ける(2026-10-31 に M1Max の E2EY-RN で踏んだ)。$1 = アプリのディレクトリ
rn_provider_is_empty() {
  local f="$1/ios/build/generated/ios/ReactCodegen/RCTThirdPartyComponentsProvider.mm"
  [ -f "$f" ] || return 0
  ! grep -Eq '^[[:space:]]*@"' "$f"
}

# $1 = アプリのディレクトリ。RN の SUT で登録表が空ならメッセージを出して失敗を返す(RN の iOS ビルドの終わりで呼ぶ)
rn_assert_provider_registered() {
  if rn_provider_is_empty "$1"; then
    echo "❌ ios/build/generated/ios/ReactCodegen/RCTThirdPartyComponentsProvider.mm の登録表が空(または無い)です。" >&2
    echo "   Fabric 部品(react-native-screens 等)が登録されず、アプリは起動直後に JS の致命的エラーで落ちます。" >&2
    echo "   ios/build と ios/Pods を消して pod install(codegen)からやり直してください。" >&2
    return 1
  fi
}

# RN の SUT の iOS 成果物(.app)か。$1 = 成果物
sut_is_rn_ios() {
  local app="${1%%/dist/*}"
  case "$1" in *.app) ;; *) return 1 ;; esac
  [ -f "$app/package.json" ] && [ -d "$app/ios" ] && grep -q '"react-native"' "$app/package.json" 2>/dev/null
}

needs_rebuild() {
  local artifact="$1"; shift
  [ "$FORCE_REBUILD" = 1 ] && return 0
  [ -e "$artifact" ] || return 0
  if sut_is_rn_ios "$artifact" && rn_provider_is_empty "${artifact%%/dist/*}"; then
    echo "→ $(basename "$artifact") は codegen の登録表(RCTThirdPartyComponentsProvider.mm)が空なので作り直します" >&2
    return 0
  fi
  local want had
  want="$(sut_sdk_stamp "$artifact")"
  had="$(cat "$artifact.sdk" 2>/dev/null || true)"
  if [ -n "$want" ] && [ "$want" != "$had" ]; then
    if [ -z "$had" ]; then
      echo "→ $(basename "$artifact") を作った SDK の控えが無いので作り直します(今: $want)" >&2
    else
      echo "→ $(basename "$artifact") は別の SDK で作られています(作成時: $had / 今: $want)" >&2
    fi
    return 0
  fi
  [ -n "$(find "$@" -type f -newer "$artifact" 2>/dev/null | head -1)" ]
}

record_sdk() {
  local stamp
  stamp="$(sut_sdk_stamp "$1")"
  [ -z "$stamp" ] || printf '%s\n' "$stamp" > "$1.sdk"
}
