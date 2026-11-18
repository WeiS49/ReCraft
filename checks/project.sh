#!/usr/bin/env bash
# This project's own lint and test commands. Owned by the project: edit freely.
#
# Runs the full offline XCTest suite and a Release build with ad-hoc signing,
# so it needs no developer certificate, Keychain item, network or API budget.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ReCraft is a macOS app: ./check needs macOS with Xcode (xcodebuild) installed." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/.build/check-derived"
LOGS="$ROOT/.build/check-logs"
mkdir -p "$LOGS"

SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)

echo "check: running XCTest suite (log: .build/check-logs/test.log)"
if ! xcodebuild test \
       -project "$ROOT/ReCraft.xcodeproj" -scheme ReCraft -configuration Debug \
       -destination 'platform=macOS,arch=arm64' \
       -derivedDataPath "$DERIVED" \
       -parallel-testing-enabled NO -collect-test-diagnostics never \
       "${SIGNING[@]}" > "$LOGS/test.log" 2>&1; then
  grep -E "error:|: error |failed \(|TEST FAILED|Test Case .* failed" "$LOGS/test.log" | sort -u | tail -40 >&2 || true
  echo "check: tests failed. Fix the code; full log in .build/check-logs/test.log" >&2
  exit 1
fi

summary="$(grep -E "Executed [0-9]+ tests" "$LOGS/test.log" | tail -1 || true)"
executed="$(sed -E 's/.*Executed ([0-9]+) tests.*/\1/' <<<"$summary")"
if [ -z "$summary" ] || [ "${executed:-0}" -lt 100 ]; then
  echo "check: expected the full suite (100+ tests) but saw: ${summary:-no summary}." >&2
  echo "A run that executes fewer tests is not a pass; restore the missing tests." >&2
  exit 1
fi
echo "check: $(sed -E 's/^[[:space:]]+//' <<<"$summary")"

echo "check: building Release (log: .build/check-logs/release.log)"
if ! xcodebuild build \
       -project "$ROOT/ReCraft.xcodeproj" -scheme ReCraft -configuration Release \
       -destination 'platform=macOS,arch=arm64' \
       -derivedDataPath "$DERIVED" \
       "${SIGNING[@]}" > "$LOGS/release.log" 2>&1; then
  grep -E "error:|: error " "$LOGS/release.log" | sort -u | tail -40 >&2 || true
  echo "check: Release build failed. Full log in .build/check-logs/release.log" >&2
  exit 1
fi

BINARY="$DERIVED/Build/Products/Release/ReCraft.app/Contents/MacOS/ReCraft"
if strings "$BINARY" | grep -qE "debug-post-hotkey|focus-probe-output|TestHooks"; then
  echo "check: Debug-only diagnostics leaked into the Release binary. Keep them inside #if DEBUG." >&2
  exit 1
fi
if [ -d "$(dirname "$BINARY")/../PlugIns" ] && ls "$(dirname "$BINARY")/../PlugIns" | grep -q xctest; then
  echo "check: the Release app embeds an XCTest bundle; it must not." >&2
  exit 1
fi
echo "check: Release build ok, no Debug-only diagnostics in the binary"
