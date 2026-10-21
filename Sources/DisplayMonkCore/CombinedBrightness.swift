/// One brightness level spread across the backlight and software dimming, so a single slider
/// first lowers the real backlight and only then darkens the image, all the way to black.
public enum CombinedBrightness {
    /// Fraction of the slider given to software dimming, below the backlight's minimum.
    public static let split = 0.25

    /// Splits a 0...1 level into a hardware (backlight) level and a software (gamma) level.
    public static func components(for level: Double) -> (hardware: Double, software: Double) {
        let level = min(1, max(0, level))
        if level >= split {
            return ((level - split) / (1 - split), 1)
        }
        return (0, level / split)
    }

    /// The single level that `components(for:)` would split into these parts.
    public static func level(hardware: Double, software: Double) -> Double {
        let hardware = min(1, max(0, hardware))
        let software = min(1, max(0, software))
        if hardware > 0 || software >= 1 {
            return split + hardware * (1 - split)
        }
        return software * split
    }
}
