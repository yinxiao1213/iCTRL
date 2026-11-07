#!/usr/bin/env python3
"""幫捷徑簽章。iOS 只接受簽過章的捷徑檔。

    sign.py 未簽章檔 輸出檔 [--hubsign]

先用 macOS 內建的 shortcuts sign。加了 --hubsign 時，內建失敗會改用 RoutineHub
的公開簽章服務；送出去的只有捷徑本身的動作，沒有任何個人資料。
"""
import argparse
import json
import plistlib
import subprocess
import sys
import urllib.request

HUBSIGN = "https://hubsign.routinehub.services/sign"


def signed(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"AEA1"
    except OSError:
        return False


def native(source, dest):
    try:
        done = subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", source, "--output", dest],
                              capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as e:
        print("shortcuts sign 沒有完成:", e)
        return False
    print("shortcuts sign 結束碼", done.returncode, done.stdout.strip(), done.stderr.strip())
    return done.returncode == 0 and signed(dest)


def hubsign(source, dest):
    with open(source, "rb") as f:
        xml = plistlib.dumps(plistlib.load(f), fmt=plistlib.FMT_XML).decode()
    body = json.dumps({"shortcutName": "ThreadsSaver", "shortcut": xml}).encode()
    request = urllib.request.Request(HUBSIGN, body, {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=60) as reply:
            data = reply.read()
    except OSError as e:
        print("HubSign 失敗:", e)
        return False
    with open(dest, "wb") as f:
        f.write(data)
    print("HubSign 回傳", len(data), "bytes")
    return signed(dest)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("dest")
    parser.add_argument("--hubsign", action="store_true")
    args = parser.parse_args()
    if native(args.source, args.dest):
        print("簽章完成（macOS 內建）:", args.dest)
        return 0
    if args.hubsign and hubsign(args.source, args.dest):
        print("簽章完成（HubSign）:", args.dest)
        return 0
    print("簽章失敗:", args.dest)
    return 1


if __name__ == "__main__":
    sys.exit(main())
