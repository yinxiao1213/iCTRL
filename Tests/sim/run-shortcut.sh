#!/bin/bash
# 開模擬器、啟動 runner，再跑 Tests/sim/shortcut_e2e.py。
# 需要 build-sim/ 裡已有 build-for-testing 的結果。
#   run-shortcut.sh 捷徑網址前綴 輸出資料夾
set -uo pipefail
cd "$(dirname "$0")/../.."
BASE="$1"
OUT="${2:-sim-out}"
mkdir -p "$OUT"
PRODUCTS=build-sim/Build/Products/Debug-iphonesimulator

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
runtimes = sorted((r for r in devices if "iOS-27" in r), reverse=True)
phones = [d for r in runtimes for d in devices[r] if d["name"].startswith("iPhone")]
plain = [d for d in phones if d["name"].split()[-1].isdigit()]
print((plain or phones)[0]["udid"])
')"
echo "simulator: $UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$PRODUCTS/iCTRL.app"
# 模擬器有沒有捷徑 App，先留下紀錄，失敗時才知道要往哪查。
xcrun simctl listapps "$UDID" 2>/dev/null | grep -i -c 'com.apple.shortcuts' | sed 's/^/shortcuts app entries: /'
xcrun simctl privacy "$UDID" grant photos com.apple.shortcuts || true
xcrun simctl privacy "$UDID" grant photos-add com.apple.shortcuts || true

TEST_RUNNER_ICTRL_ALLOW_AUTH_ONCE=1 xcodebuild test-without-building \
    -project iCTRL.xcodeproj -scheme iCTRL -destination "id=$UDID" \
    -derivedDataPath build-sim \
    -only-testing:iCTRLUITests/iCTRLUITests/testStartServer \
    > "$OUT/runner.log" 2>&1 &
RUNNER=$!

# 長按連結測 URL 物件要用的測試頁。
python3 -m http.server 8765 --bind 127.0.0.1 --directory threads-saver/testpage > /dev/null 2>&1 &
HTTP=$!

python3 Tests/sim/shortcut_e2e.py "$UDID" "$BASE" "$OUT" 2>&1 | tee "$OUT/e2e.txt"
RESULT=${PIPESTATUS[0]}

# 捷徑 App 的系統記錄：匯入被拒的原因只會出現在這裡。
# log show 在模擬器上可能跑很久，最多等 2 分鐘，只留已經讀到的部分。
python3 - "$UDID" "$OUT/shortcuts-log.txt" <<'PY'
import subprocess, sys
udid, out = sys.argv[1:3]
predicate = 'process == "Shortcuts" OR process == "siriactionsd" OR subsystem BEGINSWITH "com.apple.shortcuts"'
with open(out, "wb") as f:
    try:
        subprocess.run(["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "15m", "--style", "compact",
                        "--predicate", predicate], stdout=f, stderr=subprocess.DEVNULL, timeout=120)
    except subprocess.TimeoutExpired:
        print("log show 逾時，只留下已讀到的部分")
PY

kill -9 "$RUNNER" "$HTTP" 2>/dev/null
xcrun simctl io "$UDID" screenshot "$OUT/final.png" 2>/dev/null
echo "e2e=$RESULT"
exit "$RESULT"
