/// Keeps several displays at one brightness level. The decisions only: each function returns
/// the brightness writes that are actually needed, keyed by display, and never one for the
/// display that started the change. Applying them doesn't ask for another sync, so changes
/// can't bounce between displays.
public struct BrightnessSync: Equatable, Sendable {
    /// Levels closer than this count as equal, so displays that already match get no write.
    public static let tolerance = 0.005

    public var isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    /// Brings every display to `reference`'s level: when sync is turned on, or on request
    /// after the displays drifted apart (for example through macOS auto-brightness).
    public func match<Key: Hashable>(levels: [Key: Double], to reference: Key) -> [Key: Double] {
        guard isEnabled, let level = levels[reference] else { return [:] }
        return writes(to: level, levels: levels, targets: levels.keys.filter { $0 != reference })
    }

    /// A person changed one display's brightness: the others follow.
    public func follow<Key: Hashable>(_ key: Key, changedTo level: Double, levels: [Key: Double]) -> [Key: Double] {
        guard isEnabled else { return [:] }
        return writes(to: level, levels: levels, targets: levels.keys.filter { $0 != key })
    }

    /// Displays connected, or the app started, while sync is on. Newcomers take the level of
    /// `reference`, a display that was already connected. When every display is new (at
    /// launch), `reference` keeps its level and the others match it.
    public func matchNewcomers<Key: Hashable>(_ newcomers: Set<Key>, levels: [Key: Double], reference: Key) -> [Key: Double] {
        guard isEnabled, levels.count > 1, let level = levels[reference] else { return [:] }
        let targets = newcomers.contains(reference) ? levels.keys.filter { $0 != reference } : newcomers.filter { $0 != reference }
        return writes(to: level, levels: levels, targets: targets)
    }

    /// Whether all levels are within `tolerance` of each other.
    public static func isMatched(_ levels: some Collection<Double>) -> Bool {
        guard let low = levels.min(), let high = levels.max() else { return true }
        return high - low <= tolerance
    }

    private func writes<Key: Hashable>(to level: Double, levels: [Key: Double], targets: some Sequence<Key>) -> [Key: Double] {
        let level = min(1, max(0, level))
        var result: [Key: Double] = [:]
        for key in targets {
            guard let current = levels[key], abs(current - level) > Self.tolerance else { continue }
            result[key] = level
        }
        return result
    }
}
