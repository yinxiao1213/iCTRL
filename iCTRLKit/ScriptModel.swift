import Foundation

/// One recorded action.
///
/// The app stores these as JSON and sends them to the runner unchanged, so the
/// same type is compiled into both processes. Coordinates are in POINTS, the
/// space `tap` uses.
struct ScriptStep: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case openApp = "open_app"
        case tap
        case doubleTap = "double_tap"
        case longPress = "long_press"
        case swipe
        case type
        case wait
        case home
        /// Wait until the text is on screen; the script fails if it never is.
        case waitText = "wait_text"
        /// Wait until the text is on screen, then tap it.
        case tapText = "tap_text"
        /// Run the next `skip` steps only if the text is (or with `negate`, is
        /// not) on screen.
        case ifText = "if_text"
    }

    var id = UUID()
    var kind: Kind
    var x: Double?
    var y: Double?
    var toX: Double?
    var toY: Double?
    /// Seconds: press length, swipe length, or how long `wait` lasts.
    var duration: Double?
    var text: String?
    var bundleId: String?
    var appName: String?
    /// Seconds to keep looking for `text`.
    var timeout: Double?
    var skip: Int?
    var negate: Bool?
    var clear: Bool?
    var submit: Bool?
    /// `open_app`: close the app first, so a replay starts from its first
    /// screen and not from wherever it was left.
    var restart: Bool?

    init(kind: Kind, x: Double? = nil, y: Double? = nil, toX: Double? = nil, toY: Double? = nil,
         duration: Double? = nil, text: String? = nil, bundleId: String? = nil, appName: String? = nil,
         timeout: Double? = nil, skip: Int? = nil, negate: Bool? = nil,
         clear: Bool? = nil, submit: Bool? = nil, restart: Bool? = nil) {
        self.kind = kind
        self.x = x
        self.y = y
        self.toX = toX
        self.toY = toY
        self.duration = duration
        self.text = text
        self.bundleId = bundleId
        self.appName = appName
        self.timeout = timeout
        self.skip = skip
        self.negate = negate
        self.clear = clear
        self.submit = submit
        self.restart = restart
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, x, y, duration, text, timeout, skip, negate, clear, submit, restart
        case toX = "to_x"
        case toY = "to_y"
        case bundleId = "bundle_id"
        case appName = "app_name"
    }

    /// `id` is only there for the app's lists, so a step without one is fine.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        x = try c.decodeIfPresent(Double.self, forKey: .x)
        y = try c.decodeIfPresent(Double.self, forKey: .y)
        toX = try c.decodeIfPresent(Double.self, forKey: .toX)
        toY = try c.decodeIfPresent(Double.self, forKey: .toY)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout)
        skip = try c.decodeIfPresent(Int.self, forKey: .skip)
        negate = try c.decodeIfPresent(Bool.self, forKey: .negate)
        clear = try c.decodeIfPresent(Bool.self, forKey: .clear)
        submit = try c.decodeIfPresent(Bool.self, forKey: .submit)
        restart = try c.decodeIfPresent(Bool.self, forKey: .restart)
    }
}
