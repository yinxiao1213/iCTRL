import AVFoundation
import CoreLocation
import UIKit

/// Keeps iCTRL running while another app (the game) is in front.
///
/// The DVT channel lives in this process. A suspended app answers nothing, so
/// the tunnel's TCP stack (which runs inside the app) stalls, the phone drops
/// the channel, and with it the fake location. iOS only lets an app keep
/// running in the background for a declared reason, and two of them fit here —
/// the same two StikDebug uses for its location simulation:
///
/// * **Background location** (`UIBackgroundModes` location): while this app
///   asks for location updates it is not suspended. It also tells us what
///   the system reports right now, so the screen can show whether the fake
///   location really took.
/// * **Background audio** (`UIBackgroundModes` audio): a silent loop, mixed
///   with other apps' sound. Another app that takes audio over exclusively
///   interrupts it, so it is retried every few seconds.
///
/// Either one is enough on its own; both are on by default so that losing one
/// (location permission refused, the game grabbing audio) does not end it.
final class LocationKeepAlive: NSObject, CLLocationManagerDelegate {
    static let audioKey = "locKeepAliveAudio"
    static let locationKey = "locKeepAliveLocation"

    static var audioEnabled: Bool {
        get { UserDefaults.standard.object(forKey: audioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: audioKey) }
    }
    static var locationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: locationKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: locationKey) }
    }

    /// What CoreLocation reports, fake or real.
    var onSystemLocation: ((GeoPoint, Double) -> Void)?
    /// Whether each keep-alive is actually running, for the screen.
    var onState: ((State) -> Void)?

    struct State: Equatable {
        var audio = false
        var location = false
        var locationDenied = false
    }

    private(set) var state = State() {
        didSet { if state != oldValue { onState?(state) } }
    }

    private let manager = CLLocationManager()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var keeping = false
    private var audioTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Location updates for the map, while the screen is showing.
    private var watching = false

    override init() {
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaReset),
                                               name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    /// Ask for When In Use if never asked. Enough for background updates that
    /// start in the foreground (the status bar shows a blue location pill).
    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// The map wants the current location even when not simulating.
    func watch(_ on: Bool) {
        watching = on
        refreshLocation()
    }

    // MARK: - Keeping alive

    func start() {
        guard !keeping else { return }
        keeping = true
        ictrlLog("📍 keep-alive on (audio \(Self.audioEnabled), location \(Self.locationEnabled))")
        refreshAudio()
        refreshLocation()
    }

    func stop() {
        guard keeping else { return }
        keeping = false
        ictrlLog("📍 keep-alive off")
        refreshAudio()
        refreshLocation()
        endBackgroundTask()
    }

    /// Re-read the settings while running.
    func settingsChanged() {
        refreshAudio()
        refreshLocation()
    }

    // MARK: - Location

    private func refreshLocation() {
        let background = keeping && Self.locationEnabled
        let wanted = background || watching
        switch manager.authorizationStatus {
        case .denied, .restricted:
            state.locationDenied = true
            state.location = false
            return
        case .notDetermined:
            state.locationDenied = false
            if wanted { manager.requestWhenInUseAuthorization() }
            state.location = false
            return
        default:
            state.locationDenied = false
        }
        guard wanted else {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            state.location = false
            return
        }
        // Only claim the background mode while it is needed for keeping alive:
        // otherwise the blue pill would show whenever the map is open.
        manager.allowsBackgroundLocationUpdates = background
        manager.showsBackgroundLocationIndicator = background
        // Coarser while simulating: the fake point comes through either way.
        manager.desiredAccuracy = background ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 5
        manager.startUpdatingLocation()
        state.location = background
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        ictrlLog("📍 location permission: \(manager.authorizationStatus.rawValue)")
        refreshLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        onSystemLocation?(GeoPoint(last.coordinate.latitude, last.coordinate.longitude), last.horizontalAccuracy)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix (indoors, no signal) is fine: the updates only have to be running.
    }

    // MARK: - Audio

    private func refreshAudio() {
        let wanted = keeping && Self.audioEnabled
        if wanted == state.audio, !wanted { return }
        if wanted {
            if !state.audio { startAudio() }
            if audioTimer == nil {
                let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.recoverAudio() }
                RunLoop.main.add(timer, forMode: .common)
                audioTimer = timer
            }
        } else {
            audioTimer?.invalidate()
            audioTimer = nil
            player.stop()
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            state.audio = false
        }
    }

    private func startAudio() {
        do {
            engine.stop()
            player.stop()
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            let session = AVAudioSession.sharedInstance()
            // Mixed, so the game's own sound plays as usual.
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            engine.attach(player)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            guard format.sampleRate > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
                throw LocationBackendError("沒有可用的音訊輸出")
            }
            buffer.frameLength = buffer.frameCapacity  // zero-filled: silence
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            try engine.start()
            player.play()
            state.audio = true
            ictrlLog("📍 silent audio playing")
        } catch {
            state.audio = false
            ictrlLog("📍 silent audio failed: \(error.localizedDescription)")
        }
    }

    private func recoverAudio() {
        guard keeping, Self.audioEnabled else { return }
        if !state.audio || !engine.isRunning || !player.isPlaying {
            if engine.isRunning, !player.isPlaying {
                player.play()
                state.audio = player.isPlaying
            } else {
                startAudio()
            }
        }
    }

    @objc private func audioInterrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            state.audio = false
        } else {
            recoverAudio()
        }
    }

    @objc private func mediaReset() {
        state.audio = false
        recoverAudio()
    }

    // MARK: - App lifecycle

    /// A little extra time while the background modes take over.
    @objc private func didEnterBackground() {
        guard keeping else { return }
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ictrl.location") { [weak self] in
            self?.endBackgroundTask()
        }
        // The map's own updates are not needed back there; keep-alive ones are.
        if !(keeping && Self.locationEnabled) && watching {
            manager.stopUpdatingLocation()
        }
        ictrlLog("📍 in background (audio \(state.audio), location \(state.location))")
    }

    @objc private func willEnterForeground() {
        endBackgroundTask()
        refreshLocation()
        recoverAudio()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
