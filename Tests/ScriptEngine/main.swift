// Runs ScriptEngine against a fake phone:
//   Scripts/test-script-engine.sh
import Foundation

// RPCTypes.swift mentions these; the engine never uses them.
enum AuthManager { static let inactivityWindow: TimeInterval = 0 }
extension Data { init?(hexString: String) { return nil } }

final class FakePhone: ScriptDriver {
    let lock = NSLock()
    private var _calls: [(String, [String: JSONValue])] = []
    var calls: [(String, [String: JSONValue])] { lock.lock(); defer { lock.unlock() }; return _calls }
    var names: [String] { calls.map { $0.0 } }
    /// `names` without the small frames the engine watches the screen with.
    var actions: [String] {
        calls.filter { !($0.0 == "screenshot" && $0.1["scale"]?.doubleValue == ScriptEngine.frameScale) }.map { $0.0 }
    }
    var notifications: [(String, String)] = []
    var locked = false
    /// How each method answers; default is an empty success.
    var answers: [String: (Int) -> ([String: JSONValue]?, JSONRPCError?)] = [:]
    private var counts: [String: Int] = [:]

    func scriptPerform(_ method: String, _ params: [String: JSONValue]) -> ([String: JSONValue]?, JSONRPCError?) {
        lock.lock()
        _calls.append((method, params))
        let n = counts[method, default: 0]
        counts[method] = n + 1
        let answer = answers[method]
        lock.unlock()
        return answer?(n) ?? ([:], nil)
    }
    var scriptPhoneLocked: Bool { locked }
    func scriptNotify(title: String, body: String) { lock.lock(); notifications.append((title, body)); lock.unlock() }
}

var failures = 0
var checks = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok { print("ok   \(name)") } else { failures += 1; print("FAIL \(name) \(detail())") }
}

func make(_ phone: FakePhone) -> ScriptEngine {
    let engine = ScriptEngine(driver: phone)
    let clock = NSLock()
    var time: TimeInterval = 0
    engine.now = { clock.lock(); defer { clock.unlock() }; return time }
    engine.sleep = { d in clock.lock(); time += d; clock.unlock(); Thread.sleep(forTimeInterval: 0.0002) }
    return engine
}

func steps(_ list: [ScriptStep]) -> JSONValue {
    let data = try! JSONEncoder().encode(list)
    return try! JSONDecoder().decode(JSONValue.self, from: data)
}

func start(_ engine: ScriptEngine, _ list: [ScriptStep], loops: Int = 1) -> ([String: JSONValue]?, JSONRPCError?) {
    engine.handle(method: "script_run", params: ["steps": steps(list), "loops": .int(loops), "name": .string("測試")])
}

func status(_ engine: ScriptEngine) -> [String: JSONValue] {
    engine.handle(method: "script_status", params: nil).0 ?? [:]
}

@discardableResult
func waitDone(_ engine: ScriptEngine) -> [String: JSONValue] {
    let end = Date().addingTimeInterval(5)
    while Date() < end {
        let s = status(engine)
        if let state = s["state"]?.stringValue, !["running", "stopping"].contains(state) { return s }
        Thread.sleep(forTimeInterval: 0.002)
    }
    return status(engine)
}

func box(_ label: String, x: Double = 100, y: Double = 200, width: Double = 80) -> JSONValue {
    .object(["label": .string(label), "x": .double(x), "y": .double(y - 10), "width": .double(width), "height": .double(20),
             "center_x": .double(x + width / 2), "center_y": .double(y)])
}

// --- 依序執行、參數正確
do {
    let phone = FakePhone()
    let engine = make(phone)
    let list = [
        ScriptStep(kind: .openApp, bundleId: "com.example.app"),
        ScriptStep(kind: .tap, x: 10, y: 20),
        ScriptStep(kind: .longPress, x: 1, y: 2, duration: 1.5),
        ScriptStep(kind: .swipe, x: 1, y: 2, toX: 3, toY: 4, duration: 0.5),
        ScriptStep(kind: .type, text: "嗨", clear: true, submit: true),
        ScriptStep(kind: .home),
    ]
    _ = start(engine, list)
    let s = waitDone(engine)
    check("跑完狀態是 finished", s["state"]?.stringValue == "finished", "\(s)")
    check("順序正確", phone.actions == ["launch_app", "tap", "long_press", "drag", "type", "home"], "\(phone.names)")
    let calls = phone.calls.filter { $0.0 != "screenshot" }
    check("開 App 帶 bundle id", calls[0].1["bundle_id"]?.stringValue == "com.example.app")
    check("點擊帶座標", calls[1].1["x"]?.doubleValue == 10 && calls[1].1["y"]?.doubleValue == 20)
    check("長按帶秒數", calls[2].1["duration"]?.doubleValue == 1.5)
    check("滑動帶起訖", calls[3].1["from_x"]?.doubleValue == 1 && calls[3].1["to_y"]?.doubleValue == 4)
    check("輸入帶選項", calls[4].1["text"]?.stringValue == "嗨" && calls[4].1["clear"]?.boolValue == true
          && calls[4].1["submit"]?.boolValue == true)
    check("完成會通知", phone.notifications.first?.0 == "腳本完成")
}

// --- 等文字：看到才繼續
do {
    let phone = FakePhone()
    phone.answers["screen_text"] = { n in (["items": .array(n < 3 ? [box("別的字")] : [box("領 取")])], nil) }
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .waitText, text: "領取", timeout: 30), ScriptStep(kind: .home)])
    let s = waitDone(engine)
    check("等到文字後繼續", s["state"]?.stringValue == "finished" && phone.names.last == "home", "\(s)")
    check("讀了 4 次畫面", phone.names.filter { $0 == "screen_text" }.count == 4, "\(phone.names)")
}

// --- 等文字逾時
do {
    let phone = FakePhone()
    phone.answers["screen_text"] = { _ in (["items": .array([])], nil) }
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .tap, x: 1, y: 1), ScriptStep(kind: .waitText, text: "領取", timeout: 3), ScriptStep(kind: .home)])
    let s = waitDone(engine)
    check("等不到會失敗", s["state"]?.stringValue == "failed", "\(s)")
    check("錯誤說明第幾步", s["error"]?.stringValue?.contains("第 2 步") == true, "\(s)")
    check("錯誤說明等什麼", s["error"]?.stringValue?.contains("領取") == true, "\(s)")
    check("失敗後不繼續", !phone.names.contains("home"), "\(phone.names)")
    check("失敗會通知", phone.notifications.first?.0 == "腳本失敗")
}

// --- 點文字
do {
    let phone = FakePhone()
    phone.answers["screen_text"] = { _ in (["items": .array([box("領取優惠", x: 100, y: 300, width: 80), box("領取", x: 50, y: 500, width: 40)])], nil) }
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .tapText, text: "領取")])
    waitDone(engine)
    let tap = phone.calls.first { $0.0 == "tap" }
    check("完全相同的字優先", tap?.1["x"]?.doubleValue == 70 && tap?.1["y"]?.doubleValue == 500, "\(String(describing: tap))")
}
do {
    let phone = FakePhone()
    phone.answers["screen_text"] = { _ in (["items": .array([box("立即領取", x: 100, y: 300, width: 80)])], nil) }
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .tapText, text: "領取")])
    waitDone(engine)
    let tap = phone.calls.first { $0.0 == "tap" }
    check("長句裡的字會點在字上", tap?.1["x"]?.doubleValue == 160, "\(String(describing: tap))")
}

// --- 錄製時點在文字上的點擊
do {
    let phone = FakePhone()
    phone.answers["screen_text"] = { _ in (["items": .array([box("確定", x: 100, y: 100, width: 40), box("確定", x: 100, y: 600, width: 40)])], nil) }
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .tapText, x: 110, y: 590, text: "確定", timeout: 5)])
    waitDone(engine)
    let tap = phone.calls.first { $0.0 == "tap" }
    check("同樣的字挑離原位置最近的", tap?.1["y"]?.doubleValue == 600, "\(String(describing: tap))")
}
do {
    let phone = FakePhone()
    phone.answers["screen_text"] = { _ in (["items": .array([box("General", x: 100, y: 250, width: 60)])], nil) }
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .tapText, x: 110, y: 400, text: "General", timeout: 5)])
    waitDone(engine)
    let tap = phone.calls.first { $0.0 == "tap" }
    check("頁面移動時跟著文字走", tap?.1["y"]?.doubleValue == 250, "\(String(describing: tap))")
}
do {
    let phone = FakePhone()
    phone.answers["screen_text"] = { _ in (["items": .array([box("別的字")])], nil) }
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .tapText, x: 110, y: 400, text: "會變的字", timeout: 2)])
    let s = waitDone(engine)
    let tap = phone.calls.first { $0.0 == "tap" }
    check("文字不見了就點原位置", s["state"]?.stringValue == "finished" && tap?.1["x"]?.doubleValue == 110, "\(s)")
}

// --- 認字的雜訊
check("圖示邊緣認成的點不影響比對", ScriptEngine.bestMatch(.array([box("• General", x: 10, y: 20, width: 40)]), text: "General")?.y == 20)
check("錄到的點不影響比對", ScriptEngine.bestMatch(.array([box("General", x: 10, y: 20, width: 40)]), text: "• General")?.y == 20)
check("中文裡的空白不影響比對", ScriptEngine.bestMatch(.array([box("登 入", x: 10, y: 20, width: 40)]), text: "登入")?.y == 20)
check("只有符號的文字不會亂配", ScriptEngine.bestMatch(.array([box("General", x: 10, y: 20, width: 40)]), text: "•") == nil)

// --- 如果看到
func ifRun(seen: Bool, negate: Bool?, skip: Int?) -> [String] {
    let phone = FakePhone()
    phone.answers["screen_text"] = { _ in (["items": .array(seen ? [box("廣告")] : [])], nil) }
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .ifText, text: "廣告", skip: skip, negate: negate),
                       ScriptStep(kind: .tap, x: 1, y: 1),
                       ScriptStep(kind: .doubleTap, x: 1, y: 1),
                       ScriptStep(kind: .home)])
    waitDone(engine)
    return phone.names.filter { $0 != "screen_text" }
}
check("看到就做", ifRun(seen: true, negate: nil, skip: 1) == ["tap", "double_tap", "home"])
check("沒看到略過一步", ifRun(seen: false, negate: nil, skip: 1) == ["double_tap", "home"])
check("沒看到略過兩步", ifRun(seen: false, negate: nil, skip: 2) == ["home"])
check("反向：沒看到才做", ifRun(seen: false, negate: true, skip: 1) == ["tap", "double_tap", "home"])
check("反向：看到就略過", ifRun(seen: true, negate: true, skip: 1) == ["double_tap", "home"])
check("略過超過結尾不會當", ifRun(seen: false, negate: nil, skip: 99) == [])

// --- 動作失敗
do {
    let phone = FakePhone()
    phone.answers["tap"] = { _ in (nil, .serverError("boom")) }
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .tap, x: 1, y: 1), ScriptStep(kind: .home)])
    let s = waitDone(engine)
    check("動作失敗會停", s["state"]?.stringValue == "failed" && s["error"]?.stringValue?.contains("boom") == true, "\(s)")
}

// --- 鎖定手機＝緊急停止
do {
    let phone = FakePhone()
    phone.answers["tap"] = { [unowned phone] _ in phone.locked = true; return ([:], nil) }
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .tap, x: 1, y: 1), ScriptStep(kind: .home)])
    let s = waitDone(engine)
    check("鎖定後停止", s["state"]?.stringValue == "stopped", "\(s)")
    check("鎖定後不再動作", !phone.names.contains("home"), "\(phone.names)")
    check("停止原因寫鎖定", s["detail"]?.stringValue?.contains("鎖定") == true, "\(s)")
}
do {
    let phone = FakePhone()
    let engine = make(phone)
    phone.locked = true
    _ = start(engine, [ScriptStep(kind: .wait, duration: 9999)])
    let s = waitDone(engine)
    check("長時間等待中鎖定也會停", s["state"]?.stringValue == "stopped", "\(s)")
}

// --- 手動停止、重複
do {
    let phone = FakePhone()
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .tap, x: 1, y: 1), ScriptStep(kind: .wait, duration: 1)], loops: 0)
    let again = start(engine, [ScriptStep(kind: .home)])
    check("執行中不能再開一個", again.1 != nil)
    let busy = engine.handle(method: "rec_step", params: [:])
    check("執行中不能錄製", busy.1 != nil)
    while phone.names.count < 3 { Thread.sleep(forTimeInterval: 0.001) }
    _ = engine.handle(method: "script_stop", params: nil)
    let s = waitDone(engine)
    check("無限重複可以手動停", s["state"]?.stringValue == "stopped", "\(s)")
    check("重複時第幾輪有更新", (s["loop"]?.intValue ?? 0) >= 3, "\(s)")
    let next = start(engine, [ScriptStep(kind: .home)])
    check("停止後可以再跑", next.1 == nil)
    check("再跑後能完成", waitDone(engine)["state"]?.stringValue == "finished")
}
do {
    let phone = FakePhone()
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .tap, x: 1, y: 1)], loops: 3)
    waitDone(engine)
    check("重複三次", phone.names.count == 3, "\(phone.names)")
}

// --- 開 App 後等畫面穩定
do {
    let phone = FakePhone()
    let full = String(repeating: "x", count: 3000)
    phone.answers["screenshot"] = { n in (["data": .string(n < 3 ? "blank" : full)], nil) }
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .openApp, bundleId: "a"), ScriptStep(kind: .home)])
    waitDone(engine)
    check("空白畫面不算好了，要有內容又靜止", phone.names.filter { $0 == "screenshot" }.count == 5, "\(phone.names)")
    check("等完才做下一步", phone.names.last == "home", "\(phone.names)")
}
do {
    let phone = FakePhone()
    phone.answers["screenshot"] = { n in (["data": .string(String(repeating: "x", count: 3000 + n))], nil) }
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .openApp, bundleId: "a"), ScriptStep(kind: .home)])
    let s = waitDone(engine)
    check("畫面一直在動也不會卡死", s["state"]?.stringValue == "finished" && phone.names.last == "home", "\(s)")
}
do {
    let phone = FakePhone()
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .openApp, bundleId: "a", restart: true)])
    waitDone(engine)
    check("從頭開始會先關掉 App", phone.actions == ["terminate_app", "launch_app"], "\(phone.actions)")
}
do {
    let phone = FakePhone()
    phone.answers["terminate_app"] = { _ in (nil, .serverError("still running")) }
    let engine = make(phone)
    _ = start(engine, [ScriptStep(kind: .openApp, bundleId: "a", restart: true)])
    check("關不掉還是繼續", waitDone(engine)["state"]?.stringValue == "finished")
}

// --- 壞資料
do {
    let phone = FakePhone()
    let engine = make(phone)
    check("空腳本被擋", engine.handle(method: "script_run", params: ["steps": .array([])]).1 != nil)
    check("沒有 steps 被擋", engine.handle(method: "script_run", params: [:]).1 != nil)
    check("未知種類被擋", engine.handle(method: "script_run", params: ["steps": .array([.object(["kind": .string("explode")])])]).1 != nil)
    check("沒有 id 也能解", ScriptEngine.decodeSteps(.array([.object(["kind": .string("home")])]))?.count == 1)
    _ = start(engine, [ScriptStep(kind: .tap)])
    check("沒座標會失敗不會當", waitDone(engine)["state"]?.stringValue == "failed")
    _ = start(engine, [ScriptStep(kind: .tapText)])
    check("沒文字會失敗不會當", waitDone(engine)["state"]?.stringValue == "failed")
}

// --- 錄製
func recordRound(_ params: [String: JSONValue], phone: FakePhone) -> [String: JSONValue] {
    let engine = make(phone)
    let started = engine.handle(method: "rec_step", params: params)
    guard let id = started.0?["job_id"]?.stringValue else { return [:] }
    let end = Date().addingTimeInterval(5)
    while Date() < end {
        if let r = engine.handle(method: "rec_result", params: ["job_id": .string(id)]).0, r["state"]?.stringValue == "done" { return r }
        Thread.sleep(forTimeInterval: 0.002)
    }
    return [:]
}
do {
    let phone = FakePhone()
    phone.answers["screenshot"] = { _ in (["data": .string("abc"), "point_width": .int(390), "point_height": .int(844), "bytes": .int(3)], nil) }
    phone.answers["screen_text"] = { _ in (["items": .array([box("確定")])], nil) }
    phone.answers["foreground_app"] = { _ in (["bundle_id": .string("com.example.next")], nil) }
    let step = steps([ScriptStep(kind: .tap, x: 5, y: 6)])
    guard case .array(let one) = step else { fatalError() }
    let r = recordRound(["step": one[0], "bundle_id": .string("com.example.app"), "return_bundle_id": .string("com.me"),
                         "return_url": .string("me://back")], phone: phone)
    check("錄製順序：切過去→動作→截圖→查前景→切回來",
          phone.actions == ["launch_app", "tap", "screenshot", "foreground_app", "launch_app"], "\(phone.actions)")
    check("切過去的是目標", phone.calls[0].1["bundle_id"]?.stringValue == "com.example.app")
    check("切回來的是自己", phone.calls.last?.1["bundle_id"]?.stringValue == "com.me")
    check("回傳截圖", r["data"]?.stringValue == "abc" && r["point_width"]?.intValue == 390, "\(r)")
    check("回傳前景 App", r["foreground_app"]?.stringValue == "com.example.next", "\(r)")
    check("沒有錯誤", r["error"] == nil, "\(r)")
}
do {
    let phone = FakePhone()
    phone.answers["tap"] = { _ in (nil, .serverError("alert in the way")) }
    phone.answers["screenshot"] = { _ in (["data": .string("abc")], nil) }
    let step = steps([ScriptStep(kind: .tap, x: 5, y: 6)])
    guard case .array(let one) = step else { fatalError() }
    let r = recordRound(["step": one[0], "return_bundle_id": .string("com.me")], phone: phone)
    check("動作失敗還是有截圖", r["data"]?.stringValue == "abc", "\(r)")
    check("動作失敗有寫原因", r["error"]?.stringValue == "alert in the way", "\(r)")
    check("動作失敗還是切回來", phone.names.last == "launch_app", "\(phone.names)")
}
do {
    let phone = FakePhone()
    phone.answers["launch_app"] = { _ in (nil, .serverError("nope")) }
    let r = recordRound(["return_bundle_id": .string("com.me"), "return_url": .string("me://back")], phone: phone)
    check("切不回來改用網址", phone.names.last == "open_url", "\(phone.names)")
    check("網址成功就不算失敗", r["return_failed"] == nil)
}
do {
    let phone = FakePhone()
    _ = recordRound(["bundle_id": .string(ScriptEngine.springboard)], phone: phone)
    check("目標是主畫面時按 Home", phone.names.first == "home", "\(phone.names)")
}
do {
    let phone = FakePhone()
    let engine = make(phone)
    check("查不存在的工作會報錯", engine.handle(method: "rec_result", params: ["job_id": .string("x")]).1 != nil)
    check("壞步驟被擋", engine.handle(method: "rec_step", params: ["step": .string("x")]).1 != nil)
}

print("\(checks - failures) / \(checks) passed")
exit(failures == 0 ? 0 : 1)
