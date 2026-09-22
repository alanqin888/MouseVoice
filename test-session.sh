#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mousevoice-session.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
sed '/^if CommandLine.arguments.contains("--diagnose") {/,$d' Sources/main.swift > "$TEST_DIR/main.swift"
cat Tests/session-resume.swift >> "$TEST_DIR/main.swift"
xcrun swiftc -swift-version 5 -framework AppKit -framework CoreGraphics -framework ApplicationServices Sources/HoldDetector.swift Sources/KeyOutput.swift "$TEST_DIR/main.swift" -o "$TEST_DIR/SessionTests"
"$TEST_DIR/SessionTests"
