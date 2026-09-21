#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mousevoice-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 5 -framework AppKit -framework CoreGraphics \
  Sources/HoldDetector.swift Sources/KeyOutput.swift Tests/main.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
