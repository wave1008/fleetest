#!/usr/bin/env bash
# E2EYAppRN を release apk としてビルドし dist/android/ へ配置する。
# android/app/build.gradle の release buildType は signingConfigs.debug で署名する
# (無署名 APK はインストール不可なため)。
set -euo pipefail

cd "$(dirname "$0")/.."

# 依存を lock に揃えてからビルドする(Scripts/rn-deps.sh)
. ../Scripts/rn-deps.sh
rn_sync_node_modules

[ -d node_modules ] || npm ci
test -x android/gradlew || { echo "android/gradlew が無い(pod install/npm install 未実行?)" >&2; exit 1; }

# 自動リンクの控え(autolinking.json)は node_modules の絶対パスを持ち、チェックアウトを移す・改名すると古い場所を指したまま
# gradle が「Configuring project … without an existing directory」で落ちる(E2EAppRN/scripts/build-android.sh と同じ)。
# 今の場所を指していなければ消す(gradle が作り直す)
AUTOLINKING_JSON="android/build/generated/autolinking/autolinking.json"
if [ -f "$AUTOLINKING_JSON" ] && ! grep -qF "$PWD/node_modules" "$AUTOLINKING_JSON"; then
  rm -rf "$(dirname "$AUTOLINKING_JSON")"
fi

(cd android && ./gradlew assembleRelease)

OUT_DIR="dist/android"
mkdir -p "$OUT_DIR"
APK_SRC="android/app/build/outputs/apk/release/app-release.apk"
APK_DST="$OUT_DIR/ft-e2ey-rn-release.apk"
cp "$APK_SRC" "$APK_DST"

echo "built: $APK_DST"
echo "install例: adb install -r $APK_DST"
