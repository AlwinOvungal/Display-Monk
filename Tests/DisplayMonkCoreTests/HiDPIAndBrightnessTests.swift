import XCTest
@testable import DisplayMonkCore

final class CombinedBrightnessTests: XCTestCase {
    func testUpperRangeDrivesBacklight() {
        XCTAssertEqual(CombinedBrightness.components(for: 1).hardware, 1)
        XCTAssertEqual(CombinedBrightness.components(for: 1).software, 1)
        XCTAssertEqual(CombinedBrightness.components(for: 0.625).hardware, 0.5)
        XCTAssertEqual(CombinedBrightness.components(for: 0.25).hardware, 0)
        XCTAssertEqual(CombinedBrightness.components(for: 0.25).software, 1)
    }

    func testLowerRangeDimsInSoftwareToBlack() {
        XCTAssertEqual(CombinedBrightness.components(for: 0.125).hardware, 0)
        XCTAssertEqual(CombinedBrightness.components(for: 0.125).software, 0.5)
        XCTAssertEqual(CombinedBrightness.components(for: 0).software, 0)
        XCTAssertEqual(CombinedBrightness.components(for: -1).software, 0)
    }

    func testRoundTrips() {
        for level in stride(from: 0.0, through: 1.0, by: 0.05) {
            let parts = CombinedBrightness.components(for: level)
            XCTAssertEqual(CombinedBrightness.level(hardware: parts.hardware, software: parts.software), level, accuracy: 1e-9)
        }
    }

    func testBacklightReadingWinsOverStaleSoftwareLevel() {
        // The monitor was brightened with its own buttons while software dimming was saved.
        XCTAssertEqual(CombinedBrightness.level(hardware: 0.5, software: 0.2), 0.625)
    }
}

final class HiDPIOverrideTests: XCTestCase {
    func testScaleResolutionEntry() {
        // 2048x1152 HiDPI -> 4096x2304 framebuffer, flag 1.
        XCTAssertEqual(
            HiDPIOverride.scaleResolutionEntry(LogicalSize(width: 2048, height: 1152)),
            [0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x01]
        )
    }

    func testRelativePath() {
        XCTAssertEqual(HiDPIOverride.relativePath(vendorID: 0x1E6D, productID: 0x7750), "DisplayVendorID-1e6d/DisplayProductID-7750")
    }

    func testPresetsForQHD() {
        let sizes = HiDPIOverride.presetSizes(nativeWidth: 2560, nativeHeight: 1440)
        XCTAssertEqual(sizes.first, LogicalSize(width: 1280, height: 720))
        XCTAssertEqual(sizes.last, LogicalSize(width: 2560, height: 1440))
        XCTAssertTrue(sizes.contains(LogicalSize(width: 2048, height: 1152)))
        XCTAssertTrue(sizes.contains(LogicalSize(width: 1920, height: 1080)))
        XCTAssertEqual(sizes.count, 21)
        XCTAssertTrue(sizes.allSatisfy { $0.height % 2 == 0 })
        XCTAssertEqual(HiDPIOverride.defaultSize(in: sizes, nativeWidth: 2560), LogicalSize(width: 2048, height: 1152))
    }

    func testPresetsRespectFramebufferLimit() {
        let sizes = HiDPIOverride.presetSizes(nativeWidth: 3840, nativeHeight: 2160, maxFramebufferWidth: 6144)
        XCTAssertEqual(sizes.last, LogicalSize(width: 3072, height: 1728))
        XCTAssertTrue(sizes.allSatisfy { $0.width * 2 <= 6144 })
    }

    func testPresetsForUltrawide() {
        let sizes = HiDPIOverride.presetSizes(nativeWidth: 3440, nativeHeight: 1440)
        XCTAssertEqual(sizes.first, LogicalSize(width: 1720, height: 720))
        XCTAssertEqual(sizes.last, LogicalSize(width: 3440, height: 1440))
    }

    func testNoPresetsWithoutNativeSize() {
        XCTAssertTrue(HiDPIOverride.presetSizes(nativeWidth: 0, nativeHeight: 0).isEmpty)
    }
}

final class SafetyTests: XCTestCase {
    func testUserControls() {
        XCTAssertTrue(VCPCode.brightness.isUserControl)
        XCTAssertTrue(VCPCode.inputSource.isUserControl)
        XCTAssertFalse(VCPCode.restoreFactoryDefaults.isUserControl)
        XCTAssertFalse(VCPCode.powerMode.isUserControl)
        XCTAssertFalse(VCPCode.redGain.isUserControl)
        XCTAssertTrue(VCPCode.volume.isContinuous)
        XCTAssertFalse(VCPCode.inputSource.isContinuous)
    }

    func testThrottleSkipsUnchangedValues() {
        var throttle = WriteThrottle<Double>(minimumInterval: 0.1)
        XCTAssertEqual(throttle.decision(for: 0.5, now: 0), .send)
        throttle.recordSent(0.5, at: 0)
        XCTAssertEqual(throttle.decision(for: 0.5, now: 5), .skip)
        throttle.reset()
        XCTAssertEqual(throttle.decision(for: 0.5, now: 5), .send)
    }

    func testThrottleSpacesOutWrites() {
        var throttle = WriteThrottle<Double>(minimumInterval: 0.1)
        throttle.recordSent(0.5, at: 10)
        guard case let .wait(delay) = throttle.decision(for: 0.6, now: 10.04) else {
            return XCTFail("expected a wait")
        }
        XCTAssertEqual(delay, 0.06, accuracy: 1e-9)
        XCTAssertEqual(throttle.decision(for: 0.6, now: 10.11), .send)
    }
}
