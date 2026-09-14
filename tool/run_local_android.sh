#!/usr/bin/env bash
set -euo pipefail

# Forward the device's loopback port before starting the debug app.
mobile_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
device_id="${1:-emulator-5554}"
if [[ $# -gt 0 ]]; then shift; fi
curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8080/health/ready >/dev/null
adb -s "$device_id" reverse tcp:8080 tcp:8080
cd "$mobile_root"
exec flutter run -d "$device_id" "$@"
