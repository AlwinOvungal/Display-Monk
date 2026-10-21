/// Decides when a value may be sent to a display. Displays store settings like brightness in
/// their own memory, so repeated identical writes are dropped and bursts are spaced out.
public struct WriteThrottle<Value: Equatable> {
    public enum Decision: Equatable {
        case send
        /// Try again after this many seconds; keep the value pending.
        case wait(Double)
        /// The display already has this value.
        case skip
    }

    public let minimumInterval: Double
    public private(set) var lastSent: Value?
    private var lastSentAt: Double?

    public init(minimumInterval: Double) {
        self.minimumInterval = minimumInterval
    }

    /// `now` is a monotonic time in seconds.
    public func decision(for value: Value, now: Double) -> Decision {
        if value == lastSent { return .skip }
        if let lastSentAt, now - lastSentAt < minimumInterval {
            return .wait(minimumInterval - (now - lastSentAt))
        }
        return .send
    }

    public mutating func recordSent(_ value: Value, at time: Double) {
        lastSent = value
        lastSentAt = time
    }

    /// Forget the last value, e.g. after reading the display shows it changed on its own.
    public mutating func reset() {
        lastSent = nil
    }
}

extension VCPCode {
    /// The everyday controls a monitor exposes in its own menu. Anything else (factory reset,
    /// power state, colour gains, vendor codes) is only written when explicitly forced.
    public static let userControls: Set<VCPCode> = [.brightness, .contrast, .volume, .mute, .inputSource]

    public var isUserControl: Bool {
        Self.userControls.contains(self)
    }

    /// Codes whose value is a level within the reported maximum, rather than an enumeration.
    public var isContinuous: Bool {
        self == .brightness || self == .contrast || self == .volume
    }
}
