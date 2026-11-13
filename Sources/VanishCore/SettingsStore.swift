import Foundation

/// User-facing app configuration, persisted as a JSON blob in UserDefaults.
public struct AppSettings: Codable {
    /// Effects the user switched off (their gesture is ignored). Optional on disk: older settings lack it.
    private var disabled: Set<EffectKind>?
    public var disabledEffects: Set<EffectKind> { get { disabled ?? [] } set { disabled = newValue } }
    /// Renderer-level effects whose gesture is listened for.
    public var enabledEffects: Set<EffectKind> {
        Set(EffectKind.allCases).subtracting(disabledEffects)
    }
    public var holdSeconds: Double = 0.5
    public var calibrationSeconds: Double = 4.0
    /// Preferred camera by localizedName; `cameraIndex` is the fallback when the name no longer matches.
    public var cameraName: String?
    public var cameraIndex: Int?
    public var outputWidth = 1280
    public var outputHeight = 720
    public var mirrorPreview = false
    public var soundEnabled = true
    public var soundVolume: Double = 0.7

    public init() {}
}

/// Thread-safe store: reads/writes the "appSettings" JSON blob and fires `onChange` after every write.
public final class SettingsStore {
    static let key = "appSettings"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var value: AppSettings
    /// Called (unspecified thread) after `settings` is persisted.
    public var onChange: ((AppSettings) -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.value = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    }

    public var settings: AppSettings {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set {
            lock.lock(); value = newValue; lock.unlock()
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) }
            onChange?(newValue)
        }
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        var s = settings
        mutate(&s)
        settings = s
    }
}
