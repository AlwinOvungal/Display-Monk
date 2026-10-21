/// Identifying fields from an EDID base block (bytes 8–23): vendor, product, serial, date and size.
///
/// Apple Silicon framebuffers publish these same 16 bytes as the "EDID UUID" registry property,
/// which is how a DDC service is tied back to the CoreGraphics display it drives.
public struct EDIDIdentity: Equatable, Sendable {
    /// Big-endian manufacturer ID, the value CoreGraphics reports as the vendor number.
    public let vendorID: UInt16
    public let productID: UInt16
    public let serialNumber: UInt32
    public let manufactureWeek: UInt8
    public let manufactureYear: Int
    /// Maximum image size in centimetres (0 when unknown or the display is a projector).
    public let widthCM: UInt8
    public let heightCM: UInt8

    /// Three-letter PNP ID, e.g. "DEL" or "APP".
    public var manufacturerCode: String {
        let letters = [(vendorID >> 10) & 0x1F, (vendorID >> 5) & 0x1F, vendorID & 0x1F]
        return String(letters.map { Character(Unicode.Scalar(UInt8($0) + 64)) })
    }

    /// `fields` must be EDID bytes 8–23.
    public init?(fields: [UInt8]) {
        guard fields.count >= 16 else { return nil }
        vendorID = UInt16(fields[0]) << 8 | UInt16(fields[1])
        productID = UInt16(fields[3]) << 8 | UInt16(fields[2])
        serialNumber = UInt32(fields[4]) | UInt32(fields[5]) << 8 | UInt32(fields[6]) << 16 | UInt32(fields[7]) << 24
        manufactureWeek = fields[8]
        manufactureYear = Int(fields[9]) + 1990
        widthCM = fields[13]
        heightCM = fields[14]
    }

    /// Reads the identity out of a full EDID blob (at least the 128-byte base block header).
    public init?(edid: [UInt8]) {
        let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        guard edid.count >= 24, Array(edid.prefix(8)) == header else { return nil }
        self.init(fields: Array(edid[8 ..< 24]))
    }

    /// Parses an "EDID UUID" string such as "10AC4AA0-0000-0000-2B1E-0104B53C2278".
    public init?(edidUUID: String) {
        let digits = Array(edidUUID.filter { $0 != "-" })
        guard digits.count == 32 else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: 32, by: 2) {
            guard let byte = UInt8(String(digits[index ... index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(fields: bytes)
    }
}
