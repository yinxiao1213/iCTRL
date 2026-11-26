// Runs the location simulator against a fake phone:
//   Scripts/test-location-sim.sh
import Foundation

final class FakePhone: LocationBackend {
    let lock = NSLock()
    private(set) var log: [String] = []
    private(set) var points: [GeoPoint] = []
    var connected = false
    /// Fail the next N connects / sets.
    var failConnects = 0
    var failSets = 0

    private func note(_ s: String) { lock.lock(); log.append(s); lock.unlock() }

    func connect() throws {
        note("connect")
        if failConnects > 0 { failConnects -= 1; throw LocationBackendError("VPN 沒連上") }
        connected = true
    }
    func set(_ point: GeoPoint) throws {
        guard connected else { note("set-unconnected"); throw LocationBackendError("沒連線") }
        if failSets > 0 { failSets -= 1; connected = false; note("set-fail"); throw LocationBackendError("連線斷了") }
        lock.lock(); points.append(point); log.append("set"); lock.unlock()
    }
    func clear() throws { note("clear") }
    func disconnect() { connected = false; note("disconnect") }

    var count: (connects: Int, sets: Int, disconnects: Int) {
        lock.lock(); defer { lock.unlock() }
        return (log.filter { $0 == "connect" }.count, log.filter { $0 == "set" }.count,
                log.filter { $0 == "disconnect" }.count)
    }
    var sets: Int { count.sets }
}

var failures = 0
var checks = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok { print("ok   \(name)") } else { failures += 1; print("FAIL \(name) \(detail())") }
}
func near(_ a: Double, _ b: Double, _ eps: Double) -> Bool { abs(a - b) <= eps }

final class Clock { var t: TimeInterval = 100 }

func make(_ phone: FakePhone, _ clock: Clock) -> (LocationSimulator, () -> [LocationStatus]) {
    let sim = LocationSimulator(backend: phone, autoStart: false, now: { clock.t })
    var seen: [LocationStatus] = []
    sim.onStatus = { seen.append($0) }
    return (sim, { seen })
}

let taipei101 = GeoPoint(25.033964, 121.564468)
let mainStation = GeoPoint(25.047924, 121.517081)

// MARK: - Geometry

do {
    let d = GeoMath.distance(taipei101, mainStation)
    check("101 to Main Station is about 5 km", d > 4_700 && d < 5_200, "\(d)")
    let east = GeoMath.destination(from: taipei101, bearing: 90, distance: 1000)
    check("1 km east is 1 km away", near(GeoMath.distance(taipei101, east), 1000, 0.5))
    check("…and due east", near(GeoMath.bearing(from: taipei101, to: east), 90, 0.5))
    let north = GeoMath.destination(from: taipei101, bearing: 0, distance: 111)
    check("111 m north is about 0.001°", near(north.latitude - taipei101.latitude, 0.001, 0.00005))
    let wrap = GeoMath.destination(from: GeoPoint(0, 179.9999), bearing: 90, distance: 1000)
    check("longitude wraps at the date line", wrap.longitude < -179 && wrap.isValid, "\(wrap)")
    check("a path's length adds up", near(GeoMath.length([taipei101, east, taipei101]), 2000, 1))
    check("speeds read as km/h", TravelSpeed.walk.kmh == 5 && TravelSpeed.bike.kmh == 16 && TravelSpeed.drive.kmh == 40)
}

// MARK: - Typed coordinates

do {
    let cases: [(String, GeoPoint?)] = [
        ("25.033964, 121.564468", taipei101),
        ("25.033964,121.564468", taipei101),
        ("25.033964 121.564468", taipei101),
        ("  (25.033964, 121.564468)\n", taipei101),
        ("25.033964，121.564468", taipei101),
        ("25.033964° N, 121.564468° E", taipei101),
        ("121.564468 E, 25.033964 N", taipei101),
        ("33.8688° S, 151.2093° E", GeoPoint(-33.8688, 151.2093)),
        ("40.7128 N 74.0060 W", GeoPoint(40.7128, -74.006)),
        ("-33.8688, 151.2093", GeoPoint(-33.8688, 151.2093)),
        ("https://www.google.com/maps/place/Taipei+101/@25.033964,121.564468,17z/data=!3d25.033964!4d121.564468", taipei101),
        ("https://www.google.com/maps/place/101/data=!4m2!3m1!1s0x0:0x0!3d25.033964!4d121.564468", taipei101),
        ("https://maps.google.com/?q=25.033964,121.564468", taipei101),
        ("https://maps.apple.com/?ll=25.033964,121.564468&q=101", taipei101),
        ("https://maps.apple.com/?q=Taipei&sll=25.033964%2C121.564468", taipei101),
        ("95, 121", nil),
        ("25.03, 190", nil),
        ("台北 101", nil),
        ("", nil),
    ]
    for (text, want) in cases {
        let got = CoordinateParser.parse(text)
        let ok: Bool
        if let want, let got {
            ok = near(got.latitude, want.latitude, 1e-9) && near(got.longitude, want.longitude, 1e-9)
        } else {
            ok = want == nil && got == nil
        }
        check("parse \(text.debugDescription)", ok, "got \(String(describing: got))")
    }
    check("text shows six decimals", taipei101.text == "25.033964, 121.564468", taipei101.text)
}

// MARK: - Favorites

do {
    let fav = FavoritePlace(name: "台北 101", point: taipei101, addedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let data = try! JSONEncoder().encode([fav])
    let back = try! JSONDecoder().decode([FavoritePlace].self, from: data)
    check("favorites survive a save", back == [fav])
}

// MARK: - Teleport and hold

do {
    let phone = FakePhone(), clock = Clock()
    let (sim, statuses) = make(phone, clock)
    check("starts off", sim.status.link == .off && !sim.status.isFake)
    sim.send(.teleport(taipei101))
    var wake = sim.pump()
    check("teleport connects once and sends the point", phone.count.connects == 1 && phone.points == [taipei101],
          "\(phone.log)")
    check("status is live and fake", sim.status.link == .live && sim.status.isFake && sim.status.simulated == taipei101)
    check("the screen saw 'connecting' first", statuses().first?.link == .connecting,
          "\(statuses().map { $0.link })")
    check("next wake is the 4 s re-send", wake.map { near($0, 104, 0.01) } == true, "\(String(describing: wake))")

    clock.t = 103.9
    sim.pump()
    check("nothing is re-sent early", phone.sets == 1)
    clock.t = 104
    wake = sim.pump()
    check("standing still re-sends every 4 s", phone.sets == 2 && phone.points.last == taipei101)
    check("without reconnecting", phone.count.connects == 1)
    for i in 1...10 { clock.t = 104 + Double(i) * 4; sim.pump() }
    check("44 s standing still is 12 sends", phone.sets == 12, "\(phone.sets)")

    sim.send(.teleport(mainStation))
    sim.pump()
    check("a second teleport is sent at once", phone.points.last == mainStation && phone.count.connects == 1)
}

// MARK: - Walking

do {
    let phone = FakePhone(), clock = Clock()
    let (sim, _) = make(phone, clock)
    sim.send(.teleport(taipei101))
    sim.pump()
    let target = GeoMath.destination(from: taipei101, bearing: 45, distance: 100)
    sim.send(.walk([target], speed: 1.4))
    var wake = sim.pump()
    check("walking wakes every second", wake.map { near($0, clock.t + 1, 0.01) } == true)
    check("status says walking, 100 m to go", sim.status.motion == .walking && near(sim.status.remainingMeters, 100, 0.5),
          "\(sim.status.motion) \(sim.status.remainingMeters)")
    var last = taipei101
    var maxStep = 0.0
    var steps = 0
    while sim.status.motion == .walking && steps < 200 {
        clock.t += 1
        wake = sim.pump()
        let p = sim.status.simulated!
        maxStep = max(maxStep, GeoMath.distance(last, p))
        last = p
        steps += 1
    }
    check("100 m at 5 km/h takes about 72 s", steps >= 71 && steps <= 73, "\(steps)")
    check("never more than 1.4 m a second", maxStep <= 1.4 + 1e-6, "\(maxStep)")
    check("ends exactly on the target", sim.status.simulated == target)
    check("and stops there", sim.status.motion == .still && sim.status.arrivals == 1)

    // Through two points, at bike speed.
    let a = GeoMath.destination(from: target, bearing: 90, distance: 40)
    let b = GeoMath.destination(from: a, bearing: 0, distance: 40)
    sim.send(.walk([a, b], speed: 4.4))
    sim.pump()
    check("a route is drawn from here through both points", sim.status.route.count == 3 && near(sim.status.remainingMeters, 80, 0.5))
    var n = 0
    while sim.status.motion == .walking && n < 100 { clock.t += 1; sim.pump(); n += 1 }
    check("80 m by bike takes about 19 s", n >= 18 && n <= 20, "\(n)")
    check("and passes the corner", phone.points.contains(where: { GeoMath.distance($0, a) < 4.5 }))

    // A long stall moves at most maxStep seconds' worth.
    let far = GeoMath.destination(from: b, bearing: 180, distance: 1000)
    sim.send(.walk([far], speed: 1.4))
    sim.pump()
    let before = sim.status.simulated!
    clock.t += 60
    sim.pump()
    check("after a stall the walk resumes, no jump", near(GeoMath.distance(before, sim.status.simulated!), 2.8, 0.01),
          "\(GeoMath.distance(before, sim.status.simulated!))")
    sim.send(.stop)
    sim.pump()
    check("stop stands still", sim.status.motion == .still && sim.status.route.isEmpty)
    let stopped = sim.status.simulated!
    clock.t += 1
    sim.pump()
    check("and stays put", sim.status.simulated == stopped)

    // Walking from nowhere starts at the first point.
    let p2 = FakePhone(), c2 = Clock()
    let (s2, _) = make(p2, c2)
    s2.send(.walk([taipei101, target], speed: 1.4))
    s2.pump()
    check("a walk with no fake position yet starts at its first point", p2.points.first == taipei101
          && s2.status.motion == .walking)
}

// MARK: - Joystick

do {
    let phone = FakePhone(), clock = Clock()
    let (sim, _) = make(phone, clock)
    sim.send(.joystick(dx: 1, dy: 0, speed: 2))
    sim.pump()
    check("the joystick needs a starting point", phone.count.connects == 0 && sim.status.notice != nil
          && sim.status.link == .off)

    sim.send(.teleport(taipei101))
    sim.pump()
    sim.send(.joystick(dx: 1, dy: 0, speed: 2))
    let wake = sim.pump()
    check("joystick updates twice a second", wake.map { near($0, clock.t + 0.5, 0.01) } == true)
    clock.t += 0.5
    sim.pump()
    let p = sim.status.simulated!
    check("pushing right goes east", near(GeoMath.bearing(from: taipei101, to: p), 90, 1))
    check("at the chosen speed", near(GeoMath.distance(taipei101, p), 1, 0.01), "\(GeoMath.distance(taipei101, p))")

    sim.send(.joystick(dx: 0, dy: -0.5, speed: 2))
    sim.pump()
    clock.t += 1
    sim.pump()
    let q = sim.status.simulated!
    check("half down goes south at half speed", near(GeoMath.bearing(from: p, to: q), 180, 1)
          && near(GeoMath.distance(p, q), 1, 0.01), "\(GeoMath.distance(p, q))")

    sim.send(.joystick(dx: 3, dy: 4, speed: 2))
    sim.pump()
    clock.t += 1
    sim.pump()
    check("a push past the edge counts as full", near(GeoMath.distance(q, sim.status.simulated!), 2, 0.01))

    sim.send(.joystick(dx: 0, dy: 0, speed: 2))
    sim.pump()
    let r = sim.status.simulated!
    clock.t += 1
    sim.pump()
    check("letting go stands still", sim.status.motion == .still && sim.status.simulated == r)
}

// MARK: - Losing the connection

do {
    let phone = FakePhone(), clock = Clock()
    let (sim, statuses) = make(phone, clock)
    sim.send(.teleport(taipei101))
    sim.pump()
    phone.failSets = 1
    clock.t = 104
    let wake = sim.pump()
    check("a failed send says retrying", sim.status.link == .retrying && !sim.status.isFake
          && sim.status.lastError == "連線斷了", "\(sim.status)")
    check("and closes the connection", phone.count.disconnects >= 1)
    check("first retry after half a second", wake.map { near($0, 104.5, 0.01) } == true, "\(String(describing: wake))")
    clock.t = 104.5
    sim.pump()
    check("then reconnects and re-sends", phone.count.connects == 2 && sim.status.isFake && sim.status.failures == 0)
    check("the screen saw it drop and come back",
          statuses().map { $0.link }.suffix(2) == [.retrying, .live] || statuses().contains { $0.link == .retrying })

    // A connection that cannot be opened backs off.
    phone.failSets = 1
    phone.failConnects = 4
    clock.t = 108.5
    var times: [TimeInterval] = []
    var w = sim.pump()
    while sim.status.link != .live && times.count < 10 {
        times.append(w!)
        clock.t = w!
        w = sim.pump()
    }
    let gaps = zip(times, times.dropFirst()).map { $0.1 - $0.0 }
    check("retries back off 0.5, 1, 2, 4, 8 s", gaps.count == 4
          && zip(gaps, [1.0, 2, 4, 8]).allSatisfy { near($0.0, $0.1, 0.01) }, "\(times) \(gaps)")
    check("and recovers", sim.status.isFake && sim.status.lastError == nil)

    // A walk holds still while the link is down.
    let target = GeoMath.destination(from: taipei101, bearing: 0, distance: 50)
    sim.send(.walk([target], speed: 1.4))
    sim.pump()
    clock.t += 1
    sim.pump()
    let here = sim.status.simulated!
    phone.failSets = 1
    phone.failConnects = 2
    clock.t += 1
    var g = sim.pump()
    var moved = sim.status.position!
    for _ in 0..<3 { clock.t = g!; g = sim.pump(); if sim.status.link == .retrying { moved = sim.status.position! } }
    check("the walk waits while reconnecting", GeoMath.distance(here, moved) <= 1.4 + 1e-6,
          "\(GeoMath.distance(here, moved))")
    while sim.status.link != .live { clock.t = g!; g = sim.pump() }
    check("and carries on once back", sim.status.motion == .walking)
}

// MARK: - Restore

do {
    let phone = FakePhone(), clock = Clock()
    let (sim, _) = make(phone, clock)
    sim.send(.teleport(taipei101))
    sim.pump()
    sim.send(.restore)
    let wake = sim.pump()
    check("restore clears the location and closes", phone.log.suffix(2) == ["clear", "disconnect"], "\(phone.log)")
    check("status goes back to real", sim.status.link == .off && sim.status.simulated == nil && !sim.status.isFake)
    check("and nothing else is scheduled", wake == nil)
    clock.t += 60
    sim.pump()
    check("no sends after restore", phone.sets == 1)
    sim.send(.teleport(mainStation))
    sim.pump()
    check("teleporting again reconnects", phone.count.connects == 2 && sim.status.simulated == mainStation)

    // Restoring while disconnected does not try to talk to the phone.
    let p2 = FakePhone(), c2 = Clock()
    let (s2, _) = make(p2, c2)
    p2.failConnects = 100
    s2.send(.teleport(taipei101))
    s2.pump()
    s2.send(.restore)
    s2.pump()
    check("restore while retrying just stops", !p2.log.contains("clear") && s2.status.link == .off)
}

// MARK: - The real thread

do {
    let phone = FakePhone()
    var timing = LocationSimulator.Timing()
    timing.hold = 0.05
    let sim = LocationSimulator(backend: phone, timing: timing)
    let seen = NSLock()
    var updates = 0
    sim.onStatus = { _ in seen.lock(); updates += 1; seen.unlock() }
    sim.send(.teleport(taipei101))
    // A CI machine's timers are coarse; this only has to show it keeps going.
    Thread.sleep(forTimeInterval: 1.0)
    let sets = phone.sets
    check("on its own thread it keeps re-sending", sets >= 4 && sets <= 22, "\(sets)")
    seen.lock(); let u = updates; seen.unlock()
    check("and reports each send", u >= sets)
    sim.send(.restore)
    Thread.sleep(forTimeInterval: 0.2)
    let after = phone.sets
    Thread.sleep(forTimeInterval: 0.3)
    check("restore stops the thread's sends", phone.sets == after && sim.status.link == .off)
    sim.send(.teleport(mainStation))
    Thread.sleep(forTimeInterval: 0.2)
    check("and a new teleport wakes it", phone.points.last == mainStation)
}

print("\(checks - failures) / \(checks) passed")
exit(failures == 0 ? 0 : 1)
