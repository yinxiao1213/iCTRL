import Foundation

// Everything here is plain Foundation, so Tests/LocationSim can build it with
// swiftc on a Mac and drive it against a fake phone (Scripts/test-location-sim.sh).

/// A point on Earth in WGS-84 degrees: what DVT's `simulateLocation` takes and
/// what MapKit shows (outside mainland China, Taiwan included).
struct GeoPoint: Codable, Equatable, Hashable {
    var latitude: Double
    var longitude: Double

    init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    /// Six decimals is about 10 cm, which is what every map app copies.
    var text: String { String(format: "%.6f, %.6f", latitude, longitude) }
}

enum GeoMath {
    static let earthRadius = 6_371_008.8

    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// Great-circle distance in meters.
    static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dLat = rad(b.latitude - a.latitude)
        let dLon = rad(b.longitude - a.longitude)
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(rad(a.latitude)) * cos(rad(b.latitude)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from a to b, degrees clockwise from north (0..<360).
    static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let lat1 = rad(a.latitude), lat2 = rad(b.latitude)
        let dLon = rad(b.longitude - a.longitude)
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let b = deg(atan2(y, x))
        return b < 0 ? b + 360 : b
    }

    /// The point `distance` meters from p along `bearing` degrees.
    static func destination(from p: GeoPoint, bearing: Double, distance: Double) -> GeoPoint {
        let d = distance / earthRadius
        let br = rad(bearing)
        let lat1 = rad(p.latitude), lon1 = rad(p.longitude)
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(br))
        let lon2 = lon1 + atan2(sin(br) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        var lon = deg(lon2)
        while lon > 180 { lon -= 360 }
        while lon < -180 { lon += 360 }
        return GeoPoint(deg(lat2), lon)
    }

    /// Total length of a path through the points, in meters.
    static func length(_ points: [GeoPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }
}

/// How fast "walk to" moves. Kept to everyday speeds on purpose.
enum TravelSpeed: String, CaseIterable, Codable {
    case walk, bike, drive

    var metersPerSecond: Double {
        switch self {
        case .walk: return 1.4    // 5 km/h
        case .bike: return 4.4    // 16 km/h
        case .drive: return 11.1  // 40 km/h
        }
    }

    var kmh: Int { Int((metersPerSecond * 3.6).rounded()) }

    var label: String {
        switch self {
        case .walk: return "步行"
        case .bike: return "腳踏車"
        case .drive: return "開車"
        }
    }

    var symbol: String {
        switch self {
        case .walk: return "figure.walk"
        case .bike: return "bicycle"
        case .drive: return "car.fill"
        }
    }
}

/// Coordinates typed or pasted by a person.
enum CoordinateParser {
    /// Accepts "25.0330, 121.5654", "25.0330 121.5654", "(25.0330,121.5654)",
    /// "25.0330° N, 121.5654° E", full-width commas, and Google / Apple Maps
    /// links ("…/@25.03,121.56,17z", "…!3d25.03!4d121.56", "?q=25.03,121.56",
    /// "?ll=25.03,121.56").
    static func parse(_ raw: String) -> GeoPoint? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Map links carry the coordinates in known places; anything else in
        // the link (a place name with digits in it) must not be read instead.
        for pattern in [#"!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)"#,
                        #"@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)"#,
                        #"[?&](?:q|ll|sll|center|query)=(-?\d+(?:\.\d+)?)(?:,|%2C)\s*(-?\d+(?:\.\d+)?)"#] {
            if let m = firstMatch(pattern, in: text), m.count == 2,
               let lat = Double(m[0]), let lon = Double(m[1]) {
                let p = GeoPoint(lat, lon)
                if p.isValid { return p }
            }
        }

        // Two numbers, each optionally followed by a hemisphere letter.
        let pattern = #"(-?\d{1,3}(?:\.\d+)?)\s*°?\s*([NSEWnsew])?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return nil }
        func value(_ m: NSTextCheckingResult) -> (Double, Character?)? {
            guard let v = Double(ns.substring(with: m.range(at: 1))) else { return nil }
            let r = m.range(at: 2)
            let letter = r.location == NSNotFound ? nil : ns.substring(with: r).uppercased().first
            return (v, letter)
        }
        guard var a = value(matches[0]), var b = value(matches[1]) else { return nil }
        // "121.56 E, 25.03 N": longitude first.
        if let la = a.1, let lb = b.1, "EW".contains(la), "NS".contains(lb) { swap(&a, &b) }
        var lat = a.0, lon = b.0
        if a.1 == "S" { lat = -abs(lat) }
        if b.1 == "W" { lon = -abs(lon) }
        let p = GeoPoint(lat, lon)
        return p.isValid ? p : nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }
}

struct FavoritePlace: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var point: GeoPoint
    var addedAt: Date

    init(id: UUID = UUID(), name: String, point: GeoPoint, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.point = point
        self.addedAt = addedAt
    }
}

/// The phone side of location simulation: one DVT channel that stays open.
///
/// All calls come from the simulator's own thread, one at a time, and may
/// block (they are network round trips through the tunnel).
protocol LocationBackend: AnyObject {
    /// Open the connection. Called again after any failure.
    func connect() throws
    /// Tell the phone it is here. Throws when the connection is gone.
    func set(_ point: GeoPoint) throws
    /// Give the phone back its real location.
    func clear() throws
    /// Close everything; safe to call when already closed.
    func disconnect()
}

struct LocationBackendError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What the simulator is doing, for the screen.
struct LocationStatus: Equatable {
    enum Link: Equatable {
        /// Not simulating: the phone reports its real location.
        case off
        /// Opening the connection for the first time.
        case connecting
        /// The phone accepted the last point and the channel is open.
        case live
        /// The channel broke; trying again. iOS has most likely gone back to
        /// the real location by now, because it does that when DVT disconnects.
        case retrying
    }

    enum Motion: Equatable {
        case still
        case walking
        case joystick
    }

    var link: Link = .off
    var motion: Motion = .still
    /// The last point the phone accepted.
    var simulated: GeoPoint?
    /// Where the simulator has the phone now (sent or about to be).
    var position: GeoPoint?
    /// The rest of the walk, starting at `position`.
    var route: [GeoPoint] = []
    var remainingMeters: Double = 0
    var speed: Double = 0
    var lastError: String?
    /// Failed attempts in a row.
    var failures = 0
    /// Points the phone has accepted since the start.
    var sends = 0
    /// Counts finished walks, so the screen can say "arrived" once per walk.
    var arrivals = 0
    /// Something the person asked for that could not be done.
    var notice: String?

    /// True only when the phone is known to be reporting the fake location.
    var isFake: Bool { link == .live && simulated != nil }
    var isActive: Bool { link != .off }
}

/// Keeps the phone at a fake location, moves it, and keeps the DVT channel
/// alive and checked.
///
/// The channel has to stay open: since iOS 17, closing it gives the phone its
/// real location back. So even standing still the point is re-sent every few
/// seconds — that is also how a dead connection is noticed and reopened (the
/// send waits for the phone's reply and fails when the channel is gone).
///
/// One thread does everything, so the backend is never called concurrently.
/// Commands are queued from any thread. Tests build it with `autoStart: false`
/// and call `pump()` with their own clock.
final class LocationSimulator {
    struct Timing {
        /// Re-send while standing still.
        var hold: TimeInterval = 4
        /// Update while walking.
        var move: TimeInterval = 1
        /// Update while the joystick is held.
        var stick: TimeInterval = 0.5
        /// Waits before each reconnect attempt; the last one repeats.
        var retry: [TimeInterval] = [0.5, 1, 2, 4, 8, 15]
        /// Most movement time applied in one step: after a stall (the app
        /// was paused) the walk carries on instead of jumping ahead.
        var maxStep: TimeInterval = 2
    }

    enum Command: Equatable {
        case teleport(GeoPoint)
        /// Walk through these points in order, from where the phone is now.
        case walk([GeoPoint], speed: Double)
        /// dx east, dy north, each -1...1; (0, 0) stops.
        case joystick(dx: Double, dy: Double, speed: Double)
        case setSpeed(Double)
        case stop
        case restore
    }

    private enum Mode { case still, walking, joystick }

    let timing: Timing
    /// Seconds on a monotonic clock.
    var now: () -> TimeInterval
    /// Called on the simulator's thread whenever the status changes.
    var onStatus: ((LocationStatus) -> Void)?

    private let backend: LocationBackend
    private let autoStart: Bool
    private let cond = NSCondition()
    private var queue: [Command] = []
    private var thread: Thread?

    // Owned by the simulator's thread (or the test calling pump()).
    private var active = false
    private var connected = false
    private var everConnected = false
    private var position: GeoPoint?
    private var lastSent: GeoPoint?
    private var lastSendTime: TimeInterval = -.infinity
    private var lastMoveTime: TimeInterval?
    private var mode: Mode = .still
    private var route: [GeoPoint] = []
    private var speed: Double = TravelSpeed.walk.metersPerSecond
    private var stickX = 0.0, stickY = 0.0
    private var failures = 0
    private var nextAttempt: TimeInterval = 0
    private var lastError: String?
    private var notice: String?
    private var sends = 0
    private var arrivals = 0
    private var mustSend = false
    private var published = LocationStatus()

    init(backend: LocationBackend, timing: Timing = Timing(), autoStart: Bool = true,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.backend = backend
        self.timing = timing
        self.autoStart = autoStart
        self.now = now
    }

    func send(_ command: Command) {
        cond.lock()
        queue.append(command)
        let needsThread = autoStart && thread == nil
        if needsThread {
            // A plain thread with room to spare: the FFI's TLS and tunnel setup
            // run on the caller's stack (the DDI mount needed the same).
            let t = Thread { [weak self] in self?.run() }
            t.stackSize = 4 * 1024 * 1024
            t.name = "ictrl.location"
            t.qualityOfService = .userInitiated
            thread = t
        }
        cond.signal()
        cond.unlock()
        if needsThread { thread?.start() }
    }

    var status: LocationStatus {
        cond.lock(); defer { cond.unlock() }
        return published
    }

    private func run() {
        while true {
            let wake = pump()
            cond.lock()
            if queue.isEmpty {
                if let wake {
                    let delay = wake - now()
                    if delay > 0 { _ = cond.wait(until: Date(timeIntervalSinceNow: delay)) }
                } else {
                    cond.wait()
                }
            }
            cond.unlock()
        }
    }

    /// Apply queued commands, move, send if due. Returns when to call again
    /// (nil: only when a command arrives).
    @discardableResult
    func pump() -> TimeInterval? {
        cond.lock()
        let commands = queue
        queue.removeAll()
        cond.unlock()

        for c in commands { apply(c, at: now()) }
        step(at: now())
        publish()
        return nextWake(at: now())
    }

    // MARK: - Commands

    private func apply(_ command: Command, at t: TimeInterval) {
        notice = nil
        switch command {
        case .teleport(let p):
            guard p.isValid else { notice = "座標不對。"; return }
            begin()
            position = p
            mode = .still
            route = []
            mustSend = true
            lastMoveTime = t

        case .walk(let points, let s):
            let points = points.filter(\.isValid)
            guard !points.isEmpty, s > 0 else { notice = "沒有可以走的路線。"; return }
            begin()
            if position == nil {
                position = points[0]
                route = Array(points.dropFirst())
                mustSend = true
            } else {
                route = points
            }
            speed = s
            mode = route.isEmpty ? .still : .walking
            lastMoveTime = t

        case .joystick(let dx, let dy, let s):
            let mag = min(hypot(dx, dy), 1)
            if mag < 0.05 {
                if mode == .joystick { mode = .still }
                return
            }
            guard position != nil else {
                notice = "先瞬移到一個起點，才能用搖桿走。"
                return
            }
            begin()
            if mode != .joystick { lastMoveTime = t }
            mode = .joystick
            route = []
            let scale = mag / hypot(dx, dy)
            stickX = dx * scale
            stickY = dy * scale
            speed = s

        case .setSpeed(let s):
            if s > 0 { speed = s }

        case .stop:
            mode = .still
            route = []

        case .restore:
            if connected {
                // Best effort: closing the channel restores it on iOS 17+ anyway.
                try? backend.clear()
            }
            backend.disconnect()
            active = false
            connected = false
            everConnected = false
            position = nil
            lastSent = nil
            lastSendTime = -.infinity
            mode = .still
            route = []
            failures = 0
            lastError = nil
            mustSend = false
        }
    }

    private func begin() {
        if !active {
            active = true
            failures = 0
            nextAttempt = 0
            lastError = nil
        }
    }

    // MARK: - Moving and sending

    private func step(at t: TimeInterval) {
        guard active, var pos = position else { return }

        // Hold still while the link is down: the walk resumes from where the
        // phone was last told it is, not from a point it never visited.
        let linkDown = !connected && failures > 0
        if mode != .still, !linkDown, let last = lastMoveTime {
            let dt = min(max(t - last, 0), timing.maxStep)
            switch mode {
            case .walking:
                var budget = speed * dt
                while budget > 0, let next = route.first {
                    let d = GeoMath.distance(pos, next)
                    if d <= budget {
                        pos = next
                        route.removeFirst()
                        budget -= d
                    } else {
                        pos = GeoMath.destination(from: pos, bearing: GeoMath.bearing(from: pos, to: next),
                                                  distance: budget)
                        budget = 0
                    }
                }
                if route.isEmpty {
                    mode = .still
                    arrivals += 1
                }
            case .joystick:
                let mag = hypot(stickX, stickY)
                var bearing = atan2(stickX, stickY) * 180 / .pi
                if bearing < 0 { bearing += 360 }
                pos = GeoMath.destination(from: pos, bearing: bearing, distance: speed * mag * dt)
            case .still:
                break
            }
        }
        lastMoveTime = t
        position = pos

        let due = mustSend || lastSent != pos || t - lastSendTime >= timing.hold
        guard due else { return }

        if !connected {
            guard t >= nextAttempt else { return }
            publish(link: failures == 0 && !everConnected ? .connecting : .retrying)
            do {
                try backend.connect()
                connected = true
                everConnected = true
            } catch {
                backend.disconnect()
                fail(error)
                return
            }
        }
        do {
            try backend.set(pos)
            lastSent = pos
            lastSendTime = t
            sends += 1
            failures = 0
            lastError = nil
            mustSend = false
        } catch {
            backend.disconnect()
            connected = false
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        failures += 1
        lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        let wait = timing.retry[min(failures - 1, timing.retry.count - 1)]
        nextAttempt = now() + wait
    }

    private func nextWake(at t: TimeInterval) -> TimeInterval? {
        guard active, position != nil else { return nil }
        var wake: TimeInterval
        if !connected {
            wake = nextAttempt
        } else {
            wake = lastSendTime + timing.hold
            if mode == .walking { wake = min(wake, (lastMoveTime ?? t) + timing.move) }
            if mode == .joystick { wake = min(wake, (lastMoveTime ?? t) + timing.stick) }
        }
        return max(wake, t + 0.02)
    }

    // MARK: - Status

    private func link() -> LocationStatus.Link {
        guard active else { return .off }
        if connected { return .live }
        return failures == 0 && !everConnected ? .connecting : .retrying
    }

    private func publish(link forced: LocationStatus.Link? = nil) {
        var s = LocationStatus()
        s.link = forced ?? link()
        s.motion = mode == .walking ? .walking : (mode == .joystick ? .joystick : .still)
        s.simulated = connected ? lastSent : nil
        s.position = position
        s.route = mode == .walking && position != nil ? [position!] + route : []
        s.remainingMeters = GeoMath.length(s.route)
        s.speed = speed
        s.lastError = lastError
        s.failures = failures
        s.sends = sends
        s.arrivals = arrivals
        s.notice = notice

        cond.lock()
        let changed = s != published
        if changed { published = s }
        cond.unlock()
        if changed { onStatus?(s) }
    }
}
