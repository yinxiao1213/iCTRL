import Foundation
import IDevice

/// Location simulation through this device's own instruments server.
///
/// The same path as the DDI mount (see DDIMounter): LocalDevVPN makes this
/// device's `remoted` reachable at 10.7.0.1, the RemotePairing file opens a
/// tunnel to it, and over that tunnel we open DVT
/// (`com.apple.instruments.dtservicehub`, which lives in the Developer Disk
/// Image) and its `LocationSimulation` channel — what Xcode's "Simulate
/// Location" uses. StikDebug does exactly this; the calls are idevice's (MIT).
///
/// Everything stays open between calls: on iOS 17+ the phone goes back to its
/// real location as soon as the channel closes.
///
/// Not thread-safe; LocationSimulator calls it from its one thread.
final class DVTLocationBackend: LocationBackend {
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var server: OpaquePointer?
    private var channel: OpaquePointer?

    /// LocalDevVPN's address for this device — DDIMounter's, repeated here
    /// because that class belongs to the main thread and this runs off it.
    static let tunnelAddress = "10.7.0.1"
    static let tunnelPort: UInt16 = 49152

    deinit { disconnect() }

    func connect() throws {
        disconnect()

        guard PairingFileStore.exists else {
            throw LocationBackendError("還沒匯入配對檔。到「設定」→ 掛載開發者映像，照步驟匯入。")
        }
        switch Self.probeTunnel() {
        case .reachable:
            break
        case .localNetworkDenied:
            throw LocationBackendError("iOS 擋住了區域網路：到 設定 → 隱私權與安全性 → 區域網路，打開 iCTRL。")
        case .unreachable:
            throw LocationBackendError("LocalDevVPN 沒連上。打開 LocalDevVPN 按連線（重開機後要再連一次）。")
        }

        var pairing: OpaquePointer?
        try Self.check("讀取配對檔") { rp_pairing_file_read(PairingFileStore.storedURL.path, &pairing) }
        defer { if let pairing { rp_pairing_file_free(pairing) } }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.tunnelPort.bigEndian
        guard Self.tunnelAddress.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw LocationBackendError("通道位址錯誤")
        }
        do {
            try withUnsafePointer(to: &addr) { ptr in
                try ptr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { sa in
                    try Self.check("建立通道") {
                        tunnel_create_rppairing(sa, idevice_socklen_t(MemoryLayout<sockaddr_in>.size),
                                                "iCTRL-Location", pairing, nil, nil, &adapter, &handshake)
                    }
                }
            }
            guard adapter != nil, handshake != nil else { throw LocationBackendError("建立通道失敗：沒有拿到連線") }
            try Self.check("連接開發者服務") { remote_server_connect_rsd(adapter, handshake, &server) }
            guard server != nil else { throw LocationBackendError("連接開發者服務失敗") }
            try Self.check("開啟定位模擬") { location_simulation_new(server, &channel) }
            guard channel != nil else { throw LocationBackendError("開啟定位模擬失敗") }
            ictrlLog("📍 DVT location channel open")
        } catch {
            disconnect()
            throw error
        }
    }

    func set(_ point: GeoPoint) throws {
        guard let channel else { throw LocationBackendError("定位連線已經關了") }
        try Self.check("設定位置") { location_simulation_set(channel, point.latitude, point.longitude) }
    }

    func clear() throws {
        guard let channel else { return }
        try Self.check("恢復真實定位") { location_simulation_clear(channel) }
    }

    /// The channel borrows the server, the server rides the tunnel: free them
    /// in that order.
    func disconnect() {
        if let channel { location_simulation_free(channel) }
        if let server { remote_server_free(server) }
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
        if channel != nil || adapter != nil { ictrlLog("📍 DVT location channel closed") }
        channel = nil
        server = nil
        handshake = nil
        adapter = nil
    }

    // MARK: - Helpers

    /// The async tunnel probe, waited for here: this runs on the simulator's
    /// own thread, never the main one.
    private static func probeTunnel() -> LocalDevVPN.TunnelProbe {
        final class Box { var value = LocalDevVPN.TunnelProbe.unreachable("timeout") }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await LocalDevVPN.probeTunnel()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        return box.value
    }

    /// An `IdeviceFfiError*` as a Swift error, freed either way, with what it
    /// usually means attached.
    private static func check(_ step: String, _ call: () -> UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let err = call() else { return }
        let message = err.pointee.message.map { String(cString: $0) } ?? "code \(err.pointee.code)"
        let code = err.pointee.code
        idevice_error_free(err)
        ictrlLog("❌ Location \(step): \(message) (code \(code))")
        throw LocationBackendError(explain(step: step, message: message))
    }

    static func explain(step: String, message: String) -> String {
        let lower = message.lowercased()
        var text = "\(step)失敗：\(message)"
        if lower.contains("socket") || lower.contains("connect:") || lower.contains("timed out")
            || lower.contains("broken pipe") || lower.contains("reset") {
            text += "。連線斷了，通常是 LocalDevVPN 斷線，或 iCTRL 在背景被暫停過。"
        } else if step == "連接開發者服務" {
            text += "。手機上找不到開發者服務：先到「設定」掛載開發者映像（重開機後要再掛一次）。"
        } else if step == "建立通道" && (lower.contains("pair") || lower.contains("verify") || lower.contains("auth")) {
            text += "。配對檔不對或過期了，重新匯入 RemotePairing 配對檔。"
        }
        return text
    }
}

#if targetEnvironment(simulator)
/// The simulator has no DVT. This stands in for it so the screen, the walk
/// and staying alive in the background can be tested there; every point is
/// written to the app log, which Tests/sim/e2e.py reads back.
final class SimulatorLocationBackend: LocationBackend {
    private var open = false
    private var count = 0

    func connect() throws {
        open = true
        ictrlLog("📍 [sim] location channel open")
    }

    func set(_ point: GeoPoint) throws {
        guard open else { throw LocationBackendError("沒連線") }
        count += 1
        ictrlLog("📍 [sim] set #\(count) \(point.text)")
    }

    func clear() throws { ictrlLog("📍 [sim] clear") }

    func disconnect() {
        if open { ictrlLog("📍 [sim] location channel closed") }
        open = false
    }
}
#endif
