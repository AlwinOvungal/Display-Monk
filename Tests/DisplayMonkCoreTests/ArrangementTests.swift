import XCTest
@testable import DisplayMonkCore

final class ArrangementTests: XCTestCase {
    private let macBook = DisplayRect(x: 0, y: 0, width: 1512, height: 982)
    private let monitor = (width: 2560.0, height: 1440.0)

    private func origin(_ placement: Placement, _ alignment: PlacementAlignment) -> DisplayPoint {
        Arrangement.origin(width: monitor.width, height: monitor.height, placement, alignment, relativeTo: macBook)
    }

    func testHorizontalPlacements() {
        XCTAssertEqual(origin(.right, .start), DisplayPoint(x: 1512, y: 0))
        XCTAssertEqual(origin(.right, .center), DisplayPoint(x: 1512, y: -229))
        XCTAssertEqual(origin(.right, .end), DisplayPoint(x: 1512, y: -458))
        XCTAssertEqual(origin(.left, .end), DisplayPoint(x: -2560, y: -458))
    }

    func testVerticalPlacements() {
        XCTAssertEqual(origin(.above, .center), DisplayPoint(x: -524, y: -1440))
        XCTAssertEqual(origin(.above, .start), DisplayPoint(x: 0, y: -1440))
        XCTAssertEqual(origin(.below, .end), DisplayPoint(x: -1048, y: 982))
    }

    func testInfersEveryPreset() {
        for placement in Placement.allCases {
            for alignment in PlacementAlignment.allCases {
                let o = origin(placement, alignment)
                let rect = DisplayRect(x: o.x, y: o.y, width: monitor.width, height: monitor.height)
                let inferred = Arrangement.placement(of: rect, relativeTo: macBook)
                XCTAssertEqual(inferred?.0, placement)
                XCTAssertEqual(inferred?.1, alignment)
            }
        }
    }

    func testSameSizeDisplaysReadAsCentred() {
        let twin = DisplayRect(x: 1512, y: 0, width: 1512, height: 982)
        XCTAssertEqual(Arrangement.placement(of: twin, relativeTo: macBook)?.1, .center)
    }

    func testCustomPositions() {
        let dragged = DisplayRect(x: 1512, y: -100, width: monitor.width, height: monitor.height)
        XCTAssertNil(Arrangement.placement(of: dragged, relativeTo: macBook))
        XCTAssertEqual(Arrangement.nearestPlacement(of: dragged, relativeTo: macBook), .right)
        let overhead = DisplayRect(x: 300, y: -1440, width: monitor.width, height: monitor.height)
        XCTAssertEqual(Arrangement.nearestPlacement(of: overhead, relativeTo: macBook), .above)
    }

    func testAlignmentLabels() {
        XCTAssertEqual(PlacementAlignment.start.label(for: .left), "Top")
        XCTAssertEqual(PlacementAlignment.end.label(for: .below), "Right")
        XCTAssertEqual(PlacementAlignment.center.label(for: .above), "Center")
    }

    func testMakingMainShiftsEveryOrigin() {
        let rects = [macBook, DisplayRect(x: 1512, y: -229, width: 2560, height: 1440)]
        XCTAssertEqual(Arrangement.originsMakingMain(1, rects: rects), [DisplayPoint(x: -1512, y: 229), DisplayPoint(x: 0, y: 0)])
        XCTAssertEqual(Arrangement.originsMakingMain(5, rects: rects).count, 2)
    }
}

final class ClosestModeTests: XCTestCase {
    func testPicksNearestHiDPISize() {
        let modes = [
            ModeDescriptor(id: 1, width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60),
            ModeDescriptor(id: 2, width: 2048, height: 1152, pixelWidth: 4096, pixelHeight: 2304, refreshRate: 60),
            ModeDescriptor(id: 3, width: 2048, height: 1152, pixelWidth: 4096, pixelHeight: 2304, refreshRate: 144),
            ModeDescriptor(id: 4, width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60),
        ]
        let current = modes[0]
        XCTAssertEqual(ModeList.closestHiDPI(to: LogicalSize(width: 2560, height: 1440), in: modes, current: current)?.id, 2)
        XCTAssertEqual(ModeList.closestHiDPI(to: LogicalSize(width: 1400, height: 788), in: modes, current: current)?.id, 4)
        XCTAssertNil(ModeList.closestHiDPI(to: LogicalSize(width: 2560, height: 1440), in: [modes[0]], current: current))
    }
}
