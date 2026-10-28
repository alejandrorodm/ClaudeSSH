#!/usr/bin/env bash
# Builds the release APK and names it claude-ssh-release.apk.
set -euo pipefail

cd "$(dirname "$0")/.."

export JAVA_HOME="${JAVA_HOME:-$HOME/dev/jdk}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/dev/android-sdk}"
export PATH="$HOME/dev/flutter/bin:$JAVA_HOME/bin:$PATH"

# BUILD_NAME/BUILD_NUMBER, when set (CI sets them from the git tag for a
# versioned release), override pubspec.yaml's version for this build only,
# so the APK's version always matches the tag it was built from instead of
# drifting from a manually-bumped pubspec.
BUILD_ARGS=()
if [[ -n "${BUILD_NAME:-}" ]]; then
  BUILD_ARGS+=(--build-name="$BUILD_NAME")
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  BUILD_ARGS+=(--build-number="$BUILD_NUMBER")
fi

flutter build apk --release "${BUILD_ARGS[@]}"

OUT_DIR="build/app/outputs/flutter-apk"
cp "$OUT_DIR/app-release.apk" "$OUT_DIR/claude-ssh-release.apk"
echo "APK: $PWD/$OUT_DIR/claude-ssh-release.apk"
