import DisplayMonkCore
import Foundation

/// A DDC/CI connection to one display. Calls block for tens of milliseconds and must not run on
/// the main thread; implementations serialize access internally.
public protocol DDCChannel: AnyObject {
    func write(_ code: VCPCode, value: UInt16) -> Bool
    func read(_ code: VCPCode) -> Result<VCPReply, DDCError>
}

public enum DDCError: Error, CustomStringConvertible {
    case transportFailed(IOReturn)
    case invalidReply(DDCReplyError)
    case noReply

    public var description: String {
        switch self {
        case let .transportFailed(code): "I2C transfer failed (IOReturn 0x\(String(UInt32(bitPattern: code), radix: 16)))"
        case let .invalidReply(error): error.description
        case .noReply: "display did not reply"
        }
    }
}

/// Timing for one DDC conversation. Displays are slow and many drop requests that arrive too
/// quickly, so writes are repeated and reads are retried.
struct DDCTiming {
    var writeRepeats = 2
    var delayBeforeWrite: useconds_t = 10_000
    var delayBeforeRead: useconds_t = 50_000
    var retries = 4
    var delayBetweenRetries: useconds_t = 20_000
}

public enum DDCChannels {
    /// Finds a DDC channel for every external display that has one.
    public static func discover(for displays: [Display]) -> [CGDirectDisplayID: DDCChannel] {
        let externals = displays.filter { !$0.isBuiltIn }
        #if arch(arm64)
            return AVServiceChannel.discover(for: externals)
        #else
            var channels: [CGDirectDisplayID: DDCChannel] = [:]
            for display in externals {
                channels[display.id] = FramebufferChannel(display: display)
            }
            return channels
        #endif
    }
}
