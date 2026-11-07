#!/usr/bin/env python3
"""用捷徑同一組規則抓真實貼文，確認 Threads 的嵌入頁格式還沒變。

每篇都真的下載媒體並檢查內容：影片要同時有畫面和聲音，GIF 要有多個影格。
"""
import html
import os
import re
import struct
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_shortcut import CODE_RE, LINK_RE, MEDIA_RE, POST_RE, STRIP_RE  # noqa: E402

# 模擬捷徑沒有自訂 User-Agent 時送出的樣子。
UA = "Shortcuts/4046 CFNetwork/3860 Darwin/25.0.0"

# （分享連結, 影片數, GIF 數, 說明）
CASES = [
    ("https://www.threads.com/@rottentomatoes/post/DQP4mmZD_0S?xmt=AQG0abc&slof=1", 1, 0, "影片，含分享參數"),
    ("https://www.threads.net/@senwhitehouse/post/DOy2H84DpZ0", 1, 0, "影片，舊網域"),
    ("https://www.threads.com/@orbismala/post/DeCQmv0Ehbi/video-why-the-harry-potter-clip/", 1, 0, "影片，含標題網址"),
    ("看這個 https://www.threads.com/@andypunzalan23/post/DQ2-kvEEgWT 好笑", 1, 0, "影片，連結夾在文字裡"),
    ("https://www.threads.com/@giphy/post/DFmKJ4zMWMv?hl=en", 0, 1, "GIF"),
    ("https://l.threads.com/?u=https%3A%2F%2Fwww.threads.com%2F%40jarvm%2Fpost%2FDWhqV_fjQEC&e=x", 0, 1, "GIF，包在轉址參數裡"),
    ("https://www.threads.com/@jarvm/post/DWhqV_fjQEC", 0, 1, "GIF"),
    ("https://www.threads.com/@serenduckity/post/DTiVoO0lImw", 0, 1, "GIF"),
    ("https://www.threads.com/@mattlombardonfl/post/DXCxn9wkfC0/lfg", 0, 1, "GIF，內含引用貼文"),
    ("https://www.threads.com/@pamplemousse_and_circumstances/post/DXieIOeDRO3", 0, 1, "回覆的 GIF，不可存到上層照片"),
    ("https://www.threads.com/@threads/post/Cy32aqouz_5?hl=en", 1, 0, "回覆的影片，不可存到上層 GIF"),
    ("https://www.threads.com/@gif_names_finding/post/DU6V-sPExs6", 0, 0, "純照片"),
    ("https://www.threads.com/@threads/post/DfaoyQan27y", 0, 0, "純文字"),
    ("https://www.threads.com/@manganimist/post/DVzlrAUDIA5", 0, 0, "連結預覽縮圖不算 GIF"),
]


# 2.6 秒的操作示範，編碼規格和有聲影片相同，來源本身就沒有聲音。
# 其他影片少了聲音軌一律算失敗，這樣才抓得到只給無聲串流的情況。
SILENT = {"Cy32aqouz_5"}


def get(url):
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(request, timeout=60) as reply:
        return reply.read()


def walk(data, start, end, found):
    while start + 8 <= end:
        size, kind = struct.unpack(">I4s", data[start:start + 8])
        head = 8
        if size == 1:
            size = struct.unpack(">Q", data[start + 8:start + 16])[0]
            head = 16
        size = size or end - start
        if size < 8:
            return
        if kind in (b"moov", b"trak", b"mdia"):
            walk(data, start + head, min(start + size, end), found)
        if kind == b"hdlr":
            found.add(data[start + head + 8:start + head + 12])
        start += size


def describe(data, silent=False):
    """回傳（種類, 說明）；內容不對時種類是 None。"""
    if data[4:8] == b"ftyp":
        tracks = set()
        walk(data, 0, len(data), tracks)
        ok = b"vide" in tracks and (silent or b"soun" in tracks)
        return ("video" if ok else None), f"MP4 {len(data) // 1024}KB 軌道 {sorted(t.decode() for t in tracks)}"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        frames = data.count(b"\x21\xf9\x04")
        return ("gif" if frames > 1 else None), f"GIF {len(data) // 1024}KB 約 {frames} 影格"
    return None, f"不認得的格式 {data[:8]!r}"


def extract(shared):
    found = re.findall(CODE_RE, shared, flags=re.I)
    if found:
        code = found[0]
    else:
        # 短網址：和捷徑一樣打開來找。
        landing = get(re.findall(LINK_RE, shared)[0]).decode("utf8", "ignore")
        code = re.findall(POST_RE, landing)[0]
    page = get(f"https://www.threads.com/t/{code}/embed").decode("utf8", "ignore")
    body = re.sub(STRIP_RE, "", page, count=1)
    return code, [m.replace("&amp;", "&") for m in re.findall(MEDIA_RE, body, flags=re.I)]


def main():
    # 指令後面可以接分享連結，只看抓到什麼，不用把別人的貼文寫進這個公開專案。
    for shared in sys.argv[1:]:
        code, urls = extract(shared)
        print(code, [describe(get(url))[1] for url in urls] or "沒有媒體", flush=True)
    if sys.argv[1:]:
        return 0
    bad = 0
    for shared, videos, gifs, note in CASES:
        code, urls = extract(shared)
        kinds, details = [], []
        for url in urls:
            kind, detail = describe(get(url), code in SILENT)
            kinds.append(kind)
            details.append(detail)
        ok = kinds.count("video") == videos and kinds.count("gif") == gifs and None not in kinds
        bad += not ok
        print(("ok   " if ok else "FAIL ") + f"{code} {note}: {'; '.join(details) or '沒有媒體'}", flush=True)
    print(f"{len(CASES) - bad} / {len(CASES)} 通過")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
