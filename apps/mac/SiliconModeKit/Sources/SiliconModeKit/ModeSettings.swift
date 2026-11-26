import Foundation

/// Every user-configurable knob ("cs" in the spec). Defaults follow understanding.md.
public struct ModeSettings: Codable, Equatable, Sendable {
    // MARK: Entering
    /// Auto-enter when the lid tilts below `thresholdAngle`.
    public var autoEnterEnabled = true
    /// Lid angle (degrees) below which Silicon Mode is offered.
    public var thresholdAngle: Double = 75
    /// Countdown shown before entering (seconds). 0 enters immediately.
    public var countdownSeconds: Double = 5
    /// Only auto-enter while at least one agent is running.
    public var requireAgentsRunning = true
    /// Seconds the lid must stay above the threshold before auto-entry re-arms after an exit/cancel.
    public var rearmSeconds: Double = 60

    // MARK: Inside
    /// For this long after entering, Silicon Mode can be turned off without the PIN
    /// (and lifting the lid back up ends it). After that it locks.
    public var graceSeconds: Double = 60
    /// Keep the Mac awake while Silicon Mode is active.
    public var caffeinate = true
    /// Selected face id.
    public var faceID = "bounce"
    /// Per-face options, keyed by face id then option key.
    public var faceOptions: [String: [String: FaceOptionValue]] = [:]
    /// Show a clock on faces that support it.
    public var showClock = true
    /// Face animation frame rate (30 saves energy on a laptop running for hours; 60 is smoother).
    public var faceFrameRate: Double = 30

    // MARK: HUD
    public var showAgentCounts = true
    public var showAgentList = true
    public var showTailLogs = true
    public var showQuestions = true
    public var tailLogCount = 10

    // MARK: Panic
    public var panicEnabled = true
    public var panicSoundEnabled = true
    /// Panic fires when the angle drops below `panicRatio * siliconModeAngle` while agents run.
    public var panicRatio: Double = 0.9
    public var panicSoundID = "mistake"
    public var panicStyleID = "strobe"
    public var panicVolume: Double = 0.9

    // MARK: Unlock
    /// Open the lock screen on Touch ID instead of the PIN keypad. Off by default: Touch ID isn't
    /// always reliable, and the keypad has a Touch ID key anyway. (Replaces `preferTouchID`, whose
    /// stored value is deliberately ignored so existing installs start on the PIN.)
    public var touchIDFirst = false

    // MARK: App
    public var hotkeyEnabled = true
    public var uiSoundsEnabled = true
    public var launchAtLogin = true
    /// When not in Silicon Mode, hold agent permission prompts this long so they can be
    /// answered from the menu bar before falling back to the terminal (seconds; 0 = don't hold).
    public var menuBarHoldSeconds: Double = 0
    /// Sync status/logs/questions to the user's Silicon account (mobile + web).
    public var cloudSyncEnabled = true
    /// Agent providers the user turned off (provider ids, e.g. "hermes").
    public var disabledProviders: [String] = []
    /// Onboarding finished (PIN set, hooks offered, face picked).
    public var onboardingCompleted = false

    public init() {}

    public static let `default` = ModeSettings()

    // Tolerant decoding: unknown/missing keys fall back to defaults so settings survive upgrades.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var s = ModeSettings()
        func v<T: Decodable>(_ k: String, _ kp: WritableKeyPath<ModeSettings, T>) {
            if let x = try? c.decodeIfPresent(T.self, forKey: AnyKey(k)) { s[keyPath: kp] = x }
        }
        v("autoEnterEnabled", \.autoEnterEnabled)
        v("thresholdAngle", \.thresholdAngle)
        v("countdownSeconds", \.countdownSeconds)
        v("requireAgentsRunning", \.requireAgentsRunning)
        v("rearmSeconds", \.rearmSeconds)
        v("graceSeconds", \.graceSeconds)
        v("caffeinate", \.caffeinate)
        v("faceID", \.faceID)
        v("faceOptions", \.faceOptions)
        v("showClock", \.showClock)
        v("faceFrameRate", \.faceFrameRate)
        v("showAgentCounts", \.showAgentCounts)
        v("showAgentList", \.showAgentList)
        v("showTailLogs", \.showTailLogs)
        v("showQuestions", \.showQuestions)
        v("tailLogCount", \.tailLogCount)
        v("panicEnabled", \.panicEnabled)
        v("panicSoundEnabled", \.panicSoundEnabled)
        v("panicRatio", \.panicRatio)
        v("panicSoundID", \.panicSoundID)
        v("panicStyleID", \.panicStyleID)
        v("panicVolume", \.panicVolume)
        v("touchIDFirst", \.touchIDFirst)
        v("hotkeyEnabled", \.hotkeyEnabled)
        v("uiSoundsEnabled", \.uiSoundsEnabled)
        v("launchAtLogin", \.launchAtLogin)
        v("menuBarHoldSeconds", \.menuBarHoldSeconds)
        v("cloudSyncEnabled", \.cloudSyncEnabled)
        v("disabledProviders", \.disabledProviders)
        v("onboardingCompleted", \.onboardingCompleted)
        self = s
    }

    /// Clamp values into sane ranges (used after user edits).
    public func sanitized() -> ModeSettings {
        var s = self
        s.thresholdAngle = min(max(s.thresholdAngle, 20), 140)
        s.countdownSeconds = min(max(s.countdownSeconds, 0), 60)
        s.rearmSeconds = min(max(s.rearmSeconds, 0), 3600)
        s.graceSeconds = min(max(s.graceSeconds, 0), 3600)
        s.panicRatio = min(max(s.panicRatio, 0.3), 0.99)
        s.tailLogCount = min(max(s.tailLogCount, 1), 50)
        s.faceFrameRate = s.faceFrameRate >= 45 ? 60 : 30
        s.panicVolume = min(max(s.panicVolume, 0), 1)
        s.menuBarHoldSeconds = min(max(s.menuBarHoldSeconds, 0), 600)
        return s
    }
}

/// A face option value (faces declare their own options).
public enum FaceOptionValue: Codable, Equatable, Sendable, Hashable {
    case bool(Bool)
    case number(Double)
    case string(String)

    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
