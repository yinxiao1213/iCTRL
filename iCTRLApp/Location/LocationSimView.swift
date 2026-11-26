import MapKit
import SwiftUI
import UIKit

/// 虛擬定位: pick a point on the map, teleport or walk there, steer with a
/// joystick, keep favorites, and go back to the real location.
struct LocationSimView: View {
    @EnvironmentObject private var loc: LocationController

    @State private var follow = true
    @State private var center: LocationMapView.CenterRequest?
    @State private var showStick = false
    @State private var showFavorites = false
    @State private var showSettings = false
    @State private var showCoordinates = false
    @State private var showAddFavorite = false
    @State private var showMount = false
    @State private var favoriteName = ""
    @State private var coordinateText = ""
    @State private var coordinateError = false
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var ddi = DeveloperDiskImage.status()
    @State private var tunnel: LocalDevVPN.TunnelProbe?
    @FocusState private var searchFocused: Bool

    private var status: LocationStatus { loc.status }

    var body: some View {
        ZStack(alignment: .top) {
            LocationMapView(target: loc.target, position: status.isActive ? status.position : nil,
                            route: status.route, favorites: loc.favorites, follow: follow,
                            center: center,
                            onTap: { point in
                                searchFocused = false
                                results = []
                                loc.target = point
                            },
                            onUserPan: { follow = false })
                .ignoresSafeArea(edges: [.top, .horizontal])

            VStack(spacing: 8) {
                statusCard
                searchBar
                if !results.isEmpty { resultList }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    if showStick {
                        JoystickPad { dx, dy in loc.joystick(dx: dx, dy: dy) }
                            .padding(.leading, 4)
                    }
                    Spacer()
                    mapButtons
                }
                panel
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .onAppear {
            loc.watchMap(true)
            refreshChecks()
        }
        .onDisappear { loc.watchMap(false) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshChecks()
        }
        .onChange(of: status.isActive) { active in
            if active { follow = true }
        }
        .sheet(isPresented: $showFavorites) { favoritesSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showMount, onDismiss: refreshChecks) { DDIMountView() }
        .alert("輸入座標", isPresented: $showCoordinates) {
            TextField("25.033964, 121.564468", text: $coordinateText)
            Button("確定") { applyCoordinates() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("緯度, 經度；也可以貼 Google 地圖或 Apple 地圖的連結。")
        }
        .alert("座標看不懂", isPresented: $coordinateError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("請輸入像「25.033964, 121.564468」這樣的緯度和經度。")
        }
        .alert("收藏這裡", isPresented: $showAddFavorite) {
            TextField("名稱", text: $favoriteName)
            Button("儲存") {
                if let p = favoriteCandidate { loc.addFavorite(name: favoriteName, point: p) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(favoriteCandidate?.text ?? "")
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let check = systemCheck {
                    Text(check)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let notice = loc.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
            }
            .accessibilityLabel("保活設定")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusColor: Color {
        switch status.link {
        case .off: return .gray
        case .connecting: return .blue
        case .live: return .green
        case .retrying: return .orange
        }
    }

    private var statusTitle: String {
        switch status.link {
        case .off: return "真實定位"
        case .connecting: return "連線中…"
        case .live: return status.simulated == nil ? "連線中…" : "假定位中"
        case .retrying: return "連線中斷，重連中"
        }
    }

    private var statusDetail: String {
        switch status.link {
        case .off:
            if let last = loc.lastPoint { return "手機回報真實位置。上次假定位在 \(last.text)" }
            return "手機回報真實位置。在地圖上點一下選目標，再按「瞬移」或「走過去」。"
        case .connecting:
            return "正在連接手機的開發者服務…"
        case .live:
            let here = status.simulated?.text ?? ""
            switch status.motion {
            case .still:
                return "停在 \(here)"
            case .walking:
                let minutes = status.speed > 0 ? Int((status.remainingMeters / status.speed / 60).rounded(.up)) : 0
                return "\(Self.motionWord(status.speed))中，還有 \(Self.meters(status.remainingMeters))（約 \(max(minutes, 1)) 分鐘）"
            case .joystick:
                return "用搖桿移動中 · \(here)"
            }
        case .retrying:
            var text = "第 \(status.failures) 次重試。斷線期間手機回報的是真實位置。"
            if let e = status.lastError { text += "\n\(e)" }
            return text
        }
    }

    /// Whether what iOS reports matches what we sent: the proof it took.
    private var systemCheck: String? {
        // The simulator's stand-in never moves the reported location.
        guard !LocationController.isSimulator,
              status.isFake, let fake = status.simulated, let sys = loc.systemLocation else { return nil }
        let d = GeoMath.distance(fake, sys)
        if d < 25 { return "✓ 系統回報的位置就是假定位" }
        if status.motion != .still { return "系統回報的位置跟在後面（差 \(Self.meters(d))）" }
        return "系統回報的位置還差 \(Self.meters(d))，等幾秒再看"
    }

    static func meters(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.1f 公里", m / 1000) : "\(Int(m.rounded())) 公尺"
    }

    static func motionWord(_ speed: Double) -> String {
        if speed >= TravelSpeed.drive.metersPerSecond - 0.01 { return "開車" }
        if speed >= TravelSpeed.bike.metersPerSecond - 0.01 { return "騎車" }
        return "步行"
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("搜尋地點", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { Task { await search() } }
            if searching { ProgressView() }
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .accessibilityLabel("清除搜尋")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(results.prefix(6).enumerated()), id: \.offset) { _, item in
                Button {
                    let c = item.placemark.coordinate
                    let p = GeoPoint(c)
                    loc.target = p
                    follow = false
                    center = .init(point: p, zoomMeters: 800)
                    results = []
                    searchFocused = false
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name ?? "地點").font(.subheadline)
                        if let address = item.placemark.title {
                            Text(address).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        // Coordinates typed into the search box work too.
        if let p = CoordinateParser.parse(text) {
            loc.target = p
            follow = false
            center = .init(point: p, zoomMeters: 800)
            return
        }
        searching = true
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let around = status.position ?? loc.systemLocation ?? loc.target {
            request.region = MKCoordinateRegion(center: around.coordinate, latitudinalMeters: 50_000,
                                                longitudinalMeters: 50_000)
        }
        do {
            results = try await MKLocalSearch(request: request).start().mapItems
            if results.isEmpty { loc.notice = "找不到「\(text)」。" }
        } catch {
            results = []
            loc.notice = "搜尋失敗：\(error.localizedDescription)"
        }
    }

    // MARK: - Map buttons

    private var mapButtons: some View {
        VStack(spacing: 8) {
            Button {
                if let p = status.isActive ? status.position : (loc.systemLocation ?? loc.target) {
                    follow = status.isActive
                    center = .init(point: p)
                }
            } label: {
                Image(systemName: follow && status.isActive ? "location.fill" : "location")
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("回到目前位置")
            Button {
                showFavorites = true
            } label: {
                Image(systemName: "star")
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("收藏清單")
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "mappin.circle.fill").foregroundColor(.red)
                Text(loc.target.map { "目標 \($0.text)" } ?? "在地圖上點一下選目標")
                    .font(.footnote.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Button("輸入座標") {
                    coordinateText = ""
                    showCoordinates = true
                }
                .font(.footnote)
            }

            HStack(spacing: 6) {
                ForEach(TravelSpeed.allCases, id: \.self) { s in
                    Button {
                        loc.speed = s
                    } label: {
                        Label("\(s.label) \(s.kmh)", systemImage: s.symbol)
                            .font(.caption.weight(loc.speed == s ? .bold : .regular))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(loc.speed == s ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(s.label)
                    .accessibilityAddTraits(loc.speed == s ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Button {
                    loc.followRoads.toggle()
                } label: {
                    Text(loc.followRoads ? "沿道路" : "走直線")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc.followRoads ? "沿道路" : "走直線")
            }

            HStack(spacing: 8) {
                Button {
                    if let t = loc.target { loc.teleport(to: t) }
                } label: {
                    Label("瞬移", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loc.target == nil)

                if status.motion == .walking || status.motion == .joystick {
                    Button {
                        loc.stop()
                    } label: {
                        Label("停下", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        if let t = loc.target { Task { await loc.walk(to: t) } }
                    } label: {
                        Label(loc.planning ? "找路中…" : "走過去", systemImage: "figure.walk").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(loc.target == nil || loc.planning)
                }
            }
            .controlSize(.large)

            HStack(spacing: 8) {
                Button {
                    showStick.toggle()
                    if !showStick { loc.joystick(dx: 0, dy: 0) }
                } label: {
                    Label("搖桿", systemImage: showStick ? "gamecontroller.fill" : "gamecontroller")
                }
                .buttonStyle(.bordered)

                Button {
                    favoriteName = loc.defaultFavoriteName
                    showAddFavorite = true
                } label: {
                    Label("收藏這裡", systemImage: "star")
                }
                .buttonStyle(.bordered)
                .disabled(favoriteCandidate == nil)

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    showStick = false
                    loc.restore()
                } label: {
                    Label("恢復真實定位", systemImage: "location.slash")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .disabled(!status.isActive)
            }
            .controlSize(.small)

            checks
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Favorites save the target if there is one, else where the phone is.
    private var favoriteCandidate: GeoPoint? {
        loc.target ?? (status.isActive ? status.position : nil)
    }

    private func applyCoordinates() {
        guard let p = CoordinateParser.parse(coordinateText) else {
            coordinateError = true
            return
        }
        loc.target = p
        follow = false
        center = .init(point: p, zoomMeters: 800)
    }

    // MARK: - What has to be ready

    @ViewBuilder
    private var checks: some View {
        if LocationController.isSimulator {
            Text("模擬器測試模式：不會真的改手機位置。")
                .font(.caption2)
                .foregroundColor(.secondary)
        } else {
            if !ddi.isMounted {
                checkRow("開發者映像還沒掛載（重開機後要再掛）", action: "掛載") { showMount = true }
            }
            if let tunnel, tunnel != .reachable {
                checkRow(tunnel == .localNetworkDenied ? "iCTRL 的區域網路權限被關掉了" : "LocalDevVPN 沒連上",
                         action: tunnel == .localNetworkDenied ? "去設定" : "連線") {
                    if tunnel == .localNetworkDenied {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    } else {
                        UIApplication.shared.open(LocalDevVPN.enableURL) { ok in
                            if !ok { UIApplication.shared.open(LocalDevVPN.appStoreURL) }
                        }
                    }
                }
            }
            if loc.keepAliveState.locationDenied && !loc.audioKeepAlive {
                checkRow("定位權限被拒、背景音訊也關了：切到遊戲後會斷線", action: "設定") { showSettings = true }
            }
        }
    }

    private func checkRow(_ text: String, action: String, _ perform: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action, action: perform).font(.caption).buttonStyle(.bordered).controlSize(.mini)
        }
    }

    private func refreshChecks() {
        ddi = DeveloperDiskImage.status()
        guard !LocationController.isSimulator else { return }
        Task { tunnel = await LocalDevVPN.probeTunnel() }
    }

    // MARK: - Sheets

    private var favoritesSheet: some View {
        NavigationStack {
            List {
                if loc.favorites.isEmpty {
                    Text("還沒有收藏。選好目標後按「收藏這裡」。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(loc.favorites) { fav in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fav.name)
                            Text(fav.point.text).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("選這裡") {
                            loc.target = fav.point
                            follow = false
                            center = .init(point: fav.point, zoomMeters: 800)
                            showFavorites = false
                        }
                        .buttonStyle(.bordered)
                        Button("瞬移") {
                            loc.target = fav.point
                            loc.teleport(to: fav.point)
                            center = .init(point: fav.point, zoomMeters: 800)
                            showFavorites = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .contextMenu {
                        Button("複製座標") { UIPasteboard.general.string = fav.point.text }
                    }
                }
                .onDelete { loc.removeFavorites(at: $0) }
            }
            .navigationTitle("收藏清單")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { showFavorites = false } }
            }
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section {
                    keepAliveRow("背景音訊", detail: "播放無聲音訊（和遊戲的聲音混在一起，不會打斷）。",
                                 on: loc.audioKeepAlive, running: loc.keepAliveState.audio) {
                        loc.audioKeepAlive.toggle()
                    }
                    keepAliveRow("背景定位", detail: "持續接收定位，狀態列會出現藍色定位標示。需要定位權限。",
                                 on: loc.locationKeepAlive, running: loc.keepAliveState.location) {
                        loc.locationKeepAlive.toggle()
                    }
                    if loc.keepAliveState.locationDenied {
                        Button("定位權限被拒：去設定打開") {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        }
                        .font(.footnote)
                    }
                } header: {
                    Text("切到遊戲後保持連線")
                } footer: {
                    Text("假定位靠 iCTRL 一直連著手機的開發者服務，連線一斷，手機就回到真實位置。iCTRL 切到背景會被 iOS 暫停，所以要用這兩種方式讓它繼續跑。兩個都開最保險。")
                }

                Section {
                    Text("• 每次重開機後：先開 LocalDevVPN 連線，再到「設定」掛載開發者映像。")
                    Text("• 搖桿只能在 iCTRL 畫面裡用。切到遊戲前可以先按「走過去」，iCTRL 會在背景自己走。")
                    Text("• iCTRL 被系統關掉（記憶體不夠、從多工畫面滑掉）時定位會回到真實位置；重新打開 iCTRL 再瞬移一次就好。")
                    Text("• 斷線時會發通知。")
                } header: {
                    Text("說明")
                }
                .font(.footnote)
            }
            .navigationTitle("保活設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } }
            }
        }
    }

    /// A button, not a Toggle: it reads its state in the label, and a tap
    /// anywhere on the row flips it.
    private func keepAliveRow(_ title: String, detail: String, on: Bool, running: Bool,
                              _ flip: @escaping () -> Void) -> some View {
        Button(action: flip) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(.primary)
                    Text(detail).font(.caption).foregroundColor(.secondary)
                    if on && status.isActive {
                        Text(running ? "運作中" : "沒在運作").font(.caption2).foregroundColor(running ? .green : .orange)
                    }
                }
                Spacer()
                Text(on ? "開" : "關")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(on ? .green : .secondary)
            }
        }
        .accessibilityLabel("\(title)：\(on ? "開" : "關")")
    }
}
