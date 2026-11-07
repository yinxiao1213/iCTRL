#!/usr/bin/env python3
"""在 iOS 模擬器的捷徑 App 裡，實際匯入並執行 Threads 保存捷徑。

    Tests/sim/shortcut_e2e.py UDID 捷徑網址前綴 OUT_DIR OCR執行檔

靠 runner 看畫面、按按鈕，再直接看模擬器相簿的資料夾，確認檔案真的存進去。
捷徑怎麼把網頁變回原始 HTML 只有實際跑才知道，所以三種寫法依序試，
第一個全部通過的寫進 OUT_DIR/winner.txt。由 Tests/sim/run-shortcut.sh 啟動。
"""
import base64
import json
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
UDID, BASE, OUT, OCR = sys.argv[1:5]
SIZE = [402, 874]
MODES = ("rename", "base64", "direct")

VIDEO = ("video", "https://www.threads.com/@rottentomatoes/post/DQP4mmZD_0S?xmt=AQG0abc&slof=1", {"mp4": 1})
GIF = ("gif", "https://www.threads.com/@giphy/post/DFmKJ4zMWMv", {"gif": 1})
REPLY = ("reply", "https://www.threads.com/@pamplemousse_and_circumstances/post/DXieIOeDRO3", {"gif": 1})
PHOTOS = ("photos-only", "https://www.threads.com/@gif_names_finding/post/DU6V-sPExs6", {})

# 畫面上出現就按。順序就是優先序；「Allow」要完全相符，才不會按到 Don't Allow。
# OK 排在 Continue 前面：警告視窗蓋住畫面時，後面的 Continue 按不到。
ANSWERS = ("Always Allow", "Allow Full Access", "Allow Access", "Allow", "Allow Once", "Add Shortcut",
           "OK", "Continue", "Get Started", "Not Now", "Done")


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
    try:
        done = subprocess.run(["xcrun", "simctl", "openurl", UDID, url], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        log("  openurl 逾時", url[:110])
        return
    log("  openurl", url[:110], "結束碼", done.returncode, done.stderr.strip()[:200])


def labels():
    """畫面上所有文字和位置（單位是點）。

    畫面用 runner 拍（simctl io 在這裡常逾時），文字用 Mac 的 Vision 辨識，
    因為 runner 的 screen_text 不給系統對話框的座標。
    """
    result = try_call("screenshot", {"format": "jpeg", "quality": 0.8})
    if not result or not result.get("data"):
        return []
    path = os.path.join(OUT, "now.jpg")
    with open(path, "wb") as f:
        f.write(base64.b64decode(result["data"]))
    try:
        done = subprocess.run([OCR, path], capture_output=True, text=True, timeout=30)
        found = json.loads(done.stdout or "[]")
    except (subprocess.TimeoutExpired, ValueError) as e:
        log("  ( 辨識失敗:", str(e)[:120], ")")
        return []
    if done.stderr.strip():
        log("  ( 辨識訊息:", done.stderr.strip()[:160], ")")
    return [{"label": i["label"], "center_x": round(i["cx"] * SIZE[0]), "center_y": round(i["cy"] * SIZE[1])}
            for i in found]


def answer():
    """按掉畫面上的一個問題，回傳按了什麼。"""
    items = labels()
    for want in ANSWERS:
        for item in items:
            label = item.get("label", "").strip()
            if label.lower() == want.lower() or (want in ("Always Allow", "Add Shortcut") and want in label):
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


def tap_label(words, exact=False):
    """按畫面上第一個符合的文字，回傳按到的字。words 的順序就是優先序。"""
    items = labels()
    for word in words:
        for item in items:
            label = item.get("label", "").strip()
            if (label.lower() == word.lower()) if exact else (word.lower() in label.lower()):
                if try_call("tap", {"x": item["center_x"], "y": item["center_y"]}) is not None:
                    log("  按了", label)
                    return word
    return None


def open_in_files(mode):
    """往下載資料夾走一步，點開捷徑檔時回傳 True，什麼都沒做時回傳 None。

    圖示模式下點到名稱會變成重新命名，所以點名稱上方的圖示。OCR 會把檔名斷成
    兩行（ts- / rename.shortcut），也常把 Downloads 讀錯，所以只比對可靠的部分。
    畫面最上方的標題和本文同名，要排除。
    """
    items = [i for i in labels() if i.get("center_y", 0) > 150 and "empty" not in i.get("label", "").lower()]

    def pick(word):
        return next((i for i in items if word.lower() in i.get("label", "").lower()), None)

    for word, lift in ((f"{mode}.", 75), ("On My iPhone", 0), ("Downlo", 50)):
        item = pick(word)
        if item:
            try_call("tap", {"x": item["center_x"], "y": item["center_y"] - lift})
            log("  點了", item.get("label"))
            return word.endswith(".")
    return None


def downloaded(name):
    root = os.path.expanduser(f"~/Library/Developer/CoreSimulator/Devices/{UDID}/data")
    for folder, _, names in os.walk(root):
        if name in names:
            return os.path.join(folder, name)
    return None


def warm_up():
    """先開過 Safari 和捷徑並留在背景。

    模擬器上兩個 App 冷啟動時都會把剛收到的網址或檔案弄丟，
    Safari 只顯示起始頁，捷徑只顯示列表。第一次開還有新功能介紹要關掉。
    """
    try_call("launch_app", {"bundle_id": "com.apple.mobilesafari"})
    time.sleep(5)
    try_call("launch_app", {"bundle_id": SHORTCUTS})
    for _ in range(5):
        time.sleep(2)
        answer()
    shot("warm")
    try_call("home")
    time.sleep(1)


def add_shortcut(mode):
    """走使用者會走的路：Safari 下載 → 檔案 App 點開 → Add Shortcut。"""
    log("匯入", mode)
    warm_up()
    name = f"ts-{mode}"
    open_url(f"{BASE}/{name}.shortcut")
    end = time.time() + 100
    round_no = 0
    path = None
    while time.time() < end and not path:
        time.sleep(2)
        round_no += 1
        items = labels()
        if round_no % 6 == 1:
            shot(f"safari-{mode}-{round_no}")
            log("  Safari:", [i.get("label") for i in items][:10])
        for item in items:
            # 提示句裡的 download 是小寫，按鈕才是大寫開頭。
            if item.get("label", "").strip().startswith("Downlo"):
                try_call("tap", {"x": item["center_x"], "y": item["center_y"]})
                log("  按了", item.get("label"))
                break
        path = downloaded(f"{name}.shortcut")
    log("  下載到", path)
    if not path:
        return False
    subprocess.run(["xcrun", "simctl", "terminate", UDID, "com.apple.DocumentsApp"], capture_output=True, timeout=30)
    try_call("launch_app", {"bundle_id": "com.apple.DocumentsApp"})
    time.sleep(3)
    tap_label(["Browse"], exact=True)
    end = time.time() + 70
    round_no = 0
    idle = 0
    opened = False
    while time.time() < end and not opened:
        time.sleep(2)
        round_no += 1
        if round_no % 5 == 1:
            shot(f"files-{mode}-{round_no}")
            log("  檔案:", [i.get("label") for i in labels()][:12])
        step = open_in_files(mode)
        opened = step is True
        idle = idle + 1 if step is None else 0
        if idle >= 5:
            tap_label(["Browse"], exact=True)
            idle = 0
    log("  點開了檔案" if opened else "  檔案 App 裡找不到捷徑檔")
    end = time.time() + 40
    added = False
    round_no = 0
    while time.time() < end:
        time.sleep(2)
        round_no += 1
        if round_no % 3 == 1:
            shot(f"import-{mode}-{round_no}")
            log("  匯入畫面:", [i.get("label") for i in labels()][:14])
        pressed = answer()
        added = added or pressed == "Add Shortcut"
        if added and pressed is None:
            break
    shot(f"import-{mode}-end")
    log("  已加入" if added else "  沒看到 Add Shortcut")
    if not added:
        tap_label(["Cancel"], exact=True)
    return added


def run_case(mode, case):
    name, link, expected = case
    before = album()
    total = sum(expected.values())
    log("執行", mode, name)
    open_url("shortcuts://run-shortcut?name=" + urllib.parse.quote(f"ts-{mode}") + "&input=text&text="
             + urllib.parse.quote(link, safe=""))
    end = time.time() + 100
    settled = 0
    round_no = 0
    while time.time() < end:
        time.sleep(1.5)
        round_no += 1
        seen = labels()
        ask = " ".join(i.get("label", "") for i in seen[:5])
        if "Allow" in ask or "allow" in ask:
            log("  詢問:", ask[:120])
        pressed = answer()
        new = set(album()) - set(before)
        if round_no == 3 or round_no % 8 == 0:
            shot(f"run-{mode}-{name}-{round_no}")
            log("  畫面:", [i.get("label") for i in seen][:12], "新檔案", len(new))
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
    try_call("home")
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
    log("裝置", info.get("model"), info.get("system_version"), info.get("point_width"), info.get("point_height"))
    if info.get("point_width") and info.get("point_height"):
        SIZE[:] = [info["point_width"], info["point_height"]]
    log("辨識測試:", [i["label"] for i in labels()][:8])

    for mode in MODES:
        if not add_shortcut(mode):
            continue
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
