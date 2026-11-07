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
# base64 是正式版：四項加分享選單都實測通過。rename 四項也過，但沒測過分享選單。
# 第一次開捷徑 App 時匯入畫面可能被新功能介紹吃掉，所以排兩次。
MODES = ("base64", "base64", "rename", "direct")

VIDEO = ("video", "https://www.threads.com/@rottentomatoes/post/DQP4mmZD_0S?xmt=AQG0abc&slof=1", {"mp4": 1})
GIF = ("gif", "https://www.threads.com/@giphy/post/DFmKJ4zMWMv", {"gif": 1})
REPLY = ("reply", "https://www.threads.com/@pamplemousse_and_circumstances/post/DXieIOeDRO3", {"gif": 1})
PHOTOS = ("photos-only", "https://www.threads.com/@gif_names_finding/post/DU6V-sPExs6", {})

# 畫面上出現就按。順序就是優先序；「Allow」要完全相符，才不會按到 Don't Allow。
# OK 排在 Continue 前面：警告視窗蓋住畫面時，後面的 Continue 按不到。
ANSWERS = ("Always Allow", "Allow Full Access", "Allow Access", "Allow Paste", "Allow", "Allow Once", "Add Shortcut",
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
    """畫面上的文字和位置，包含系統畫在 App 上面的對話框（overlay_items）。"""
    result = try_call("screen_text") or {}
    return result.get("items", []) + result.get("overlay_items", [])


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
        if round_no % 8 == 0:
            open_url(f"{BASE}/{name}.shortcut")
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


def wait_album(before, want, limit=100):
    """一邊回答詢問一邊等，回傳新檔案的種類統計。"""
    end = time.time() + limit
    settled = 0
    while time.time() < end:
        time.sleep(1.5)
        pressed = answer()
        settled = settled + 1 if (len(set(album()) - set(before)) >= want and pressed is None) else 0
        if settled >= 3:
            break
    kinds = [kind(p) for p in sorted(set(album()) - set(before))]
    return {k: kinds.count(k) for k in set(kinds)}


def from_clipboard(mode):
    """從主畫面按捷徑的情況：沒有輸入，改讀剪貼簿。"""
    log("剪貼簿", mode)
    link = "https://www.threads.com/@orbismala/post/DeCQmv0Ehbi"
    subprocess.run(["xcrun", "simctl", "pbcopy", UDID], input=link, text=True, capture_output=True, timeout=30)
    pasted = subprocess.run(["xcrun", "simctl", "pbpaste", UDID], capture_output=True, text=True, timeout=30)
    log("  模擬器剪貼簿:", pasted.stdout[:80])
    before = album()
    try_call("launch_app", {"bundle_id": SHORTCUTS})
    time.sleep(3)
    shot("clipboard-start")
    tap_label([f"ts-{mode}"])
    got = wait_album(before, 1, 45)
    shot("clipboard-end")
    log(("ok   " if got == {"mp4": 1} else "FAIL ") + f"剪貼簿: 實際 {got}")
    try_call("home")


def from_share_sheet(mode):
    """實際使用的路：開貼文 → 分享 → 選捷徑。輸入是網頁而不是文字，跑在分享擴充功能裡。"""
    log("分享選單", mode)
    before = album()
    open_url("https://www.threads.com/@senwhitehouse/post/DOy2H84DpZ0")
    time.sleep(12)
    shot("share-page")
    source = (try_call("page_source") or {})
    lines = [line.strip()[:90] for line in str(source.get("source") or source.get("body") or source).split("\n")
             if "Button" in line]
    log("  按鈕:", lines[:24])
    for word in ("Page Menu", "More", "Share"):
        found = try_call("find_element", {"element_id": word, "bundle_id": "com.apple.mobilesafari", "match": "contains"})
        log("  找", word, bool(found and found.get("ref")))
        if found and found.get("ref"):
            try_call("tap", {"ref": found["ref"]})
            time.sleep(2.5)
            shot("share-menu")
            log("  選單:", [i.get("label") for i in labels()][:14])
            if word != "Share":
                tap_label(["Share"])
                time.sleep(3)
            break
    for round_no in range(7):
        items = labels()
        log("  分享選單:", [i.get("label") for i in items][:16])
        shot(f"share-sheet-{round_no}")
        item = next((i for i in items if f"ts-{mode}" in i.get("label", "")), None)
        if item:
            try_call("tap", {"x": item["center_x"], "y": item["center_y"]})
            log("  點了", item.get("label"))
            break
        try_call("drag", {"from_x": 200, "from_y": 720, "to_x": 200, "to_y": 330, "duration": 0.3})
        time.sleep(1.5)
    else:
        log("FAIL 分享選單: 找不到捷徑")
        return
    got = wait_album(before, 1)
    shot("share-end")
    log(("ok   " if got == {"mp4": 1} else "FAIL ") + f"分享選單: 實際 {got}")


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
        if all([run_case(mode, VIDEO), run_case(mode, GIF)]):
            rest = [run_case(mode, REPLY), run_case(mode, PHOTOS)]
            log(f"{mode} 基本兩項通過，回覆與純照片 {sum(rest)} / {len(rest)}")
            if all(rest):
                with open(os.path.join(OUT, "winner.txt"), "w") as f:
                    f.write(mode)
                log("採用", mode)
                # 這兩項只回報結果：失敗也不影響已驗證的檔案，但要看得到。
                for extra in (from_clipboard, from_share_sheet):
                    try:
                        extra(mode)
                    except Exception as e:  # noqa: BLE001
                        log("FAIL", extra.__name__, repr(e)[:200])
                return 0
    log("沒有一種寫法全部通過")
    return 1


sys.exit(main())
