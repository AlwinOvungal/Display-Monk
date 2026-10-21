/// DDC/CI message framing (VESA DDC/CI 1.1). Pure byte manipulation, no I/O.
public enum DDC {
    /// 7-bit I2C address of the display's DDC/CI endpoint.
    public static let chipAddress: UInt8 = 0x37
    /// 8-bit write address of the display (`chipAddress << 1`), the first byte every checksum covers.
    public static let displayWriteAddress: UInt8 = 0x6E
    /// Source address the host puts in front of every request.
    public static let hostAddress: UInt8 = 0x51
    /// Displays compute reply checksums against this virtual host address.
    public static let replyChecksumSeed: UInt8 = 0x50
    /// Size of a Get VCP Feature reply: source, length, opcode, result, code, type, max(2), current(2), checksum.
    public static let vcpReplyLength = 11

    public static func checksum(seed: UInt8, _ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(seed, ^)
    }
}

public enum DDCRequest: Equatable, Sendable {
    case getVCP(VCPCode)
    case setVCP(VCPCode, UInt16)

    public var isRead: Bool {
        if case .getVCP = self { return true }
        return false
    }

    /// Length byte (0x80 | payload count) followed by opcode and arguments.
    var body: [UInt8] {
        let payload: [UInt8]
        switch self {
        case let .getVCP(code):
            payload = [0x01, code.rawValue]
        case let .setVCP(code, value):
            payload = [0x03, code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)]
        }
        return [0x80 | UInt8(payload.count)] + payload
    }

    /// Bytes for a raw I2C transaction sent to `displayWriteAddress` (the Intel IOFramebuffer path):
    /// host address, body, checksum over everything including the destination address.
    public var i2cMessage: [UInt8] {
        let message = [DDC.hostAddress] + body
        return message + [DDC.checksum(seed: DDC.displayWriteAddress, message)]
    }

    /// Bytes for `IOAVServiceWriteI2C` (the Apple Silicon path), which sends the host address itself
    /// as the I2C sub-address, so it is left out of the buffer.
    ///
    /// Read requests leave the host address out of the checksum too. That is what MonitorControl and
    /// m1ddc send on this path and what displays in the field accept; writes use the full checksum.
    public var avServiceMessage: [UInt8] {
        let seed = isRead ? DDC.displayWriteAddress : DDC.displayWriteAddress ^ DDC.hostAddress
        return body + [DDC.checksum(seed: seed, body)]
    }
}

public struct VCPReply: Equatable, Sendable {
    public let code: VCPCode
    public let current: UInt16
    public let maximum: UInt16
    /// MCCS "type" byte: 0 = set parameter, 1 = momentary.
    public let type: UInt8

    public init(code: VCPCode, current: UInt16, maximum: UInt16, type: UInt8 = 0) {
        self.code = code
        self.current = current
        self.maximum = maximum
        self.type = type
    }
}

public enum DDCReplyError: Error, Equatable, CustomStringConvertible {
    case tooShort(Int)
    case badChecksum(expected: UInt8, actual: UInt8)
    case unexpectedOpcode(UInt8)
    case unsupportedCode(VCPCode)
    case codeMismatch(expected: VCPCode, actual: VCPCode)

    public var description: String {
        switch self {
        case let .tooShort(count): "reply too short (\(count) bytes)"
        case let .badChecksum(expected, actual): "bad checksum (expected \(hex(expected)), got \(hex(actual)))"
        case let .unexpectedOpcode(opcode): "unexpected reply opcode \(hex(opcode))"
        case let .unsupportedCode(code): "display does not support \(code)"
        case let .codeMismatch(expected, actual): "reply is for \(actual), expected \(expected)"
        }
    }
}

extension VCPReply {
    /// Parses a Get VCP Feature reply as read back from the display (first byte is the source address).
    public init(parsing bytes: [UInt8], expecting code: VCPCode) throws {
        guard bytes.count >= DDC.vcpReplyLength else {
            throw DDCReplyError.tooShort(bytes.count)
        }
        let reply = Array(bytes.prefix(DDC.vcpReplyLength))
        let expected = DDC.checksum(seed: DDC.replyChecksumSeed, reply.dropLast())
        guard expected == reply[10] else {
            throw DDCReplyError.badChecksum(expected: expected, actual: reply[10])
        }
        guard reply[2] == 0x02 else {
            throw DDCReplyError.unexpectedOpcode(reply[2])
        }
        guard reply[3] == 0x00 else {
            throw DDCReplyError.unsupportedCode(code)
        }
        let replyCode = VCPCode(rawValue: reply[4])
        guard replyCode == code else {
            throw DDCReplyError.codeMismatch(expected: code, actual: replyCode)
        }
        self.init(
            code: code,
            current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
            maximum: UInt16(reply[6]) << 8 | UInt16(reply[7]),
            type: reply[5]
        )
    }
}

func hex(_ byte: UInt8) -> String {
    "0x" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
}
