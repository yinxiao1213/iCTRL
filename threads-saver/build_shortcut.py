#!/usr/bin/env python3
"""產生「Threads 保存」捷徑（未簽章的 plist）。

    build_shortcut.py 輸出檔

流程：取得貼文代碼 → 讀官方 /embed 嵌入頁 → 切掉回覆上層 → 找影片和 GIF →
逐一下載存進相簿。全部在手機上跑，不經過任何伺服器。
"""
import argparse
import plistlib
import uuid

# 以下三條規則同時給 check_live.py 用，改這裡兩邊一起生效。
# 代碼：/post/代碼 或 /t/代碼。後面的帳號、xmt 參數、網域都不影響。
# 連結包在別的網址參數裡時斜線會編碼成 %2F，比對時不分大小寫。
CODE_RE = r"(?:(?<=/post/)|(?<=/t/)|(?<=%2Fpost%2F)|(?<=%2Ft%2F))[A-Za-z0-9_-]+"
# 短網址要打開才知道是哪篇，頁面的 canonical 會有 /post/代碼。
# 這裡不比對 /t/：頁面裡的靜態資源路徑也可能有。
POST_RE = r"(?<=/post/)[A-Za-z0-9_-]+"
# 回覆貼文的嵌入頁會先顯示上層貼文，目標貼文從第一個 OuterContainerFull 開始。
# 只切到第一個：引用貼文會在同一篇裡再出現一次，切到最後會把主貼文切掉。
STRIP_RE = r'^[\s\S]*?class="OuterContainer OuterContainerFull'
# 影片是 <source src>；GIF 是 Meta 代理網址，url= 參數裡是 Giphy 等來源。
# 連結預覽縮圖也走同一個代理，所以要看 url= 的內容才分得出來。
MEDIA_RE = (
    r'(?<=<source src=")[^"]+'
    r'|(?<=src=")https://[^"]*/emg1/[^"]*url=https?[^&"]*(?:giphy|tenor|klipy|\.gif)[^"]*'
)

OBJ = "\ufffc"
NS = uuid.UUID("6f1f3a52-3c55-4a54-9d0e-7b6f7c1e0a11")
INPUT = {"Type": "ExtensionInput"}
# Threads App 分享時傳的是 URL 物件，要明確轉成文字。
INPUT_TEXT = {
    "Type": "ExtensionInput",
    "Aggrandizements": [{"Type": "WFCoercionVariableAggrandizement", "CoercionItemClass": "WFStringContentItem"}],
}
CODES = {"Type": "Variable", "VariableName": "postCodes"}
REPEAT_ITEM = {"Type": "Variable", "VariableName": "Repeat Item"}


def uid(label):
    return str(uuid.uuid5(NS, label)).upper()


def output(label, name):
    return {"Type": "ActionOutput", "OutputUUID": uid(label), "OutputName": name}


def attach(value):
    return {"Value": value, "WFSerializationType": "WFTextTokenAttachment"}


def text(*parts):
    """文字欄位：字串和變數可以混著放。"""
    string, ranges = "", {}
    for part in parts:
        if isinstance(part, str):
            string += part
        else:
            offset = len(string.encode("utf-16-le")) // 2
            ranges[f"{{{offset}, 1}}"] = part
            string += OBJ
    return {
        "Value": {"string": string, "attachmentsByRange": ranges},
        "WFSerializationType": "WFTextTokenString",
    }


def action(identifier, label=None, **params):
    if label:
        params["UUID"] = uid(label)
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions." + identifier,
        "WFWorkflowActionParameters": params,
    }


def block_if(group, value, body, otherwise):
    """如果 value 有任何值就跑 body，否則跑 otherwise。"""
    gid = uid(group)
    return [
        action("conditional", WFControlFlowMode=0, GroupingIdentifier=gid, WFCondition=100,
               WFInput={"Type": "Variable", "Variable": attach(value)}),
        *body,
        action("conditional", WFControlFlowMode=1, GroupingIdentifier=gid),
        *otherwise,
        action("conditional", group + "-end", WFControlFlowMode=2, GroupingIdentifier=gid),
    ]


def block_repeat(group, value, body):
    gid = uid(group)
    return [
        action("repeat.each", WFControlFlowMode=0, GroupingIdentifier=gid, WFInput=attach(value)),
        *body,
        action("repeat.each", group + "-end", WFControlFlowMode=2, GroupingIdentifier=gid),
    ]


def alert(title, message):
    return action("alert", WFAlertActionTitle=title, WFAlertActionMessage=message,
                  WFAlertActionCancelButtonShown=False)


def read_html(prefix, page):
    """把下載到的網頁轉成原始 HTML 文字，回傳（動作清單, 文字變數）。

    捷徑預設把網頁當成排版文字，<source> 這類標籤會不見，
    所以 base64 來回一次再改名成 .txt，讀到的才是原始碼。
    """
    encoded = output(prefix + "-enc", "Base64 Encoded")
    decoded = output(prefix + "-dec", "Base64 Decoded")
    named = output(prefix + "-txt", "Renamed Item")
    return [
        action("base64encode", prefix + "-enc", WFInput=attach(page), WFEncodeMode="Encode",
               WFBase64LineBreakMode="None"),
        action("base64encode", prefix + "-dec", WFInput=attach(encoded), WFEncodeMode="Decode"),
        action("setitemname", prefix + "-txt", WFInput=attach(decoded), WFName="page.txt",
               WFDontIncludeFileExtension=False),
        action("detect.text", prefix + "-html", WFInput=attach(named)),
    ], output(prefix + "-html", "Text")


def remember(codes):
    return action("setvariable", WFVariableName=CODES["VariableName"], WFInput=attach(codes))


def find_code():
    """找出貼文代碼放進 postCodes，回傳（動作清單, 收到的內容）。"""
    links = output("links", "URLs")
    received = output("received", "Text")
    codes = output("codes", "Matches")
    link = output("link", "Item from List")
    link_page = output("link-page", "Contents of URL")
    link_codes = output("link-codes", "Matches")
    clipboard = output("clipboard", "Clipboard")
    clip_codes = output("clip-codes", "Matches")
    html_steps, html = read_html("link", link_page)
    return [
        # 文字轉換和取出網址兩條路都走，放在一起比對，哪一條拿到都算。
        action("detect.link", "links", WFInput=attach(INPUT)),
        action("gettext", "received", WFTextActionText=text(INPUT_TEXT, "\n", links)),
        action("text.match", "codes", text=text(received), WFMatchTextPattern=CODE_RE,
               WFMatchTextCaseSensitive=False),
        remember(codes),
        *block_if("need-more", codes, [], [
            *block_if("has-link", links, [
                # 短網址：打開來看轉到哪一篇。
                action("getitemfromlist", "link", WFInput=attach(links), WFItemSpecifier="First Item"),
                action("downloadurl", "link-page", WFURL=text(link), WFHTTPMethod="GET"),
                *html_steps,
                action("text.match", "link-codes", text=text(html), WFMatchTextPattern=POST_RE,
                       WFMatchTextCaseSensitive=True),
                remember(link_codes),
            ], [
                # 完全沒收到網址才讀剪貼簿，否則可能存到上一篇複製過的貼文。
                action("getclipboard", "clipboard"),
                action("text.match", "clip-codes", text=text(clipboard), WFMatchTextPattern=CODE_RE,
                       WFMatchTextCaseSensitive=False),
                remember(clip_codes),
            ]),
        ]),
    ], received


def build():
    code = output("code", "Item from List")
    page = output("page", "Contents of URL")
    body = output("body", "Updated Text")
    media = output("media", "Matches")
    fixed = output("fixed", "Updated Text")
    file = output("file", "Contents of URL")
    count = output("count", "Count")
    html_steps, html = read_html("embed", page)
    code_steps, received = find_code()

    save_all = [
        *block_repeat("each", media, [
            # HTML 裡的 & 是 &amp;，不換回來網址的簽章參數會失效。
            action("text.replace", "fixed", WFInput=text(REPEAT_ITEM), WFReplaceTextFind="&amp;",
                   WFReplaceTextReplace="&", WFReplaceTextCaseSensitive=True,
                   WFReplaceTextRegularExpression=False),
            action("downloadurl", "file", WFURL=text(fixed), WFHTTPMethod="GET"),
            action("savetocameraroll", WFInput=attach(file)),
        ]),
        action("count", "count", Input=attach(media), WFCountType="Items"),
        action("notification", WFNotificationActionTitle="已存到相簿",
               WFNotificationActionBody=text("共 ", count, " 個影片或 GIF"),
               WFNotificationActionSound=False),
    ]
    fetch_and_save = [
        action("getitemfromlist", "code", WFInput=attach(CODES), WFItemSpecifier="First Item"),
        action("downloadurl", "page", WFURL=text("https://www.threads.com/t/", code, "/embed"),
               WFHTTPMethod="GET"),
        *html_steps,
        action("text.replace", "body", WFInput=text(html), WFReplaceTextFind=STRIP_RE,
               WFReplaceTextReplace="", WFReplaceTextCaseSensitive=True,
               WFReplaceTextRegularExpression=True),
        action("text.match", "media", text=text(body), WFMatchTextPattern=MEDIA_RE,
               WFMatchTextCaseSensitive=False),
        *block_if("has-media", media, save_all, [
            alert("找不到影片或 GIF", "這篇可能只有文字或照片，或是私人帳號的貼文。"),
        ]),
    ]
    actions = [
        *code_steps,
        *block_if("has-code", CODES, fetch_and_save, [
            alert("沒有收到 Threads 連結", text("請把這個畫面截圖回報。收到的內容：\n", received)),
        ]),
    ]
    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "5037.0.17",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {
            "WFWorkflowIconGlyphNumber": 59693,  # 下載箭頭
            "WFWorkflowIconStartColor": 946986751,  # 深藍
        },
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": [
            "WFURLContentItem", "WFSafariWebPageContentItem", "WFStringContentItem",
            "WFRichTextContentItem",
        ],
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowTypes": ["ActionExtension", "WFWorkflowTypeShowInSearch"],
        "WFWorkflowHasShortcutInputVariables": True,
        "WFWorkflowHasOutputFallback": False,
        "WFQuickActionSurfaces": [],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    args = parser.parse_args()
    with open(args.out, "wb") as f:
        plistlib.dump(build(), f, fmt=plistlib.FMT_BINARY)
    print("wrote", args.out)


if __name__ == "__main__":
    main()
