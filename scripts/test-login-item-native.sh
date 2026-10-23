#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/prism-login-item-check.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  "$repo_root/apps/desktop/src-tauri/native/login-item/LoginItem.swift" \
  "$repo_root/apps/desktop/src-tauri/native/tests/LoginItemTests.swift" \
  -o "$test_dir/login-item-tests"
"$test_dir/login-item-tests"
