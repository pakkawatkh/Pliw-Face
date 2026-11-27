import Foundation

public enum LivenessMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case fast
    case balanced
    case strict

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .strict: return "Strict"
        }
    }

    public var summary: String {
        switch self {
        case .fast:
            return "Instant deny-cue anti-spoofing (glare & screen bezel)"
        case .balanced:
            return "Deny cues + 3D geometry / micro-motion confirmation"
        case .strict:
            return "Deny cues + required eye blink or clear head parallax"
        }
    }
}

public enum SessionTimeoutOption: Int, CaseIterable, Codable, Identifiable, Sendable {
    case oneHour = 3600
    case fourHours = 14400
    case eightHours = 28800
    case never = 0

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .oneHour: return "1 Hour"
        case .fourHours: return "4 Hours"
        case .eightHours: return "8 Hours"
        case .never: return "Never"
        }
    }

    public var timeInterval: TimeInterval? {
        rawValue > 0 ? TimeInterval(rawValue) : nil
    }
}

public enum NotchHUDStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case notchWings
    case dynamicIsland

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .notchWings: return "Notch Wings"
        case .dynamicIsland: return "Dynamic Island"
        }
    }

    public var summary: String {
        switch self {
        case .notchWings:
            return "Horizontal wings flush with the MacBook notch"
        case .dynamicIsland:
            return "iPhone-style Face ID squircle expanding below the notch"
        }
    }
}

public struct FaceSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var unlockOnWake: Bool
    public var unlockOnLock: Bool
    public var unlockOnSpacebar: Bool
    public var livenessMode: LivenessMode
    public var similarityThreshold: Float
    public var sessionTimeout: SessionTimeoutOption
    public var hapticFeedback: Bool
    public var scanTimeoutSeconds: TimeInterval
    public var showNotchHUD: Bool
    public var hudStyle: NotchHUDStyle
    public var unlockOnNotchHover: Bool
    public var autoArmOnLaunch: Bool

    public init(
        isEnabled: Bool = true,
        unlockOnWake: Bool = true,
        unlockOnLock: Bool = false,
        unlockOnSpacebar: Bool = true,
        livenessMode: LivenessMode = .balanced,
        similarityThreshold: Float = 0.46,
        sessionTimeout: SessionTimeoutOption = .never,
        hapticFeedback: Bool = true,
        scanTimeoutSeconds: TimeInterval = 3.0,
        showNotchHUD: Bool = true,
        hudStyle: NotchHUDStyle = .notchWings,
        unlockOnNotchHover: Bool = true,
        autoArmOnLaunch: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.unlockOnWake = unlockOnWake
        self.unlockOnLock = unlockOnLock
        self.unlockOnSpacebar = unlockOnSpacebar
        self.livenessMode = livenessMode
        self.similarityThreshold = similarityThreshold
        self.sessionTimeout = sessionTimeout
        self.hapticFeedback = hapticFeedback
        self.scanTimeoutSeconds = scanTimeoutSeconds
        self.showNotchHUD = showNotchHUD
        self.hudStyle = hudStyle
        self.unlockOnNotchHover = unlockOnNotchHover
        self.autoArmOnLaunch = autoArmOnLaunch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.unlockOnWake = try c.decodeIfPresent(Bool.self, forKey: .unlockOnWake) ?? true
        self.unlockOnLock = try c.decodeIfPresent(Bool.self, forKey: .unlockOnLock) ?? false
        self.unlockOnSpacebar = try c.decodeIfPresent(Bool.self, forKey: .unlockOnSpacebar) ?? true
        self.livenessMode = try c.decodeIfPresent(LivenessMode.self, forKey: .livenessMode) ?? .balanced
        self.similarityThreshold = try c.decodeIfPresent(Float.self, forKey: .similarityThreshold) ?? 0.46
        self.sessionTimeout = try c.decodeIfPresent(SessionTimeoutOption.self, forKey: .sessionTimeout) ?? .never
        self.hapticFeedback = try c.decodeIfPresent(Bool.self, forKey: .hapticFeedback) ?? true
        self.scanTimeoutSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .scanTimeoutSeconds) ?? 3.0
        self.showNotchHUD = try c.decodeIfPresent(Bool.self, forKey: .showNotchHUD) ?? true
        self.hudStyle = try c.decodeIfPresent(NotchHUDStyle.self, forKey: .hudStyle) ?? .notchWings
        self.unlockOnNotchHover = try c.decodeIfPresent(Bool.self, forKey: .unlockOnNotchHover) ?? true
        self.autoArmOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoArmOnLaunch) ?? true
    }

    private static let storageKey = "com.local.pliw-face.settings.v1"

    public static func load(from defaults: UserDefaults = .standard) -> FaceSettings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(FaceSettings.self, from: data) else {
            return FaceSettings()
        }
        return decoded
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
