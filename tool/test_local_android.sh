#!/usr/bin/env bash
set -euo pipefail

mobile_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
device_id="${1:-emulator-5554}"
if (( $# > 0 )); then shift; fi
cd "$mobile_root"
curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8080/health/ready >/dev/null
adb -s "$device_id" reverse tcp:8080 tcp:8080
pnpm --dir "$mobile_root/../packages/agents/opencode" build
node "$mobile_root/../packages/agents/opencode/test/support/mobile-chat-server.mjs" &
chat_fixture_pid=$!
trap 'kill "$chat_fixture_pid" 2>/dev/null || true; wait "$chat_fixture_pid" 2>/dev/null || true' EXIT
for attempt in {1..50}; do
  if curl --fail --silent --max-time 1 http://127.0.0.1:8092/ready >/dev/null; then break; fi
  sleep 0.1
done
curl --fail --silent --show-error --max-time 2 http://127.0.0.1:8092/ready >/dev/null
adb -s "$device_id" reverse tcp:8092 tcp:8092

# Both protections are necessary: a separate package isolates Keystore/data,
# and --no-uninstall prevents Flutter cleanup from acting on a cached APK ID.
export ORG_GRADLE_PROJECT_openremotecodeIntegration=true
# Extra Flutter arguments (for example --dart-define=MCP_VISUAL_PAUSE_SECONDS=30)
# must reach both compilation and the native test runner.
flutter build apk --debug --target integration_test/local_auth_test.dart "$@"
flutter test integration_test/local_auth_test.dart -d "$device_id" "$@" --no-uninstall
