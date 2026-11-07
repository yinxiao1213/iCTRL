#!/usr/bin/env python3
"""在 iOS 模擬器的捷徑 App 裡，實際匯入並執行 Threads 保存捷徑。

    Tests/sim/shortcut_e2e.py UDID 捷徑網址前綴 OUT_DIR

靠 runner 看畫面、按按鈕，再直接看模擬器相簿的資料夾，確認檔案真的存進去。
捷徑怎麼把網頁變回原始 HTML 只有實際跑才知道，所以三種寫法依序試，
第一個全部通過的寫進 OUT_DIR/winner.txt。由 Tests/sim/run-shortcut.sh 啟動。
"""
import base64
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "Scripts"))
import ictrl_rpc as rpc  # noqa: E402

HOST = "127.0.0.1:8200"
KEY = "ci"
SHORTCUTS = "com.apple.shortcuts"
UDID, BASE, OUT = sys.argv[1:4]
MODES = ("rename", "base64", "direct")

VIDEO = ("video", "https://www.threads.com/@rottentomatoes/post/DQP4mmZD_0S?xmt=AQG0abc&slof=1", {"mp4": 1})
GIF = ("gif", "https://www.threads.com/@giphy/post/DFmKJ4zMWMv", {"gif": 1})
REPLY = ("reply", "https://www.threads.com/@pamplemousse_and_circumstances/post/DXieIOeDRO3", {"gif": 1})
PHOTOS = ("photos-only", "https://www.threads.com/@gif_names_finding/post/DU6V-sPExs6", {})

# 畫面上出現就按。順序就是優先序；「Allow」要完全相符，才不會按到 Don't Allow。
ANSWERS = ("Always Allow", "Allow Full Access", "Allow Access", "Allow", "Allow Once", "Add Shortcut",
           "Continue", "Get Started", "Not Now", "OK", "Done")


def log(*parts):
    print(*parts, flush=True)


def try_call(method, params=None, timeout=40):
    try:
        reply = rpc.call(HOST, method, params, timeout=timeout, store_key=KEY)
    except (SystemExit, OSError, RuntimeError) as e:
        log("  (", method, "失敗:", str(e)[:200], ")")
        return None
    if "error" in reply:
        log("  (", method, "失敗:", str(reply["error"].get("message"))[:200], ")")
        return None
    return reply.get("result", {})


def shot(name):
    result = try_call("screenshot", {"format": "jpeg", "quality": 0.7})
    if result and result.get("data"):
        with open(os.path.join(OUT, name + ".jpg"), "wb") as f:
            f.write(base64.b64decode(result["data"]))


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


def open_url(url):
    done = subprocess.run(["xcrun", "simctl", "openurl", UDID, url], capture_output=True, text=True, timeout=60)
    log("  openurl", url[:110], "結束碼", done.returncode, done.stderr.strip()[:200])


def labels():
    return (try_call("screen_text") or {}).get("items", [])


def answer():
    """按掉畫面上的一個問題，回傳按了什麼。"""
    items = labels()
    for want in ANSWERS:
        for item in items:
            label = item.get("label", "").strip()
            if label.lower() == want.lower() or (want == "Always Allow" and want in label):
                if try_call("tap", {"x": item["center_x"], "y": item["center_y"]}) is not None:
                    log("  按了", want)
                    return want
    return None


def album():
    root = os.path.expanduser(f"~/Library/Developer/CoreSimulator/Devices/{UDID}/data/Media/DCIM")
    found = {}
    for folder, _, names in os.walk(root):
        for name in names:
            path = os.path.join(folder, name)
            found[path] = os.path.getsize(path)
    return found


def kind(path):
    with open(path, "rb") as f:
        head = f.read(12)
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    if head[4:8] == b"ftyp":
        return "mp4"
    return "other:" + os.path.basename(path)


def add_shortcut(mode):
    """回傳是否按到了 Add Shortcut。"""
    log("匯入", mode)
    name = f"TS {mode}"
    url = f"{BASE}/ts-{mode}.shortcut"
    open_url("shortcuts://import-shortcut?url=" + urllib.parse.quote(url, safe="") + "&name=" + urllib.parse.quote(name))
    end = time.time() + 75
    added = False
    round_no = 0
    while time.time() < end:
        time.sleep(2)
        round_no += 1
        if round_no % 5 == 1:
            shot(f"import-{mode}-{round_no}")
            log("  畫面:", [i.get("label") for i in labels()][:16])
        pressed = answer()
        added = added or pressed == "Add Shortcut"
        if added and pressed is None:
            break
    shot(f"import-{mode}-end")
    log("  已加入" if added else "  沒看到 Add Shortcut")
    return added


def run_case(mode, case):
    name, link, expected = case
    before = album()
    total = sum(expected.values())
    log("執行", mode, name)
    open_url("shortcuts://run-shortcut?name=" + urllib.parse.quote(f"TS {mode}") + "&input=text&text="
             + urllib.parse.quote(link, safe=""))
    end = time.time() + 70
    settled = 0
    round_no = 0
    while time.time() < end:
        time.sleep(2)
        round_no += 1
        pressed = answer()
        new = set(album()) - set(before)
        if round_no == 3 or round_no % 8 == 0:
            shot(f"run-{mode}-{name}-{round_no}")
            log("  畫面:", [i.get("label") for i in labels()][:12], "新檔案", len(new))
        settled = settled + 1 if (len(new) >= total and pressed is None) else 0
        # 沒有預期檔案的情況要多等一下，確認真的沒有多存。
        if settled >= (8 if total == 0 else 3):
            break
    shot(f"run-{mode}-{name}-end")
    new = sorted(set(album()) - set(before))
    kinds = [kind(p) for p in new]
    got = {k: kinds.count(k) for k in set(kinds)}
    ok = got == expected
    log(("ok   " if ok else "FAIL ") + f"{mode} {name}: 預期 {expected}，實際 {got}",
        [album()[p] // 1024 for p in new], "KB")
    subprocess.run(["xcrun", "simctl", "terminate", UDID, SHORTCUTS], capture_output=True, timeout=30)
    time.sleep(2)
    return ok


def main():
    os.makedirs(OUT, exist_ok=True)
    if not wait_server():
        log("runner 沒有起來")
        return 1
    rpc.pair(HOST, "ci", False, store_key=KEY)
    time.sleep(3)
    answer()
    info = try_call("device_info") or {}
    log("裝置", info.get("model"), info.get("system_version"))

    for mode in MODES:
        if not add_shortcut(mode):
            continue
        subprocess.run(["xcrun", "simctl", "terminate", UDID, SHORTCUTS], capture_output=True, timeout=30)
        time.sleep(2)
        if all([run_case(mode, VIDEO), run_case(mode, GIF)]):
            rest = [run_case(mode, REPLY), run_case(mode, PHOTOS)]
            log(f"{mode} 基本兩項通過，回覆與純照片 {sum(rest)} / {len(rest)}")
            if all(rest):
                with open(os.path.join(OUT, "winner.txt"), "w") as f:
                    f.write(mode)
                log("採用", mode)
                return 0
    log("沒有一種寫法全部通過")
    return 1


sys.exit(main())
