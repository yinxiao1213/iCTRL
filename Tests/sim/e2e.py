#!/usr/bin/env python3
"""End-to-end checks in the iOS Simulator, through the real runner and app.

    Tests/sim/e2e.py engine OUT_DIR    the script engine, driven over RPC
    Tests/sim/e2e.py app OUT_DIR       the app, driven like a person would

The screenshots land in OUT_DIR. Started by Tests/sim/run.sh.
"""
import base64
import json
import os
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
    time.sleep(1)
    front = call("foreground_app")
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
    call("launch_app", {"bundle_id": APP})
    check("the setup list shows", find("準備", 40, APP) is not None)
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

    press("點文字")
    time.sleep(6)
    shot("app-7-text-mode")
    target = find_text(["About"])
    if not check("the picture shows the General page", target is not None):
        raise SystemExit(1)
    call("tap", {"x": target["center_x"], "y": target["center_y"]})
    check("recorded the text tap", find("已錄 3 步", 60, APP) is not None)
    time.sleep(3)
    shot("app-8-about")

    press("完成")
    time.sleep(1)
    shot("app-9-steps")

    press("執行", exact=True)
    time.sleep(2)
    done = status_wait(90)
    check("the recorded script played", done.get("state") == "finished", json.dumps(done, ensure_ascii=False))
    time.sleep(1)
    shot("app-10-after-run")
    check("the replay reached the same page", find_text(["iOS Version", "Model Name", "Software Version", "Name"]) is not None)
    call("launch_app", {"bundle_id": APP})
    time.sleep(2)
    shot("app-11-back")


def main():
    mode = sys.argv[1]
    os.makedirs(OUT, exist_ok=True)
    try:
        (engine if mode == "engine" else app)()
    except SystemExit as e:
        log("stopped:", e)
        results.append(False)
    except Exception as e:  # noqa: BLE001
        log("crashed:", repr(e))
        results.append(False)
    log(f"{sum(results)} / {len(results)} passed ({mode})")
    sys.exit(0 if results and all(results) else 1)


main()
