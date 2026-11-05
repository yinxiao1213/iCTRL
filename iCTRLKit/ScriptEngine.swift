import Foundation

/// What the engine needs from the runner. A protocol so the logic can be tested
/// without XCTest or a phone (Tests/ScriptEngine).
protocol ScriptDriver: AnyObject {
    /// Run one UI method through the same path an RPC takes. Blocks until done.
    func scriptPerform(_ method: String, _ params: [String: JSONValue]) -> ([String: JSONValue]?, JSONRPCError?)
    var scriptPhoneLocked: Bool { get }
    func scriptNotify(title: String, body: String)
}

/// Plays scripts and does the work behind on-phone recording.
///
/// It lives in the runner, not the app: the app is suspended the moment the
/// target app comes to the front, and the runner is the only process that keeps
/// running and can touch other apps. So every call returns at once and the work
/// carries on here; the app asks for the outcome when it is back.
final class ScriptEngine {
    typealias Reply = ([String: JSONValue]?, JSONRPCError?)

    static let methods: Set<String> = ["script_run", "script_stop", "script_status", "rec_step", "rec_result"]
    static let springboard = "com.apple.springboard"

    enum State: String { case idle, running, stopping, finished, failed, stopped }

    private enum Abort: Error {
        case stopped(String)
        case failed(String)
    }

    private struct Run {
        var state = State.idle
        var name = ""
        var stepIndex = 0
        var stepCount = 0
        var loop = 0
        var loops = 1
        var error: String?
        var detail: String?
    }

    private struct Job {
        let id: String
        var done = false
        var result: [String: JSONValue] = [:]
    }

    // Test seams: virtual time keeps the tests fast.
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Lets the reply reach the app before anything takes the screen from it.
    var startDelay: TimeInterval = 0.3
    /// Pause between steps. Most actions already wait for the screen to settle.
    var stepGap: TimeInterval = 0.4

    private weak var driver: ScriptDriver?
    private let queue = DispatchQueue(label: "com.openminis.ictrl.script")
    private let lock = NSLock()
    private var run = Run()
    private var job: Job?
    private var cancelled = false

    init(driver: ScriptDriver) {
        self.driver = driver
    }

    // MARK: - RPC

    func handle(method: String, params: [String: JSONValue]?) -> Reply {
        switch method {
        case "script_run": return startRun(params)
        case "script_stop": return stopRun()
        case "script_status": return (statusJSON(), nil)
        case "rec_step": return startJob(params)
        case "rec_result": return jobResult(params)
        default: return (nil, .methodNotFound)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var isBusy: Bool {
        run.state == .running || run.state == .stopping || (job != nil && job?.done == false)
    }

    static func decodeSteps(_ value: JSONValue?) -> [ScriptStep]? {
        guard let value = value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode([ScriptStep].self, from: data)
    }

    private static func decodeStep(_ value: JSONValue?) -> ScriptStep? {
        guard let value = value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(ScriptStep.self, from: data)
    }

    // MARK: - Playing

    private func startRun(_ params: [String: JSONValue]?) -> Reply {
        guard let steps = Self.decodeSteps(params?["steps"]), !steps.isEmpty else {
            return (nil, JSONRPCError(code: -32602, message: "script_run needs a non-empty 'steps' array", data: nil))
        }
        let loops = max(0, params?["loops"]?.intValue ?? 1)
        let name = params?["name"]?.stringValue ?? "腳本"

        let started: Bool = withLock {
            guard !isBusy else { return false }
            run = Run(state: .running, name: name, stepIndex: 0, stepCount: steps.count, loop: 1, loops: loops)
            cancelled = false
            return true
        }
        guard started else { return (nil, .serverError("已經有腳本在執行，請先停止它。")) }

        queue.async { [self] in play(steps, loops: loops, name: name) }
        return (statusJSON(), nil)
    }

    private func stopRun() -> Reply {
        withLock {
            cancelled = true
            if run.state == .running { run.state = .stopping }
        }
        return (statusJSON(), nil)
    }

    private func statusJSON() -> [String: JSONValue] {
        withLock {
            var out: [String: JSONValue] = [
                "state": .string(run.state.rawValue),
                "name": .string(run.name),
                "step_index": .int(run.stepIndex),
                "step_count": .int(run.stepCount),
                "loop": .int(run.loop),
                "loops": .int(run.loops),
            ]
            if let error = run.error { out["error"] = .string(error) }
            if let detail = run.detail { out["detail"] = .string(detail) }
            return out
        }
    }

    private func play(_ steps: [ScriptStep], loops: Int, name: String) {
        var current = 0
        do {
            try pause(startDelay)
            var loop = 0
            while loops == 0 || loop < loops {
                loop += 1
                var index = 0
                while index < steps.count {
                    try checkpoint()
                    current = index
                    let (shownIndex, shownLoop) = (index, loop)
                    withLock {
                        run.stepIndex = shownIndex
                        run.loop = shownLoop
                    }
                    let skip = try execute(steps[index])
                    index += 1 + skip
                    try pause(stepGap)
                }
            }
            finish(.finished, error: nil, detail: nil, title: "腳本完成", body: "「\(name)」跑完了。")
        } catch Abort.stopped(let reason) {
            finish(.stopped, error: nil, detail: reason, title: "腳本已停止", body: "「\(name)」：\(reason)")
        } catch Abort.failed(let message) {
            let text = "第 \(current + 1) 步失敗：\(message)"
            finish(.failed, error: text, detail: nil, title: "腳本失敗", body: "「\(name)」\(text)")
        } catch {
            let text = "第 \(current + 1) 步失敗：\(error.localizedDescription)"
            finish(.failed, error: text, detail: nil, title: "腳本失敗", body: "「\(name)」\(text)")
        }
    }

    private func finish(_ state: State, error: String?, detail: String?, title: String, body: String) {
        withLock {
            run.state = state
            run.error = error
            run.detail = detail
        }
        driver?.scriptNotify(title: title, body: body)
    }

    /// Between any two actions: the way out.
    ///
    /// Locking the phone is the emergency stop, because while a script runs the
    /// app is not on screen and the side button is the one control that always
    /// works.
    private func checkpoint() throws {
        if withLock({ cancelled }) { throw Abort.stopped("手動停止") }
        if driver?.scriptPhoneLocked == true { throw Abort.stopped("手機鎖定了") }
    }

    /// A wait that still honours `checkpoint`, however long it is.
    private func pause(_ seconds: TimeInterval) throws {
        let end = now() + seconds
        var left = seconds
        while left > 0 {
            try checkpoint()
            sleep(min(left, 0.2))
            left = end - now()
        }
    }

    @discardableResult
    private func call(_ method: String, _ params: [String: JSONValue] = [:]) throws -> [String: JSONValue] {
        guard let driver = driver else { throw Abort.failed("runner 已結束") }
        let (result, error) = driver.scriptPerform(method, params)
        if let error = error { throw Abort.failed(error.message) }
        return result ?? [:]
    }

    private func point(_ step: ScriptStep) throws -> [String: JSONValue] {
        guard let x = step.x, let y = step.y else { throw Abort.failed("這一步沒有座標") }
        return ["x": .double(x), "y": .double(y)]
    }

    /// Returns how many of the following steps to skip.
    @discardableResult
    private func execute(_ step: ScriptStep) throws -> Int {
        switch step.kind {
        case .openApp:
            guard let id = step.bundleId, !id.isEmpty else { throw Abort.failed("沒有指定 App") }
            // Best effort: a replay from the wrong screen beats no replay.
            if step.restart == true { _ = try? call("terminate_app", ["bundle_id": .string(id)]) }
            try call("launch_app", ["bundle_id": .string(id)])
            try waitForStillScreen(limit: 8)
        case .tap:
            try call("tap", try point(step))
        case .doubleTap:
            try call("double_tap", try point(step))
        case .longPress:
            var params = try point(step)
            params["duration"] = .double(step.duration ?? 1)
            try call("long_press", params)
        case .swipe:
            guard let x = step.x, let y = step.y, let toX = step.toX, let toY = step.toY else {
                throw Abort.failed("這一步沒有座標")
            }
            try call("drag", ["from_x": .double(x), "from_y": .double(y),
                              "to_x": .double(toX), "to_y": .double(toY),
                              "duration": .double(step.duration ?? 0.3)])
        case .type:
            var params: [String: JSONValue] = ["text": .string(step.text ?? "")]
            if step.clear == true { params["clear"] = .bool(true) }
            if step.submit == true { params["submit"] = .bool(true) }
            try call("type", params)
        case .wait:
            try pause(step.duration ?? 1)
        case .home:
            try call("home")
        case .waitText:
            let text = try wanted(step)
            guard try look(for: text, timeout: step.timeout ?? 30) != nil else {
                throw Abort.failed("等了 \(Self.seconds(step.timeout ?? 30)) 秒都沒看到「\(text)」")
            }
        case .tapText:
            let text = try wanted(step)
            var spot: (x: Double, y: Double)?
            if let x = step.x, let y = step.y { spot = (x, y) }
            let hit = try look(for: text, timeout: step.timeout ?? 30, near: spot) ?? spot
            guard let target = hit else {
                throw Abort.failed("等了 \(Self.seconds(step.timeout ?? 30)) 秒都沒看到「\(text)」")
            }
            try call("tap", ["x": .double(target.x), "y": .double(target.y)])
        case .ifText:
            let seen = try look(for: try wanted(step), timeout: step.timeout ?? 0) != nil
            return seen != (step.negate == true) ? 0 : max(0, step.skip ?? 1)
        }
        return 0
    }

    /// Wait until the screen holds still, or `limit` runs out.
    ///
    /// A cold-started app shows a blank page or a splash for seconds, and a tap
    /// or a picture taken then is wasted. Small frames are compared: identical
    /// JPEGs mean nothing moved, and a tiny one is a screen with nothing on it yet.
    private func waitForStillScreen(limit: TimeInterval) throws {
        let end = now() + limit
        var previous: String?
        while now() < end {
            try checkpoint()
            let frame = try? call("screenshot", ["scale": .double(Self.frameScale), "format": .string("jpeg"),
                                                 "quality": .double(0.3)])
            guard let data = frame?["data"]?.stringValue else { return }
            if data == previous, data.count >= Self.blankFrameSize { return }
            previous = data
            try pause(0.4)
        }
    }

    static let frameScale = 0.25
    /// Base64 length under which a frame at `frameScale` counts as blank.
    private static let blankFrameSize = 2000

    private func wanted(_ step: ScriptStep) throws -> String {
        guard let text = step.text, !text.isEmpty else { throw Abort.failed("這一步沒有指定文字") }
        return text
    }

    private static func seconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Read the screen until the text shows up or time runs out.
    ///
    /// Asks for every text box and matches here instead of passing `element_id`:
    /// OCR often puts spaces inside Chinese ("登 入"), and the runner's filter
    /// is a plain substring test.
    private func look(for text: String, timeout: TimeInterval,
                      near spot: (x: Double, y: Double)? = nil) throws -> (x: Double, y: Double)? {
        let end = now() + timeout
        while true {
            try checkpoint()
            let result = try call("screen_text")
            if let hit = Self.bestMatch(result["items"], text: text, near: spot) { return hit }
            if now() >= end { return nil }
            try pause(0.5)
        }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    /// Where to tap for `text`. An exact box beats one that only contains it;
    /// inside a longer line the tap aims at the words, not the line's middle.
    /// Among equals the one nearest `spot` wins, else the first.
    static func bestMatch(_ value: JSONValue?, text: String,
                          near spot: (x: Double, y: Double)? = nil) -> (x: Double, y: Double)? {
        guard case .array(let items)? = value else { return nil }
        let want = normalize(text)
        guard !want.isEmpty else { return nil }
        var exact: [(x: Double, y: Double)] = []
        var partial: [(x: Double, y: Double)] = []
        for item in items {
            guard let box = item.objectValue, let label = box["label"]?.stringValue,
                  let cx = box["center_x"]?.doubleValue, let cy = box["center_y"]?.doubleValue else { continue }
            let have = normalize(label)
            if have == want {
                exact.append((cx, cy))
                continue
            }
            guard let range = have.range(of: want) else { continue }
            let before = Double(have.distance(from: have.startIndex, to: range.lowerBound))
            let share = (before + Double(want.count) / 2) / Double(have.count)
            if let x = box["x"]?.doubleValue, let width = box["width"]?.doubleValue {
                partial.append((x + width * share, cy))
            } else {
                partial.append((cx, cy))
            }
        }
        let pool = exact.isEmpty ? partial : exact
        guard let spot = spot else { return pool.first }
        return pool.min { hypot($0.x - spot.x, $0.y - spot.y) < hypot($1.x - spot.x, $1.y - spot.y) }
    }

    // MARK: - Recording

    /// One recording round: go to the target app, do the step, capture what the
    /// screen shows now, and come back to the app that asked.
    private func startJob(_ params: [String: JSONValue]?) -> Reply {
        var step: ScriptStep?
        if let raw = params?["step"] {
            guard let decoded = Self.decodeStep(raw) else {
                return (nil, JSONRPCError(code: -32602, message: "rec_step: 'step' is not a valid step", data: nil))
            }
            step = decoded
        }
        let target = params?["bundle_id"]?.stringValue
        let returnBundle = params?["return_bundle_id"]?.stringValue
        let returnURL = params?["return_url"]?.stringValue
        let settle = params?["settle"]?.doubleValue ?? 0.6
        let scale = params?["scale"]?.doubleValue ?? 2

        let id = UUID().uuidString
        let started: Bool = withLock {
            guard !isBusy else { return false }
            job = Job(id: id)
            cancelled = false
            return true
        }
        guard started else { return (nil, .serverError("手機正在忙，請稍等。")) }

        queue.async { [self] in
            var out = record(step, target: target, settle: settle, scale: scale)
            goBack(bundle: returnBundle, url: returnURL, into: &out)
            withLock {
                job?.done = true
                job?.result = out
            }
        }
        return (["job_id": .string(id)], nil)
    }

    private func record(_ step: ScriptStep?, target: String?, settle: TimeInterval, scale: Double) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        do {
            try pause(startDelay)
            if let target = target {
                if target == Self.springboard {
                    try call("home")
                } else {
                    try call("launch_app", ["bundle_id": .string(target)])
                }
            }
            if let step = step { try execute(step) }
            try pause(settle)
            try waitForStillScreen(limit: 3)
        } catch Abort.failed(let message) {
            out["error"] = .string(message)
        } catch Abort.stopped(let reason) {
            out["error"] = .string(reason)
        } catch {
            out["error"] = .string(error.localizedDescription)
        }

        // Captured even after a failure: the screen is what explains it.
        do {
            let shot = try call("screenshot", ["scale": .double(scale), "format": .string("jpeg"), "quality": .double(0.6)])
            for key in ["data", "point_width", "point_height"] { out[key] = shot[key] }
        } catch Abort.failed(let message) {
            if out["error"] == nil { out["error"] = .string(message) }
        } catch {}
        // Optional: recording still works without it. Text on the picture is
        // read by the app, so this round doesn't have to wait for it.
        if let front = try? call("foreground_app") { out["foreground_app"] = front["bundle_id"] }
        return out
    }

    private func goBack(bundle: String?, url: String?, into out: inout [String: JSONValue]) {
        if let bundle = bundle, !bundle.isEmpty, (try? call("launch_app", ["bundle_id": .string(bundle)])) != nil { return }
        if let url = url, !url.isEmpty, (try? call("open_url", ["url": .string(url)])) != nil { return }
        if bundle != nil || url != nil { out["return_failed"] = .bool(true) }
    }

    private func jobResult(_ params: [String: JSONValue]?) -> Reply {
        guard let id = params?["job_id"]?.stringValue else {
            return (nil, JSONRPCError(code: -32602, message: "rec_result needs 'job_id'", data: nil))
        }
        return withLock {
            guard let job = job, job.id == id else { return (nil, .serverError("找不到這個錄製工作。")) }
            guard job.done else { return (["state": .string("running")], nil) }
            var out = job.result
            out["state"] = .string("done")
            return (out, nil)
        }
    }
}
