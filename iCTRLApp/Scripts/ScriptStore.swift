import Foundation
import UIKit

/// A script as the app keeps it. The runner only ever sees its steps.
struct SavedScript: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var steps: [ScriptStep] = []
    /// Times to play it; 0 = until stopped.
    var loops = 1
    var updatedAt = Date()
}

/// Scripts on disk: one JSON file each, in Documents/Scripts.
@MainActor
final class ScriptStore: ObservableObject {
    @Published private(set) var scripts: [SavedScript] = []

    private let folder: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Scripts", isDirectory: true)
    }()

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        scripts = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SavedScript.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func script(id: UUID) -> SavedScript? {
        scripts.first { $0.id == id }
    }

    func save(_ script: SavedScript) {
        var copy = script
        copy.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(copy)
            try data.write(to: url(for: copy.id), options: .atomic)
        } catch {
            ictrlLog("Could not save script: \(error.localizedDescription)")
            return
        }
        if let index = scripts.firstIndex(where: { $0.id == copy.id }) {
            scripts[index] = copy
        } else {
            scripts.insert(copy, at: 0)
        }
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        scripts.removeAll { $0.id == id }
    }

    private func url(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }
}

/// Talks to the script engine in the runner.
@MainActor
final class ScriptController: ObservableObject {
    struct Progress: Equatable {
        var state: String
        var name: String
        var stepIndex: Int
        var stepCount: Int
        var loop: Int
        var loops: Int
        var error: String?
        var detail: String?

        var isActive: Bool { state == "running" || state == "stopping" }
    }

    @Published private(set) var progress: Progress?
    @Published var notice: String?

    private let admin: RunnerAdmin
    private var polling: Task<Void, Never>?

    /// The runner registers this scheme; opening it starts the automation server.
    static let startRunnerURL = URL(string: "ictrl://start?callback=ictrl-app://started")!

    init(admin: RunnerAdmin) {
        self.admin = admin
    }

    static func runLink(for id: UUID) -> String {
        "ictrl-app://run?id=\(id.uuidString)"
    }

    func run(_ script: SavedScript) async {
        notice = nil
        guard !script.steps.isEmpty else {
            notice = "這個腳本還沒有步驟。"
            return
        }
        do {
            let steps = try ScriptJSON.object(script.steps)
            let reply = try await admin.rpc("script_run", ["steps": steps, "loops": script.loops, "name": script.name])
            progress = Self.parse(reply)
            startPolling()
        } catch {
            notice = ScriptJSON.message(error)
        }
    }

    /// Opened from a Home Screen shortcut: the runner may not be up yet.
    func runFromLink(_ script: SavedScript) async {
        if !(await Self.runnerIsUp()) {
            _ = await UIApplication.shared.open(Self.startRunnerURL)
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if await Self.runnerIsUp() { break }
            }
        }
        await run(script)
    }

    func stop() async {
        do {
            progress = Self.parse(try await admin.rpc("script_stop"))
        } catch {
            notice = ScriptJSON.message(error)
        }
    }

    func refresh() async {
        guard admin.isPaired, let reply = try? await admin.rpc("script_status") else { return }
        let next = Self.parse(reply)
        progress = next.state == "idle" ? nil : next
        if next.isActive { startPolling() }
    }

    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self else { return }
                await self.refresh()
                if self.progress?.isActive != true { break }
            }
            self?.polling = nil
        }
    }

    private static func runnerIsUp() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8200/schema")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func parse(_ reply: [String: Any]) -> Progress {
        Progress(state: reply["state"] as? String ?? "idle",
                 name: reply["name"] as? String ?? "",
                 stepIndex: reply["step_index"] as? Int ?? 0,
                 stepCount: reply["step_count"] as? Int ?? 0,
                 loop: reply["loop"] as? Int ?? 0,
                 loops: reply["loops"] as? Int ?? 1,
                 error: reply["error"] as? String,
                 detail: reply["detail"] as? String)
    }
}

enum ScriptJSON {
    /// Encodable to what JSONSerialization (and so `RunnerClient.call`) takes.
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    static func message(_ error: Error) -> String {
        switch error as? RunnerClient.Failure {
        case .notRunning: return "自動化服務沒有在執行，請先啟動。"
        case .notPaired, .keyRejected: return "App 還沒連上自動化服務，請先按「連接」。"
        default: return error.localizedDescription
        }
    }
}

extension ScriptStep {
    var title: String {
        switch kind {
        case .openApp: return "打開「\(appName ?? bundleId ?? "?")」"
        case .tap: return "點一下 \(Self.spot(x, y))"
        case .doubleTap: return "連點兩下 \(Self.spot(x, y))"
        case .longPress: return "長按 \(Self.spot(x, y)) \(Self.number(duration ?? 1)) 秒"
        case .swipe: return "滑動 \(Self.spot(x, y)) → \(Self.spot(toX, toY))"
        case .type: return "輸入「\(text ?? "")」"
        case .wait: return "等 \(Self.number(duration ?? 1)) 秒"
        case .home: return "回主畫面"
        case .waitText: return "等畫面出現「\(text ?? "")」，最多 \(Self.number(timeout ?? 30)) 秒"
        case .tapText: return "點畫面上的「\(text ?? "")」，最多等 \(Self.number(timeout ?? 30)) 秒"
        case .ifText:
            let what = negate == true ? "沒看到" : "看到"
            return "\(what)「\(text ?? "")」才做下面 \(skip ?? 1) 步"
        }
    }

    var symbol: String {
        switch kind {
        case .openApp: return "app.badge"
        case .tap: return "hand.tap"
        case .doubleTap: return "hand.tap.fill"
        case .longPress: return "hand.point.up.left"
        case .swipe: return "hand.draw"
        case .type: return "keyboard"
        case .wait: return "clock"
        case .home: return "house"
        case .waitText: return "eye"
        case .tapText: return "text.viewfinder"
        case .ifText: return "arrow.triangle.branch"
        }
    }

    private static func spot(_ x: Double?, _ y: Double?) -> String {
        "(\(Int(x ?? 0)), \(Int(y ?? 0)))"
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
