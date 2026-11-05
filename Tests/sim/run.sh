#!/bin/bash
# Boot a simulator, then run Tests/sim/e2e.py against the real runner and app.
# Expects a `build-for-testing` in build-sim/.
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-sim-out}"
mkdir -p "$OUT"
PRODUCTS=build-sim/Build/Products/Debug-iphonesimulator

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
runtimes = sorted((r for r in devices if "iOS-27" in r), reverse=True)
phones = [d for r in runtimes for d in devices[r] if d["name"].startswith("iPhone")]
plain = [d for d in phones if d["name"].split()[-1].isdigit()]
print((plain or phones)[0]["udid"], (plain or phones)[0]["name"], file=sys.stdout)
')"
echo "simulator: $UDID"
UDID="${UDID%% *}"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$PRODUCTS/iCTRL.app"

RUNNER=""
start_runner() {
    # Armed for one pairing per start: e2e.py pairs itself in the first run and
    # the app pairs in the second, which is why there are two.
    TEST_RUNNER_ICTRL_ALLOW_AUTH_ONCE=1 xcodebuild test-without-building \
        -project iCTRL.xcodeproj -scheme iCTRL -destination "id=$UDID" \
        -derivedDataPath build-sim \
        -only-testing:iCTRLUITests/iCTRLUITests/testStartServer \
        > "$OUT/runner-$1.log" 2>&1 &
    RUNNER=$!
}
stop_runner() {
    kill "$RUNNER" 2>/dev/null
    wait "$RUNNER" 2>/dev/null
    xcrun simctl terminate "$UDID" com.openminis.ictrl.uitests.xctrunner 2>/dev/null
    sleep 4
}

start_runner 1
python3 Tests/sim/e2e.py engine "$OUT" 2>&1 | tee "$OUT/engine.txt"
ENGINE=${PIPESTATUS[0]}
stop_runner

start_runner 2
python3 Tests/sim/e2e.py app "$OUT" 2>&1 | tee "$OUT/app.txt"
APP=${PIPESTATUS[0]}
stop_runner

xcrun simctl io "$UDID" screenshot "$OUT/final.png" 2>/dev/null
echo "engine=$ENGINE app=$APP"
[ "$ENGINE" = 0 ] && [ "$APP" = 0 ]
