#!/usr/bin/env bash
# Builds the release APK and names it claude-ssh-release.apk.
set -euo pipefail

cd "$(dirname "$0")/.."

export JAVA_HOME="${JAVA_HOME:-$HOME/dev/jdk}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/dev/android-sdk}"
export PATH="$HOME/dev/flutter/bin:$JAVA_HOME/bin:$PATH"

flutter build apk --release

OUT_DIR="build/app/outputs/flutter-apk"
cp "$OUT_DIR/app-release.apk" "$OUT_DIR/claude-ssh-release.apk"
echo "APK: $PWD/$OUT_DIR/claude-ssh-release.apk"
