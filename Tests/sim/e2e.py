#!/usr/bin/env python3
"""End-to-end checks in the iOS Simulator, through the real runner and app.

    Tests/sim/e2e.py engine OUT_DIR    the script engine, driven over RPC
    Tests/sim/e2e.py app OUT_DIR       the app, driven like a person would
    Tests/sim/e2e.py location OUT_DIR  虛擬定位: the screen, and staying alive behind another app

The screenshots land in OUT_DIR. Started by Tests/sim/run.sh.
"""
import base64
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "Scripts"))
import ictrl_rpc as rpc  # noqa: E402

HOST = "127.0.0.1:8200"
KEY = "ci"
APP = "com.openminis.ictrl"
SETTINGS = "com.apple.Preferences"
OUT = sys.argv[2]
results = []


def log(*parts):
    print(*parts, flush=True)


def check(name, ok, detail=""):
    results.append(bool(ok))
    log(("ok   " if ok else "FAIL ") + name + (f"  -> {detail}" if detail != "" else ""))
    return ok


def call(method, params=None, timeout=40):
    reply = rpc.call(HOST, method, params, timeout=timeout, store_key=KEY)
    if "error" in reply:
        raise RuntimeError(f"{method}: {reply['error'].get('message')}")
    return reply.get("result", {})


def try_call(method, params=None, timeout=40):
    try:
        return call(method, params, timeout)
    except (RuntimeError, SystemExit, OSError) as e:
        log("  (", method, "failed:", str(e)[:200], ")")
        return None


def shot(name):
    result = try_call("screenshot", {"format": "jpeg", "quality": 0.7})
    if result and result.get("data"):
        with open(os.path.join(OUT, name + ".jpg"), "wb") as f:
            f.write(base64.b64decode(result["data"]))
    log("  shot", name)


def wait_server():
    end = time.time() + 240
    while time.time() < end:
        try:
            with urllib.request.urlopen(f"http://{HOST}/schema", timeout=2) as r:
                if r.status == 200:
                    return True
        except OSError:
            pass
        time.sleep(1)
    return False


def dismiss_alerts():
    """The notification prompt, the first time the runner starts."""
    for label in ("Allow", "允許"):
        found = try_call("find_element", {"element_id": label, "bundle_id": "com.apple.springboard"})
        if found and found.get("ref"):
            try_call("tap", {"ref": found["ref"]})
            log("  answered an alert:", label)
            time.sleep(1)


def status_wait(limit=60):
    end = time.time() + limit
    last = {}
    while time.time() < end:
        last = call("script_status")
        if last.get("state") not in ("running", "stopping"):
            return last
        time.sleep(0.5)
    return last


def texts():
    result = try_call("screen_text") or {}
    return result.get("items", [])


def find_text(words):
    for item in texts():
        if any(w.lower() in item.get("label", "").lower() for w in words):
            return item
    return None


def engine():
    check("runner came up", wait_server())
    rpc.pair(HOST, "ci", False, store_key=KEY)
    log("paired")
    time.sleep(3)
    dismiss_alerts()
    info = call("device_info")
    log("device", json.dumps({k: info.get(k) for k in ("model", "system_version", "os_version", "point_width",
                                                       "point_height", "server_version")}, ensure_ascii=False))

    steps = [
        {"kind": "open_app", "bundle_id": SETTINGS},
        {"kind": "wait_text", "text": "General", "timeout": 20},
        {"kind": "tap_text", "text": "General", "timeout": 10},
        {"kind": "wait_text", "text": "About", "timeout": 20},
    ]
    call("script_run", {"steps": steps, "name": "e2e"})
    done = status_wait()
    check("script finished", done.get("state") == "finished", json.dumps(done, ensure_ascii=False))
    shot("engine-1-general")
    check("the screen really changed", find_text(["About"]) is not None)

    steps = [
        {"kind": "if_text", "text": "No such words anywhere", "timeout": 0, "skip": 1},
        {"kind": "tap_text", "text": "About", "timeout": 5},
        {"kind": "wait", "duration": 1},
    ]
    call("script_run", {"steps": steps, "name": "skip"})
    done = status_wait()
    check("if_text skipped the tap", done.get("state") == "finished", done)
    check("the tap did not happen", find_text(["About"]) is not None)

    steps = [{"kind": "wait_text", "text": "No such words anywhere", "timeout": 2}]
    call("script_run", {"steps": steps, "name": "fail"})
    done = status_wait()
    check("a missing text fails", done.get("state") == "failed" and "第 1 步" in done.get("error", ""),
          json.dumps(done, ensure_ascii=False))

    call("script_run", {"steps": [{"kind": "wait", "duration": 60}], "name": "stop", "loops": 0})
    time.sleep(1.5)
    call("script_stop")
    done = status_wait(10)
    check("stop works", done.get("state") == "stopped", done)

    # One recording round, with Safari standing in for the app that asked.
    started = call("rec_step", {"bundle_id": SETTINGS, "return_bundle_id": "com.apple.mobilesafari",
                                "step": {"kind": "home"}})
    job = started["job_id"]
    end = time.time() + 40
    result = {}
    while time.time() < end:
        result = call("rec_result", {"job_id": job})
        if result.get("state") == "done":
            break
        time.sleep(0.5)
    check("recording round finished", result.get("state") == "done", {k: v for k, v in result.items() if k != "data"})
    check("round brought a picture", len(result.get("data", "")) > 1000)
    check("round brought its size", result.get("point_width", 0) > 0)
    # Safari starts cold here, which takes a CI machine a while.
    end = time.time() + 30
    front = {}
    while time.time() < end and front.get("bundle_id") != "com.apple.mobilesafari":
        time.sleep(1)
        front = try_call("foreground_app") or {}
    check("round went back to the caller", front.get("bundle_id") == "com.apple.mobilesafari", front)
    shot("engine-2-after-round")
    try_call("home")


def find(label, timeout=15, bundle=None, exact=False):
    """An element of the app in front, by label, or None."""
    end = time.time() + timeout
    params = {"element_id": label, "match": "exact" if exact else "contains"}
    if bundle:
        params["bundle_id"] = bundle
    while time.time() < end:
        result = try_call("find_element", params)
        if result and result.get("ref"):
            return result
        time.sleep(0.7)
    return None


def press(label, timeout=15, bundle=APP, exact=False):
    found = find(label, timeout, bundle, exact)
    if not check(f"found 「{label}」", found is not None):
        shot("missing-" + label)
        raise SystemExit(1)
    call("tap", {"ref": found["ref"]})
    time.sleep(1)


def app():
    check("runner came up again", wait_server())
    time.sleep(3)
    dismiss_alerts()
    # A timeout here only means the reply came first; the launch goes on.
    try_call("launch_app", {"bundle_id": APP})
    check("the setup list shows", find("準備", 60, APP) is not None)
    time.sleep(2)
    shot("app-1-setup")

    press("連接", exact=True)
    time.sleep(3)
    shot("app-2-connected")
    check("setup is done", find("連接 App 和服務", 3, APP) is None)

    press("新增腳本")
    time.sleep(1)
    shot("app-3-editor")
    press("開始錄製")
    time.sleep(2)
    shot("app-4-picker")
    press("com.apple.Preferences")

    if not check("came back from Settings with a picture", find("已錄 1 步", 60, APP) is not None):
        shot("app-5-failed")
        raise SystemExit(1)
    time.sleep(3)
    shot("app-5-recorder")

    target = find_text(["General"])
    if target is None:
        # What a person would do with a page that was still loading.
        press("重新截圖")
        time.sleep(25)
        shot("app-5-recorder-again")
        target = find_text(["General"])
    if not check("the picture shows Settings", target is not None):
        raise SystemExit(1)
    call("tap", {"x": target["center_x"], "y": target["center_y"]})
    check("recorded the tap", find("已錄 2 步", 60, APP) is not None)
    time.sleep(3)
    shot("app-6-after-tap")

    # Wait for this text before going on; nothing moves on the phone.
    press("等文字", exact=True)
    time.sleep(6)
    shot("app-7-text-mode")
    target = find_text(["About"])
    if not check("the picture shows the General page", target is not None):
        raise SystemExit(1)
    call("tap", {"x": target["center_x"], "y": target["center_y"]})
    check("recorded the wait", find("已錄 3 步", 15, APP) is not None)

    press("點文字", exact=True)
    time.sleep(1)
    call("tap", {"x": target["center_x"], "y": target["center_y"]})
    check("recorded the text tap", find("已錄 4 步", 60, APP) is not None)
    time.sleep(6)
    shot("app-8-about")

    # Only if this page says so, do the next step.
    press("看到才做", exact=True)
    time.sleep(1)
    target = find_text(["Model Name"])
    if not check("the picture shows the About page", target is not None):
        raise SystemExit(1)
    call("tap", {"x": target["center_x"], "y": target["center_y"]})
    check("recorded the condition", find("已錄 5 步", 15, APP) is not None)

    # A swipe on the picture is a swipe on the phone.
    middle = target["center_x"]
    call("drag", {"from_x": middle, "from_y": 500, "to_x": middle, "to_y": 250, "duration": 0.4})
    check("recorded the swipe", find("已錄 6 步", 60, APP) is not None)
    time.sleep(3)
    shot("app-8b-swiped")

    press("完成")
    time.sleep(1)
    shot("app-9-steps")
    for words in ("從頭打開「設定」", "點「General」", "等畫面出現「About」", "點畫面上的「About」", "看到「Model Name」才做下面 1 步", "滑動"):
        check(f"the list says {words}", find(words, 8, APP) is not None)

    press("執行", exact=True)
    time.sleep(2)
    done = status_wait(90)
    check("the recorded script played", done.get("state") == "finished", json.dumps(done, ensure_ascii=False))
    time.sleep(1)
    shot("app-10-after-run")
    check("the replay reached the same page and scrolled it", find_text(["Available", "Capacity", "Certificate"]) is not None)
    try_call("launch_app", {"bundle_id": APP})
    check("back in the app, it shows how the run went", find("跑完了", 40, APP) is not None)
    shot("app-11-back")


# ---------------------------------------------------------------- 虛擬定位

def app_log_lines():
    """Every line the app has logged, oldest run first (read off the simulator's disk)."""
    try:
        data = subprocess.check_output(["xcrun", "simctl", "get_app_container", "booted", APP, "data"],
                                       text=True, stderr=subprocess.DEVNULL).strip()
    except (subprocess.CalledProcessError, OSError):
        return []
    lines = []
    for path in sorted(glob.glob(os.path.join(data, "Library", "Logs", "iCTRL", "*.log")), key=os.path.getmtime):
        with open(path, encoding="utf-8", errors="replace") as f:
            lines += f.read().splitlines()
    return lines


SET_LINE = re.compile(r"\[(\d\d):(\d\d):(\d\d)\.(\d+)\] .*\[sim\] set #\d+ (-?[\d.]+), (-?[\d.]+)")


def sends():
    """(seconds since midnight, lat, lon) for every point the app handed to the (stand-in) phone."""
    out = []
    for line in app_log_lines():
        m = SET_LINE.match(line)
        if m:
            h, mi, sec, frac = m.group(1), m.group(2), m.group(3), m.group(4)
            out.append((int(h) * 3600 + int(mi) * 60 + int(sec) + float("0." + frac),
                        float(m.group(5)), float(m.group(6))))
    return out


def now_of_day():
    n = datetime.datetime.now()
    return n.hour * 3600 + n.minute * 60 + n.second + n.microsecond / 1e6


def set_keepalive(on):
    press("保活設定", exact=True)
    time.sleep(1)
    word = "開" if on else "關"
    for name in ("背景音訊", "背景定位"):
        if find(f"{name}：{word}", 2, APP, exact=True) is None:
            press(name)
            time.sleep(0.7)
        check(f"{name} is {word}", find(f"{name}：{word}", 5, APP, exact=True) is not None)
    shot("loc-keepalive-" + ("on" if on else "off"))
    press("完成", exact=True)
    time.sleep(1)


def sends_behind(seconds, label):
    """Put Settings in front for a while; count the points the app sent meanwhile."""
    try_call("launch_app", {"bundle_id": SETTINGS})
    end = time.time() + 30
    front = {}
    nudged = False
    while time.time() < end and front.get("bundle_id") != SETTINGS:
        time.sleep(1)
        front = try_call("foreground_app") or {}
        # Settings starting cold on a slow CI machine can outlast launch_app;
        # the simulator itself can still bring it up.
        if not nudged and front.get("bundle_id") != SETTINGS and time.time() > end - 22:
            nudged = True
            subprocess.run(["xcrun", "simctl", "launch", "booted", SETTINGS],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    check(f"Settings is in front ({label})", front.get("bundle_id") == SETTINGS, front)
    time.sleep(8)   # past the few seconds iOS gives any app that just left
    start = now_of_day()
    time.sleep(seconds)
    stop = now_of_day()
    count = len([s for s in sends() if start <= s[0] <= stop])
    log(f"  {label}: {count} points sent in {seconds} s with Settings in front")
    try_call("launch_app", {"bundle_id": APP})
    time.sleep(3)
    return count


def location():
    check("runner came up for the location test", wait_server())
    time.sleep(3)
    dismiss_alerts()
    try_call("launch_app", {"bundle_id": APP})
    for label in ("Allow While Using App", "使用 App 期間允許"):
        found = try_call("find_element", {"element_id": label, "bundle_id": "com.apple.springboard"})
        if found and found.get("ref"):
            try_call("tap", {"ref": found["ref"]})
    press("定位", 60, exact=True)
    time.sleep(3)
    shot("loc-1-tab")
    check("starts on the real location", find("真實定位", 10, APP, exact=True) is not None)
    check("says it is the simulator", find("模擬器測試模式", 5, APP) is not None)

    # Straight lines: a directions lookup on a CI machine is not what is tested here.
    if find("沿道路", 3, APP, exact=True):
        press("沿道路", exact=True)
    check("walks in straight lines", find("走直線", 5, APP, exact=True) is not None)

    info = call("device_info")
    w = info.get("point_width") or 402
    h = info.get("point_height") or 874
    call("tap", {"x": w / 2, "y": h * 0.42})
    time.sleep(1.5)
    check("a tap on the map picks a target", find("目標 2", 8, APP) is not None)
    shot("loc-2-target")

    press("瞬移", exact=True)
    check("teleport shows the fake location", find("假定位中", 20, APP, exact=True) is not None)
    time.sleep(2)
    shot("loc-3-fake")
    first = sends()
    check("the point reached the phone side", len(first) >= 1, len(first))

    # Standing still it re-sends every 4 s: that keeps the channel checked.
    time.sleep(9)
    check("standing still re-sends", len(sends()) - len(first) >= 2, len(sends()) - len(first))

    # The question that matters: does it keep going behind another app?
    # First without keep-alive, to see that the simulator does pause it at all.
    set_keepalive(False)
    paused = sends_behind(30, "keep-alive off")
    set_keepalive(True)
    kept = sends_behind(40, "keep-alive on")
    check("with keep-alive on it keeps sending behind another app (every 4 s)", kept >= 8, kept)
    if paused <= 2:
        log(f"note: without keep-alive the app was paused ({paused} sends) — so the {kept} above are keep-alive's doing")
    else:
        log(f"note: without keep-alive it still sent {paused} times — the simulator did not pause it, "
            f"so this run does not prove keep-alive on its own")
    check("still fake after coming back", find("假定位中", 10, APP, exact=True) is not None)
    shot("loc-4-back")

    # Walk to a point a little way off.
    call("tap", {"x": w / 2 + 70, "y": h * 0.42 - 50})
    time.sleep(1)
    before = len(sends())
    press("走過去", exact=True)
    check("walking says how far is left", find("步行中", 10, APP) is not None)
    time.sleep(6)
    shot("loc-5-walking")
    walked = sends()[before:]
    check("walking sends a point every second", len(walked) >= 4, len(walked))
    if len(walked) >= 2:
        a, b = walked[0], walked[-1]
        check("and the points move", (a[1], a[2]) != (b[1], b[2]), (a, b))
    press("停下", exact=True)
    check("stop stands still", find("停在", 10, APP) is not None)

    # The joystick moves it too.
    press("搖桿", exact=True)
    time.sleep(1)
    pad = find("搖桿圓盤", 5, APP, exact=True)
    if check("the joystick shows", pad is not None):
        before = len(sends())
        x, y = pad["center_x"], pad["center_y"]
        call("drag", {"from_x": x, "from_y": y, "to_x": x, "to_y": y - 50, "duration": 3})
        time.sleep(1)
        moved = sends()[before:]
        check("pushing the joystick sends points", len(moved) >= 2, len(moved))
        if len(moved) >= 2:
            check("pushing up goes north", moved[-1][1] > moved[0][1], (moved[0], moved[-1]))
    shot("loc-6-joystick")
    press("搖桿", exact=True)

    # Favorites.
    press("收藏這裡", exact=True)
    time.sleep(1)
    press("儲存", exact=True)
    press("收藏清單", exact=True)
    check("the favorite is listed", find("收藏 1", 8, APP, exact=True) is not None)
    shot("loc-7-favorites")
    press("完成", exact=True)

    press("恢復真實定位", exact=True)
    check("restore goes back to the real location", find("真實定位", 10, APP, exact=True) is not None)
    time.sleep(1)
    check("and closes the channel", any("[sim] clear" in line for line in app_log_lines()))
    count = len(sends())
    time.sleep(6)
    check("nothing is sent after that", len(sends()) == count, len(sends()) - count)
    shot("loc-8-restored")


def main():
    mode = sys.argv[1]
    os.makedirs(OUT, exist_ok=True)
    try:
        {"engine": engine, "app": app, "location": location}[mode]()
    except SystemExit as e:
        log("stopped:", e)
        results.append(False)
    except Exception as e:  # noqa: BLE001
        log("crashed:", repr(e))
        results.append(False)
    log(f"{sum(results)} / {len(results)} passed ({mode})")
    sys.exit(0 if results and all(results) else 1)


main()
