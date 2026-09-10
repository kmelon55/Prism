#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/prism-dictation-overlay.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
native_arch=$(uname -m)
xcrun swiftc -parse-as-library -target "$native_arch-apple-macosx14.0" \
  "$repo_root"/apps/desktop/src-tauri/native/dictation/*.swift \
  "$repo_root/apps/desktop/src-tauri/native/tests/DictationOverlayCheck.swift" \
  -o "$test_dir/dictation-overlay-check"
"$test_dir/dictation-overlay-check" "${1:-$test_dir/waveform.png}"
