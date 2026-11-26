import Foundation
import MapKit
import UIKit
import UserNotifications

/// The location tab's state: the simulator, keeping the app alive, the
/// favorites, and what the system reports.
@MainActor
final class LocationController: ObservableObject {
    @Published private(set) var status = LocationStatus()
    /// The point picked on the map (or typed, searched, chosen from favorites).
    @Published var target: GeoPoint?
    @Published var speed: TravelSpeed {
        didSet {
            UserDefaults.standard.set(speed.rawValue, forKey: "locSpeed")
            engine.send(.setSpeed(speed.metersPerSecond))
        }
    }
    /// Walk along streets (Apple Maps directions) instead of a straight line.
    @Published var followRoads: Bool {
        didSet { UserDefaults.standard.set(followRoads, forKey: "locFollowRoads") }
    }
    @Published var audioKeepAlive: Bool {
        didSet { LocationKeepAlive.audioEnabled = audioKeepAlive; keepAlive.settingsChanged() }
    }
    @Published var locationKeepAlive: Bool {
        didSet { LocationKeepAlive.locationEnabled = locationKeepAlive; keepAlive.settingsChanged() }
    }
    @Published private(set) var favorites: [FavoritePlace] = []
    /// What CoreLocation reports right now — the fake point when it took.
    @Published private(set) var systemLocation: GeoPoint?
    @Published private(set) var keepAliveState = LocationKeepAlive.State()
    @Published private(set) var lastPoint: GeoPoint?
    @Published private(set) var planning = false
    /// A short message for the person; cleared by the next action.
    @Published var notice: String?

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private let engine: LocationSimulator
    private let keepAlive = LocationKeepAlive()
    private var lastSaved = Date.distantPast
    private var arrivals = 0
    private var outage = false
    private var askedNotifications = false

    init() {
        #if targetEnvironment(simulator)
        let backend: LocationBackend = SimulatorLocationBackend()
        #else
        let backend: LocationBackend = DVTLocationBackend()
        #endif
        engine = LocationSimulator(backend: backend)
        speed = TravelSpeed(rawValue: UserDefaults.standard.string(forKey: "locSpeed") ?? "") ?? .walk
        followRoads = UserDefaults.standard.object(forKey: "locFollowRoads") as? Bool ?? true
        audioKeepAlive = LocationKeepAlive.audioEnabled
        locationKeepAlive = LocationKeepAlive.locationEnabled
        favorites = FavoriteStore.load()
        lastPoint = UserDefaults.standard.data(forKey: "locLastPoint")
            .flatMap { try? JSONDecoder().decode(GeoPoint.self, from: $0) }

        engine.onStatus = { [weak self] s in
            Task { @MainActor in self?.update(s) }
        }
        keepAlive.onSystemLocation = { [weak self] p, _ in
            Task { @MainActor in self?.systemLocation = p }
        }
        keepAlive.onState = { [weak self] s in
            Task { @MainActor in self?.keepAliveState = s }
        }
    }

    // MARK: - Actions

    func teleport(to point: GeoPoint) {
        prepare()
        notice = nil
        engine.send(.teleport(point))
        ictrlLog("📍 teleport → \(point.text)")
    }

    /// Walk from where the phone is (fake, or else real) to `point`.
    func walk(to point: GeoPoint) async {
        let from = status.position ?? (status.isActive ? nil : systemLocation)
        guard let from else {
            notice = "還不知道你現在在哪：先瞬移到一個起點，或等地圖抓到你的位置。"
            return
        }
        prepare()
        notice = nil
        var points = [point]
        if followRoads {
            planning = true
            if let route = await Self.route(from: from, to: point, speed: speed) {
                points = route
            } else {
                notice = "找不到路線，改走直線。"
            }
            planning = false
        }
        if status.position == nil { points.insert(from, at: 0) }
        engine.send(.walk(points, speed: speed.metersPerSecond))
        ictrlLog("📍 walk → \(point.text), \(points.count) points, \(speed.rawValue)")
    }

    /// From the on-screen joystick: dx east, dy north, -1...1.
    func joystick(dx: Double, dy: Double) {
        if hypot(dx, dy) > 0.05 { prepare() }
        engine.send(.joystick(dx: dx, dy: dy, speed: speed.metersPerSecond))
    }

    func stop() { engine.send(.stop) }

    func restore() {
        engine.send(.restore)
        notice = "已恢復真實定位。"
        ictrlLog("📍 restore real location")
    }

    func watchMap(_ on: Bool) { keepAlive.watch(on) }

    // MARK: - Favorites

    func addFavorite(name: String, point: GeoPoint) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        favorites.insert(FavoritePlace(name: trimmed.isEmpty ? defaultFavoriteName : trimmed, point: point), at: 0)
        FavoriteStore.save(favorites)
    }

    func removeFavorites(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        FavoriteStore.save(favorites)
    }

    func renameFavorite(_ id: UUID, to name: String) {
        guard let i = favorites.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        favorites[i].name = trimmed
        FavoriteStore.save(favorites)
    }

    var defaultFavoriteName: String { "收藏 \(favorites.count + 1)" }

    // MARK: - Status

    private func update(_ s: LocationStatus) {
        let old = status
        status = s
        if s.isActive && !old.isActive { keepAlive.start() }
        if !s.isActive && old.isActive { keepAlive.stop() }
        if let n = s.notice, n != old.notice { notice = n }

        if let p = s.simulated, s.motion == .still || Date().timeIntervalSince(lastSaved) > 10 {
            if p != lastPoint, let data = try? JSONEncoder().encode(p) {
                UserDefaults.standard.set(data, forKey: "locLastPoint")
                lastPoint = p
                lastSaved = Date()
            }
        }
        if s.arrivals > arrivals {
            arrivals = s.arrivals
            notice = "到了。"
            notify("已經走到目標", s.simulated?.text ?? "")
        }
        if old.link == .live && s.link == .retrying && !outage {
            outage = true
            ictrlLog("📍 link lost: \(s.lastError ?? "?")")
            notify("虛擬定位斷線了，正在重連", "斷線期間手機會回到真實位置。\(s.lastError ?? "")")
        }
        if s.link == .live && outage {
            outage = false
            ictrlLog("📍 link back")
            notify("虛擬定位重新連上了", s.simulated?.text ?? "")
        }
    }

    private func prepare() {
        keepAlive.requestPermission()
        guard !Self.isSimulator, !askedNotifications else { return }
        askedNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Only while the person is elsewhere (in the game): on screen it shows anyway.
    private func notify(_ title: String, _ body: String) {
        guard UIApplication.shared.applicationState != .active, !Self.isSimulator else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "ictrl.location.status", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Directions

    /// Apple Maps directions as a list of points, ending at `to`.
    static func route(from: GeoPoint, to: GeoPoint, speed: TravelSpeed) async -> [GeoPoint]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
        request.transportType = speed == .drive ? .automobile : .walking
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let line = response.routes.first?.polyline, line.pointCount > 1 else { return nil }
            var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: line.pointCount)
            line.getCoordinates(&coords, range: NSRange(location: 0, length: line.pointCount))
            var points = coords.map { GeoPoint($0.latitude, $0.longitude) }
            // The route runs from the nearest street; walk to and from it too.
            if let first = points.first, GeoMath.distance(first, from) < 3 { points.removeFirst() }
            if let last = points.last, GeoMath.distance(last, to) > 3 { points.append(to) }
            return points.isEmpty ? nil : points
        } catch {
            ictrlLog("📍 directions failed: \(error.localizedDescription)")
            return nil
        }
    }
}

extension GeoPoint {
    init(_ c: CLLocationCoordinate2D) { self.init(c.latitude, c.longitude) }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Favorites as JSON in Application Support, beside the pairing file.
enum FavoriteStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Location/favorites.json")
    }

    static func load() -> [FavoritePlace] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FavoritePlace].self, from: data)) ?? []
    }

    static func save(_ list: [FavoritePlace]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(list).write(to: url, options: .atomic)
        } catch {
            ictrlLog("📍 favorites not saved: \(error.localizedDescription)")
        }
    }
}
