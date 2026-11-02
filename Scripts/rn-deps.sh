# shellcheck shell=bash
# RN の SUT のビルド前に、入っている依存(node_modules・Pods)をリポジトリの lock に揃える。
# E2E*AppRN/scripts/build-*.sh が SUT ディレクトリを cwd にして source する:
#   rn_sync_node_modules   # iOS / Android とも
#   rn_sync_pods           # iOS だけ(node_modules の後 = Podfile が node_modules を読む)
#
# - ビルドは入っている依存をそのまま使う。lock だけ新しい版になった機械(align で package-lock.json だけ
#   変わったリモート等)では、揃えないと古い版の RN で「作り直した」アプリになり、黙って古い版で回る
# - 揃える側は **lock を書き換えない**(npm ci / pod install --deployment)。lock は追跡ファイルで、
#   書き換えるとクローンが汚れて次の align が止まる。lock と食い違う解決が要るなら、ここで落ちる
# - 判定は mtime でなく中身で見る(git checkout は内容が同じでも mtime を進め、毎回 npm ci になる)

# package-lock.json の各パッケージの版が node_modules/.package-lock.json(npm が入れた記録)と一致するか。
# optional は機種で入らないものがあるので見ない
_rn_node_modules_match_lock() {
  python3 -I -c '
import json, sys
lock = json.load(open("package-lock.json"))["packages"]
try:
    have = json.load(open("node_modules/.package-lock.json"))["packages"]
except (OSError, ValueError, KeyError):
    sys.exit(1)
sys.exit(1 if any(
    k.startswith("node_modules/") and not v.get("optional")
    and have.get(k, {}).get("version") != v.get("version")
    for k, v in lock.items()) else 0)'
}

rn_sync_node_modules() {
  _rn_node_modules_match_lock && return 0
  echo "→ node_modules が package-lock.json と食い違うので npm ci で入れ直します"
  npm ci
}

# pod install が書く自動リンクの記録が、このクローンを指して在るか。無い・別の置き場所を指す記録のままだと、
# ビルド時の codegen が WebView 等のネイティブ部品を登録しないアプリを作り、起動直後に落ちる
# (「Module has not been registered as callable」。Pods は lock と一致するので Manifest.lock だけでは入れ直しに気づかない)
_rn_autolinking_matches_checkout() {
  python3 -I -c '
import json, os, sys
try:
    root = json.load(open("ios/build/generated/autolinking/autolinking.json"))["root"]
except (OSError, ValueError, KeyError):
    sys.exit(1)
sys.exit(0 if os.path.realpath(root) == os.path.realpath(".") else 1)'
}

rn_sync_pods() {
  # Manifest.lock は pod install が Pods/ に書く Podfile.lock の写し(CocoaPods 自身の同期判定と同じ)
  if cmp -s ios/Podfile.lock ios/Pods/Manifest.lock; then
    _rn_autolinking_matches_checkout && return 0
    echo "→ 自動リンクの記録が無い(または別の置き場所を指す)ので pod install --deployment で作り直します"
  else
    echo "→ Pods が Podfile.lock と食い違うので pod install --deployment で入れ直します"
  fi
  # Local Podspecs は外部パスの podspec の前回の写し。RN の版を上げると CocoaPods がこの古い写しと比べ、
  # hermes-engine で「版が変わった」と止まるか、React-Core-prebuilt を黙って前の版のまま残す
  # (0.87 で前の版のヘッダの置き方が残り module.modulemap が無いと落ちる)。消せば node_modules から読み直す
  rm -rf "ios/Pods/Local Podspecs"
  (cd ios && pod install --deployment)
}
