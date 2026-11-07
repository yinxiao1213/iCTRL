#!/usr/bin/env python3
"""產生捷徑並簽章，放進 signed/ts-v2.shortcut。iOS 只接受簽過章的捷徑檔。

    sign.py

macOS 的 shortcuts sign 要登入 iCloud，雲端 Mac 用不了，所以改用 RoutineHub 的
公開簽章服務 HubSign。送出去的只有捷徑本身的動作，沒有任何個人資料。
要在一般電腦上跑：從 GitHub Actions 送出時 HubSign 回 403，從這台電腦用 curl 就正常。

簽章憑證有效期約一年，過期前重跑一次再推上去就好。已加入手機的捷徑不受影響。
"""
import json
import os
import plistlib
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_shortcut import build  # noqa: E402

HUBSIGN = "https://hubsign.routinehub.services/sign"
SIGNED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "signed")


def sign():
    xml = plistlib.dumps(build(), fmt=plistlib.FMT_XML).decode()
    dest = os.path.join(SIGNED, "ts-v2.shortcut")
    with tempfile.TemporaryDirectory() as folder:
        payload = os.path.join(folder, "payload.json")
        with open(payload, "w", encoding="utf8") as f:
            json.dump({"shortcutName": "ThreadsSaver", "shortcut": xml}, f)
        reply = os.path.join(folder, "reply")
        done = subprocess.run(
            ["curl", "-sS", "-m", "60", "-o", reply, "-w", "%{http_code}", "-X", "POST",
             "-H", "Content-Type: application/json", "--data", "@" + payload, HUBSIGN],
            capture_output=True, text=True)
        with open(reply, "rb") as f:
            data = f.read()
    if done.stdout != "200" or data[:4] != b"AEA1":
        print(f"簽章失敗: HTTP {done.stdout} {done.stderr.strip()} {data[:120]!r}")
        return False
    with open(dest, "wb") as f:
        f.write(data)
    print(f"簽章完成: {len(data)} bytes")
    return True


def main():
    os.makedirs(SIGNED, exist_ok=True)
    return 0 if sign() else 1


if __name__ == "__main__":
    sys.exit(main())
