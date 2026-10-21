import XCTest
@testable import DisplayMonkCore

final class ModeListTests: XCTestCase {
    private let modes: [ModeDescriptor] = [
        ModeDescriptor(id: 1, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60),
        ModeDescriptor(id: 2, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60),
        ModeDescriptor(id: 3, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 144),
        ModeDescriptor(id: 4, width: 3840, height: 2160, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60),
        ModeDescriptor(id: 5, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60),
        ModeDescriptor(id: 6, width: 640, height: 480, pixelWidth: 640, pixelHeight: 480, refreshRate: 60, isUsableForDesktop: false),
    ]

    func testOrganizeSortsDedupesAndFilters() {
        XCTAssertEqual(ModeList.organize(modes).map(\.id), [4, 3, 2, 1])
        XCTAssertEqual(ModeList.organize(modes, includeUnusable: true).map(\.id), [4, 3, 2, 1, 6])
    }

    func testBestMatchPrefersRequestedRate() {
        let spec = ModeSpec(width: 1920, height: 1080, refreshRate: 144)
        XCTAssertEqual(ModeList.bestMatch(for: spec, in: modes, current: nil)?.id, 3)
    }

    func testBestMatchKeepsCurrentRateWhenNoneRequested() {
        let spec = ModeSpec(width: 1920, height: 1080)
        XCTAssertEqual(ModeList.bestMatch(for: spec, in: modes, current: modes[3])?.id, 2)
    }

    func testBestMatchHonoursScaling() {
        let spec = ModeSpec(width: 1920, height: 1080, hiDPI: false)
        XCTAssertEqual(ModeList.bestMatch(for: spec, in: modes, current: nil)?.id, 1)
        XCTAssertNil(ModeList.bestMatch(for: ModeSpec(width: 3840, height: 2160, hiDPI: true), in: modes, current: nil))
    }

    func testDescriptions() {
        XCTAssertEqual(modes[2].description, "1920x1080 @ 144Hz HiDPI")
        let fractional = ModeDescriptor(id: 7, width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, refreshRate: 59.94)
        XCTAssertEqual(fractional.description, "1280x720 @ 59.94Hz")
    }

    func testParsesModeSpec() {
        XCTAssertEqual(ModeSpec("1920x1080"), ModeSpec(width: 1920, height: 1080))
        XCTAssertEqual(ModeSpec("2560X1440@144hz"), ModeSpec(width: 2560, height: 1440, refreshRate: 144))
        XCTAssertEqual(ModeSpec("1280x720@59.94"), ModeSpec(width: 1280, height: 720, refreshRate: 59.94))
        XCTAssertNil(ModeSpec("1920"))
        XCTAssertNil(ModeSpec("1920x1080@fast"))
        XCTAssertNil(ModeSpec("0x1080"))
    }
}

final class SelectorTests: XCTestCase {
    private let displays = [
        SelectableDisplay(id: 1, name: "Built-in Retina Display", isMain: false, isBuiltIn: true),
        SelectableDisplay(id: 5, name: "DELL U2720Q", isMain: true, isBuiltIn: false),
        SelectableDisplay(id: 9, name: "LG HDR 4K", isMain: false, isBuiltIn: false),
    ]

    func testResolvesSelectors() {
        XCTAssertEqual(DisplaySelector("main").resolve(in: displays), 1)
        XCTAssertEqual(DisplaySelector("builtin").resolve(in: displays), 0)
        XCTAssertEqual(DisplaySelector("external").resolve(in: displays), 1)
        XCTAssertEqual(DisplaySelector("2").resolve(in: displays), 2)
        XCTAssertEqual(DisplaySelector("id:9").resolve(in: displays), 2)
        XCTAssertEqual(DisplaySelector("lg").resolve(in: displays), 2)
        XCTAssertNil(DisplaySelector("7").resolve(in: displays))
        XCTAssertNil(DisplaySelector("samsung").resolve(in: displays))
    }
}

final class LevelTests: XCTestCase {
    func testParsesLevelChanges() {
        XCTAssertEqual(LevelChange("50"), .absolute(50))
        XCTAssertEqual(LevelChange(" 75% "), .absolute(75))
        XCTAssertEqual(LevelChange("+10"), .relative(10))
        XCTAssertEqual(LevelChange("-5"), .relative(-5))
        XCTAssertNil(LevelChange("loud"))
    }

    func testAppliesAndClamps() {
        XCTAssertEqual(LevelChange.relative(10).apply(to: 95), 100)
        XCTAssertEqual(LevelChange.relative(-30).apply(to: 20), 0)
        XCTAssertEqual(LevelChange.absolute(150).apply(to: 20), 100)
    }

    func testScalesRawValues() {
        XCTAssertEqual(LevelScale.raw(fromFraction: 0.5, maximum: 100), 50)
        XCTAssertEqual(LevelScale.raw(fromFraction: 1.2, maximum: 255), 255)
        XCTAssertEqual(LevelScale.fraction(fromRaw: 64, maximum: 255), 64.0 / 255.0)
        XCTAssertEqual(LevelScale.fraction(fromRaw: 10, maximum: 0), 0)
    }

    func testStepsSnapToGrid() {
        XCTAssertEqual(LevelScale.step(0.5, up: true, fine: false), 0.5625)
        XCTAssertEqual(LevelScale.step(0.51, up: false, fine: false), 0.4375)
        XCTAssertEqual(LevelScale.step(1, up: true, fine: false), 1)
        XCTAssertEqual(LevelScale.step(0, up: false, fine: true), 0)
        XCTAssertEqual(LevelScale.step(0.5, up: true, fine: true), 0.515625)
    }
}
