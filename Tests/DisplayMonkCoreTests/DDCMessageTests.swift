import XCTest
@testable import DisplayMonkCore

final class DDCMessageTests: XCTestCase {
    func testSetVCPForAVService() {
        // 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32 = 0x9A
        XCTAssertEqual(DDCRequest.setVCP(.brightness, 50).avServiceMessage, [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
    }

    func testSetVCPForI2C() {
        XCTAssertEqual(DDCRequest.setVCP(.brightness, 50).i2cMessage, [0x51, 0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
    }

    func testSetVCPSplitsSixteenBitValue() {
        let message = DDCRequest.setVCP(.volume, 0x0123).avServiceMessage
        XCTAssertEqual(Array(message[2 ... 4]), [0x62, 0x01, 0x23])
    }

    func testGetVCPForAVServiceOmitsHostAddressFromChecksum() {
        // 0x6E ^ 0x82 ^ 0x01 ^ 0x10 = 0xFD
        XCTAssertEqual(DDCRequest.getVCP(.brightness).avServiceMessage, [0x82, 0x01, 0x10, 0xFD])
    }

    func testGetVCPForI2C() {
        // 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10 = 0xAC
        XCTAssertEqual(DDCRequest.getVCP(.brightness).i2cMessage, [0x51, 0x82, 0x01, 0x10, 0xAC])
    }

    private let brightnessReply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]

    func testParsesReply() throws {
        let reply = try VCPReply(parsing: brightnessReply, expecting: .brightness)
        XCTAssertEqual(reply, VCPReply(code: .brightness, current: 50, maximum: 100))
    }

    func testIgnoresTrailingBytes() throws {
        let reply = try VCPReply(parsing: brightnessReply + [0x00], expecting: .brightness)
        XCTAssertEqual(reply.current, 50)
    }

    func testRejectsBadChecksum() {
        var bytes = brightnessReply
        bytes[10] = 0x00
        XCTAssertThrowsError(try VCPReply(parsing: bytes, expecting: .brightness)) { error in
            XCTAssertEqual(error as? DDCReplyError, .badChecksum(expected: 0xF2, actual: 0x00))
        }
    }

    func testRejectsShortReply() {
        XCTAssertThrowsError(try VCPReply(parsing: [0x6E, 0x88], expecting: .brightness)) { error in
            XCTAssertEqual(error as? DDCReplyError, .tooShort(2))
        }
    }

    func testRejectsUnsupportedCode() {
        var bytes = brightnessReply
        bytes[3] = 0x01
        bytes[10] ^= 0x01
        XCTAssertThrowsError(try VCPReply(parsing: bytes, expecting: .brightness)) { error in
            XCTAssertEqual(error as? DDCReplyError, .unsupportedCode(.brightness))
        }
    }

    func testRejectsReplyForOtherCode() {
        var bytes = brightnessReply
        bytes[4] = 0x12
        bytes[10] ^= 0x10 ^ 0x12
        XCTAssertThrowsError(try VCPReply(parsing: bytes, expecting: .brightness)) { error in
            XCTAssertEqual(error as? DDCReplyError, .codeMismatch(expected: .brightness, actual: .contrast))
        }
    }
}

final class VCPCodeTests: XCTestCase {
    func testParsesArguments() {
        XCTAssertEqual(VCPCode(argument: "Brightness"), .brightness)
        XCTAssertEqual(VCPCode(argument: "0x62"), .volume)
        XCTAssertEqual(VCPCode(argument: "96"), .inputSource)
        XCTAssertNil(VCPCode(argument: "loudness"))
        XCTAssertNil(VCPCode(argument: "0x1FF"))
    }

    func testDescription() {
        XCTAssertEqual(VCPCode.brightness.description, "brightness (0x10)")
        XCTAssertEqual(VCPCode(rawValue: 0x0B).description, "0x0B")
    }

    func testInputSources() {
        XCTAssertEqual(InputSource.vcpValue(forArgument: "hdmi1"), 0x11)
        XCTAssertEqual(InputSource.vcpValue(forArgument: "HDMI"), 0x11)
        XCTAssertEqual(InputSource.vcpValue(forArgument: "usb-c"), 0x1B)
        XCTAssertEqual(InputSource.vcpValue(forArgument: "DP2"), 0x10)
        XCTAssertEqual(InputSource.vcpValue(forArgument: "0x0f"), 0x0F)
        XCTAssertNil(InputSource.vcpValue(forArgument: "scart"))
        XCTAssertEqual(InputSource(vcpValue: 0x0211), .hdmi1)
    }
}

final class EDIDIdentityTests: XCTestCase {
    func testParsesEDIDUUID() throws {
        let identity = try XCTUnwrap(EDIDIdentity(edidUUID: "10AC4AA0-0000-0000-2B1E-0104B53C2278"))
        XCTAssertEqual(identity.vendorID, 0x10AC)
        XCTAssertEqual(identity.manufacturerCode, "DEL")
        XCTAssertEqual(identity.productID, 0xA04A)
        XCTAssertEqual(identity.manufactureWeek, 43)
        XCTAssertEqual(identity.manufactureYear, 2020)
        XCTAssertEqual(identity.widthCM, 60)
        XCTAssertEqual(identity.heightCM, 34)
    }

    func testParsesEDIDBlob() throws {
        let edid: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00,
                             0x06, 0x10, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12,
                             0x01, 0x20, 0x01, 0x04, 0xB5, 0x3C, 0x22, 0x78]
        let identity = try XCTUnwrap(EDIDIdentity(edid: edid))
        XCTAssertEqual(identity.manufacturerCode, "APP")
        XCTAssertEqual(identity.productID, 0x1234)
        XCTAssertEqual(identity.serialNumber, 0x1234_5678)
        XCTAssertEqual(identity.manufactureYear, 2022)
    }

    func testRejectsMalformedInput() {
        XCTAssertNil(EDIDIdentity(edidUUID: "not-a-uuid"))
        XCTAssertNil(EDIDIdentity(edidUUID: "ZZAC4AA0-0000-0000-2B1E-0104B53C2278"))
        XCTAssertNil(EDIDIdentity(edid: [0x00, 0x01]))
    }
}
