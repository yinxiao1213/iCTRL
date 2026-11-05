import SwiftUI
import UIKit
import Vision

/// Recording, inside the app.
///
/// iOS lets no app see touches meant for another one, so the target app can't
/// be watched while you use it. Instead its screen is shown here as a picture,
/// and the picture behaves like the phone: a tap, a long press or a swipe on it
/// is recorded, then the runner does the same thing in the real app, takes a new
/// picture and comes back.
struct RecorderView: View {
    @Binding var script: SavedScript
    @EnvironmentObject private var admin: RunnerAdmin
    @Environment(\.dismiss) private var dismiss

    struct TextBox: Identifiable {
        let id = UUID()
        let label: String
        let rect: CGRect
    }

    struct Shot {
        let image: UIImage
        let size: CGSize
        /// Filled in shortly after the picture arrives.
        var boxes: [TextBox] = []
    }

    enum Mode: String, CaseIterable, Identifiable {
        case touch = "操作"
        case tapText = "點文字"
        case waitText = "等文字"
        case ifText = "看到才做"
        var id: String { rawValue }
    }

    @State private var shot: Shot?
    /// App the next round goes to; nil until one is chosen.
    @State private var target: String?
    @State private var mode = Mode.touch
    @State private var busy = false
    @State private var notice: String?
    @State private var showPicker = false
    @State private var askText = false
    @State private var typed = ""
    @State private var askWait = false
    @State private var waitSeconds = "2"
    @State private var doubleNext = false
    @State private var pressedAt: Date?

    var body: some View {
        VStack(spacing: 8) {
            header
            ZStack {
                if let shot = shot {
                    screen(shot)
                } else if !busy {
                    Text("還沒有畫面。按下方的「換 App」選一個 App。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                if busy {
                    ProgressView("手機操作中…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let notice = notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .padding(.horizontal)
            } else if mode != .touch, shot?.boxes.isEmpty == true {
                Text("還在認字，或這個畫面沒有文字。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Picker("模式", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            tools
        }
        .disabled(busy)
        .task { await begin() }
        .sheet(isPresented: $showPicker) {
            AppPickerView { app in
                let bundleId = app.bundleId
                if bundleId == ScriptEngine.springboard {
                    perform(ScriptStep(kind: .home))
                } else {
                    // The first app starts from its first screen, so a replay
                    // starts where this recording does.
                    perform(ScriptStep(kind: .openApp, bundleId: bundleId, appName: app.name,
                                       restart: script.steps.isEmpty ? true : nil))
                }
            }
            .environmentObject(admin)
        }
        .alert("輸入文字", isPresented: $askText) {
            TextField("文字", text: $typed)
            Button("輸入") { perform(ScriptStep(kind: .type, text: typed)) }
            Button("輸入並送出") { perform(ScriptStep(kind: .type, text: typed, submit: true)) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("要先點輸入框，鍵盤跳出來後再用這個。")
        }
        .alert("等幾秒？", isPresented: $askWait) {
            TextField("秒數", text: $waitSeconds)
                .keyboardType(.decimalPad)
            Button("加入") {
                script.steps.append(ScriptStep(kind: .wait, duration: Double(waitSeconds) ?? 2))
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Button("完成") { dismiss() }
                .font(.body.weight(.semibold))
            Spacer()
            Text("已錄 \(script.steps.count) 步")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Button("復原") {
                if !script.steps.isEmpty { script.steps.removeLast() }
            }
            .disabled(script.steps.isEmpty)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func screen(_ shot: Shot) -> some View {
        GeometryReader { geo in
            let area = Self.fit(shot.size, in: geo.size)
            let ratio = area.width / shot.size.width
            ZStack(alignment: .topLeading) {
                Color.clear
                Image(uiImage: shot.image)
                    .resizable()
                    .frame(width: area.width, height: area.height)
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.4)))
                    .offset(x: area.minX, y: area.minY)
                if mode != .touch {
                    ForEach(shot.boxes) { box in
                        Rectangle()
                            .stroke(Color.accentColor, lineWidth: 1.5)
                            .background(Color.accentColor.opacity(0.15))
                            .frame(width: box.rect.width * ratio, height: box.rect.height * ratio)
                            .offset(x: area.minX + box.rect.minX * ratio, y: area.minY + box.rect.minY * ratio)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if pressedAt == nil { pressedAt = Date() }
                    }
                    .onEnded { value in
                        let held = Date().timeIntervalSince(pressedAt ?? Date())
                        pressedAt = nil
                        touched(from: value.startLocation, to: value.location, held: held, area: area, shot: shot)
                    }
            )
        }
        .padding(.horizontal, 8)
    }

    private var tools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tool("重新截圖", "arrow.clockwise") {
                    Task { await round(step: nil, switchTo: target, record: false) }
                }
                tool("換 App", "app.badge") { showPicker = true }
                tool("輸入文字", "keyboard") {
                    typed = ""
                    askText = true
                }
                tool("等待", "clock") { askWait = true }
                tool(doubleNext ? "下一下連點" : "連點", "hand.tap.fill") { doubleNext.toggle() }
                tool("回主畫面", "house") { perform(ScriptStep(kind: .home)) }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private func tool(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                Text(title).font(.caption2)
            }
            .frame(minWidth: 58)
        }
        .buttonStyle(.bordered)
    }

    /// The largest rectangle with the screen's shape that fits, centred.
    private static func fit(_ size: CGSize, in box: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let ratio = min(box.width / size.width, box.height / size.height)
        let width = size.width * ratio
        let height = size.height * ratio
        return CGRect(x: (box.width - width) / 2, y: (box.height - height) / 2, width: width, height: height)
    }

    /// Picture coordinates to phone points; nil outside the picture.
    private func phonePoint(_ location: CGPoint, area: CGRect, shot: Shot) -> CGPoint? {
        guard area.width > 0, area.contains(location) else { return nil }
        let x = (location.x - area.minX) / area.width * shot.size.width
        let y = (location.y - area.minY) / area.height * shot.size.height
        return CGPoint(x: (x * 10).rounded() / 10, y: (y * 10).rounded() / 10)
    }

    private func touched(from start: CGPoint, to end: CGPoint, held: TimeInterval, area: CGRect, shot: Shot) {
        guard let from = phonePoint(start, area: area, shot: shot) else { return }
        guard mode == .touch else {
            pickText(at: from, shot: shot)
            return
        }
        let moved = hypot(end.x - start.x, end.y - start.y)
        if moved > 12 {
            let clamped = CGPoint(x: min(max(end.x, area.minX), area.maxX - 1), y: min(max(end.y, area.minY), area.maxY - 1))
            guard let to = phonePoint(clamped, area: area, shot: shot) else { return }
            perform(ScriptStep(kind: .swipe, x: from.x, y: from.y, toX: to.x, toY: to.y,
                               duration: min(max(held, 0.15), 2)))
        } else if held >= 0.6 {
            perform(ScriptStep(kind: .longPress, x: from.x, y: from.y, duration: min(held, 5)))
        } else if doubleNext {
            doubleNext = false
            perform(ScriptStep(kind: .doubleTap, x: from.x, y: from.y))
        } else {
            perform(ScriptStep(kind: .tap, x: from.x, y: from.y))
        }
    }

    private func pickText(at point: CGPoint, shot: Shot) {
        let hit = shot.boxes.first { $0.rect.insetBy(dx: -6, dy: -6).contains(point) }
        guard let box = hit else {
            notice = "這裡沒有認到文字，請點藍框。"
            return
        }
        notice = nil
        switch mode {
        case .touch:
            break
        case .tapText:
            perform(ScriptStep(kind: .tapText, text: box.label, timeout: 30))
        case .waitText:
            script.steps.append(ScriptStep(kind: .waitText, text: box.label, timeout: 30))
            mode = .touch
        case .ifText:
            script.steps.append(ScriptStep(kind: .ifText, text: box.label, timeout: 3, skip: 1))
            mode = .touch
        }
    }

    private func perform(_ step: ScriptStep) {
        // These two go somewhere by themselves.
        let opensItself = step.kind == .openApp || step.kind == .home
        Task { await round(step: step, switchTo: opensItself ? nil : target, record: true) }
    }

    private func begin() async {
        guard shot == nil else { return }
        if let last = script.steps.last(where: { $0.kind == .openApp || $0.kind == .home }) {
            target = last.kind == .home ? ScriptEngine.springboard : last.bundleId
            await round(step: nil, switchTo: target, record: false)
        } else {
            showPicker = true
        }
    }

    /// One trip to the target app and back.
    private func round(step: ScriptStep?, switchTo: String?, record: Bool) async {
        busy = true
        notice = nil
        defer { busy = false }
        var params: [String: Any] = ["return_url": "ictrl-app://recorded"]
        if let own = Bundle.main.bundleIdentifier { params["return_bundle_id"] = own }
        if let switchTo = switchTo { params["bundle_id"] = switchTo }
        do {
            if let step = step { params["step"] = try ScriptJSON.object(step) }
            let started = try await admin.rpc("rec_step", params)
            guard let job = started["job_id"] as? String else {
                notice = "手機沒有回應。"
                return
            }
            let result = try await waitForResult(job)
            apply(result, step: step, record: record)
        } catch {
            notice = ScriptJSON.message(error)
        }
    }

    /// Polls rather than waits on one request: this app was suspended for most
    /// of the round, and a request in flight doesn't survive that.
    private func waitForResult(_ job: String) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            do {
                let reply = try await admin.rpc("rec_result", ["job_id": job])
                if reply["state"] as? String == "done" { return reply }
            } catch RunnerClient.Failure.server(let message) {
                throw RunnerClient.Failure.server(message)
            } catch {
                continue
            }
        }
        throw RunnerClient.Failure.server("等太久了，手機沒有完成這一步。")
    }

    private func apply(_ result: [String: Any], step: ScriptStep?, record: Bool) {
        if let encoded = result["data"] as? String, let data = Data(base64Encoded: encoded),
           let image = UIImage(data: data) {
            let width = result["point_width"] as? Double ?? Double(result["point_width"] as? Int ?? 0)
            let height = result["point_height"] as? Double ?? Double(result["point_height"] as? Int ?? 0)
            let size = width > 0 && height > 0 ? CGSize(width: width, height: height) : image.size
            shot = Shot(image: image, size: size)
            Task {
                let boxes = await Self.readText(image, size: size)
                if shot?.image === image { shot?.boxes = boxes }
            }
        }
        if let error = result["error"] as? String {
            notice = "這一步沒有錄進去：\(error)"
            return
        }
        guard let step = step else { return }
        if record { script.steps.append(step) }
        switch step.kind {
        case .openApp:
            target = step.bundleId
        case .home:
            target = ScriptEngine.springboard
        default:
            // A step can land in another app (a link opening Safari). SpringBoard
            // here may just be a system alert over the app, so it doesn't count.
            let own = Bundle.main.bundleIdentifier
            if let front = result["foreground_app"] as? String, front != ScriptEngine.springboard, front != own {
                target = front
            }
        }
        mode = .touch
    }

    /// Text on the picture, in phone points.
    private static func readText(_ image: UIImage, size: CGSize) async -> [TextBox] {
        await Task.detached(priority: .userInitiated) {
            guard let cgImage = image.cgImage else { return [] }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["zh-Hant", "zh-Hans", "en-US"]
            try? VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]).perform([request])
            return (request.results ?? []).compactMap { observation -> TextBox? in
                guard let top = observation.topCandidates(1).first, top.confidence >= 0.3 else { return nil }
                // Vision's origin is bottom-left.
                let box = observation.boundingBox
                return TextBox(label: top.string,
                               rect: CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                            width: box.width * size.width, height: box.height * size.height))
            }
        }.value
    }
}

/// Choose the app to record in.
///
/// Searches by name because iOS 26 and later no longer let an app list what is
/// installed: the list here is only what the runner has opened before.
struct AppPickerView: View {
    struct App: Identifiable, Hashable {
        var id: String { bundleId }
        let name: String
        let bundleId: String
    }

    @EnvironmentObject private var admin: RunnerAdmin
    @Environment(\.dismiss) private var dismiss
    let onPick: (App) -> Void

    @State private var query = ""
    @State private var recent: [App] = []
    @State private var found: [App] = []
    @State private var searching = false
    @State private var notice: String?

    private static let builtIn = [
        App(name: "Safari", bundleId: "com.apple.mobilesafari"),
        App(name: "設定", bundleId: "com.apple.Preferences"),
        App(name: "App Store", bundleId: "com.apple.AppStore"),
        App(name: "訊息", bundleId: "com.apple.MobileSMS"),
        App(name: "備忘錄", bundleId: "com.apple.mobilenotes"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("App 名稱，例如 LINE", text: $query)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .onSubmit { Task { await search() } }
                        if searching {
                            ProgressView()
                        } else {
                            Button("搜尋") { Task { await search() } }
                                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if let notice = notice {
                        Text(notice).font(.footnote).foregroundColor(.orange)
                    }
                    ForEach(found) { row($0) }
                    if query.contains("."), !query.contains(" ") {
                        row(App(name: query, bundleId: query))
                    }
                } header: {
                    Text("搜尋 App")
                } footer: {
                    Text("會到 App Store 查這個 App 的代號，手機要能上網。")
                }
                Section("主畫面") {
                    row(App(name: "主畫面", bundleId: ScriptEngine.springboard))
                }
                if !recent.isEmpty {
                    Section("用過的") { ForEach(recent) { row($0) } }
                }
                Section("系統 App") { ForEach(Self.builtIn) { row($0) } }
            }
            .navigationTitle("選 App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await loadRecent() }
        }
    }

    private func row(_ app: App) -> some View {
        Button {
            dismiss()
            onPick(app)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).foregroundColor(.primary)
                Text(app.bundleId).font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private func loadRecent() async {
        guard let reply = try? await admin.rpc("list_apps") else { return }
        recent = Self.apps(reply["apps"])
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        notice = nil
        defer { searching = false }
        let region = (Locale.current.regionCode ?? "us").lowercased()
        var results: [App] = []
        var failure: Error?
        do {
            results = Self.apps(try await admin.rpc("resolve_app", ["text": text, "country": region, "distance": 10], timeout: 20)["apps"])
        } catch {
            failure = error
        }
        if results.isEmpty, let reply = try? await admin.rpc("resolve_app", ["text": text, "distance": 10], timeout: 20) {
            results = Self.apps(reply["apps"])
        }
        found = results
        if results.isEmpty {
            notice = failure.map(ScriptJSON.message) ?? "找不到這個 App。"
        }
    }

    private static func apps(_ value: Any?) -> [App] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["bundle_id"] as? String, !id.isEmpty else { return nil }
            let name = row["name"] as? String ?? ""
            return App(name: name.isEmpty ? id : name, bundleId: id)
        }
    }
}
