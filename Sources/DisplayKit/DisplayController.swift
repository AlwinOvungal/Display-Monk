import CoreGraphics
import DisplayMonkCore
import Foundation

/// Everything that can be controlled on one display. DDC calls block, so call these off the
/// main thread.
public final class DisplayController {
    public let display: Display
    public let ddc: DDCChannel?
    private let lock = NSLock()
    private var maximums: [VCPCode: UInt16] = [:]

    init(display: Display, ddc: DDCChannel?) {
        self.display = display
        self.ddc = ddc
    }

    public var hasNativeBrightness: Bool {
        NativeBrightness.get(display.id) != nil
    }

    /// Native for Apple displays, DDC when the monitor has a channel, software otherwise.
    public var preferredBrightnessMethod: BrightnessMethod {
        if hasNativeBrightness { return .native }
        if ddc != nil { return .ddc }
        return .software
    }

    // MARK: Brightness

    public func brightness(using method: BrightnessMethod) -> Double? {
        switch method {
        case .native: NativeBrightness.get(display.id)
        case .ddc: try? level(.brightness).get()
        case .software: SoftwareDimmer.level(for: display.id)
        }
    }

    @discardableResult
    public func setBrightness(_ value: Double, using method: BrightnessMethod) -> Bool {
        switch method {
        case .native: NativeBrightness.set(value, for: display.id)
        case .ddc: setLevel(.brightness, value)
        case .software: SoftwareDimmer.setLevel(value, for: display.id)
        }
    }

    // MARK: DDC values

    /// A continuous VCP value as a 0...1 fraction of the display's maximum.
    public func level(_ code: VCPCode) -> Result<Double, DDCError> {
        read(code).map { LevelScale.fraction(fromRaw: $0.current, maximum: $0.maximum) }
    }

    @discardableResult
    public func setLevel(_ code: VCPCode, _ fraction: Double) -> Bool {
        let maximum = maximum(for: code)
        return write(code, value: LevelScale.raw(fromFraction: fraction, maximum: maximum))
    }

    public func read(_ code: VCPCode) -> Result<VCPReply, DDCError> {
        guard let ddc else { return .failure(.noReply) }
        let result = ddc.read(code)
        if case let .success(reply) = result, reply.maximum > 0 {
            lock.lock()
            maximums[code] = reply.maximum
            lock.unlock()
        }
        return result
    }

    @discardableResult
    public func write(_ code: VCPCode, value: UInt16) -> Bool {
        ddc?.write(code, value: value) ?? false
    }

    /// The display's reported maximum for a code, read once and cached. Displays that refuse
    /// reads are assumed to use the common 0...100 range.
    public func maximum(for code: VCPCode) -> UInt16 {
        lock.lock()
        let cached = maximums[code]
        lock.unlock()
        if let cached { return cached }
        if case let .success(reply) = read(code), reply.maximum > 0 { return reply.maximum }
        return 100
    }

    // MARK: Volume

    public func isMuted() -> Bool? {
        guard case let .success(reply) = read(.mute) else { return nil }
        return reply.current == 1
    }

    /// MCCS mute values: 1 = muted, 2 = unmuted.
    @discardableResult
    public func setMuted(_ muted: Bool) -> Bool {
        write(.mute, value: muted ? 1 : 2)
    }

    // MARK: Input

    public func inputSource() -> UInt16? {
        guard case let .success(reply) = read(.inputSource) else { return nil }
        return reply.current
    }

    @discardableResult
    public func setInputSource(_ value: UInt16) -> Bool {
        write(.inputSource, value: value)
    }
}
