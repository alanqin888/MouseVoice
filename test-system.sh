#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mousevoice-system-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# Reuse the production delegate unchanged, replacing only the executable entry point.
sed '/^if CommandLine.arguments.contains("--diagnose") {/,$d' Sources/main.swift > "$TEST_DIR/main.swift"
cat Tests/system-events.swift >> "$TEST_DIR/main.swift"
xcrun swiftc -swift-version 5 -framework AppKit -framework CoreGraphics -framework ApplicationServices \
  Sources/HoldDetector.swift Sources/KeyOutput.swift "$TEST_DIR/main.swift" -o "$TEST_DIR/MouseIntegration"
"$TEST_DIR/MouseIntegration"
