import XCTest
@testable import DisplayMonkCore

final class SVGPathTests: XCTestCase {
    func testAbsoluteCommands() {
        XCTAssertEqual(SVGPath.parse("M1 2L3 4H5V6C7 8 9 10 11 12Z"), [
            .move(x: 1, y: 2), .line(x: 3, y: 4), .line(x: 5, y: 4), .line(x: 5, y: 6),
            .curve(x1: 7, y1: 8, x2: 9, y2: 10, x: 11, y: 12), .close,
        ])
    }

    func testRelativeCommandsAndImplicitLines() {
        XCTAssertEqual(SVGPath.parse("m10 10 5 0 l0 5 h-5 v-5 c1 1 2 2 3 3 z"), [
            .move(x: 10, y: 10), .line(x: 15, y: 10), .line(x: 15, y: 15), .line(x: 10, y: 15),
            .line(x: 10, y: 10), .curve(x1: 11, y1: 11, x2: 12, y2: 12, x: 13, y: 13), .close,
        ])
    }

    func testCompactNumbers() {
        XCTAssertEqual(SVGPath.parse("M-0.5.5L1e1,2-3-4"), [
            .move(x: -0.5, y: 0.5), .line(x: 10, y: 2), .line(x: -3, y: -4),
        ])
        XCTAssertEqual(SVGPath.parse("M1e-1 2"), [.move(x: 0.1, y: 2)])
    }

    func testRejectsMalformedData() {
        XCTAssertNil(SVGPath.parse("M1"))
        XCTAssertNil(SVGPath.parse("1 2"))
        XCTAssertNil(SVGPath.parse("M1 2 Q3 4 5 6"))
        XCTAssertNil(SVGPath.parse("M1 2 L3 x"))
    }

    /// The stand and screen paths of Resources/MenuBarIcon.svg.
    func testParsesTheMenuBarArtwork() throws {
        let stand = try XCTUnwrap(SVGPath.parse("M17.9482 41.5355C17.2099 41.4061 17.3045 40.3184 18.054 40.3184H29.0966C29.8578 40.3184 29.9443 41.4271 29.1924 41.5453C28.1707 41.7058 28.1413 43.1664 29.1558 43.3679L32.1298 43.9585C32.7087 44.0735 32.6249 44.9258 32.0347 44.9258H15.3947C14.8075 44.9258 14.713 44.0829 15.2857 43.9529L17.9931 43.3383C18.9726 43.116 18.9375 41.7088 17.9482 41.5355Z"))
        XCTAssertEqual(stand.first, .move(x: 17.9482, y: 41.5355))
        XCTAssertEqual(stand.last, .close)
        XCTAssertEqual(stand.count, 12)
        XCTAssertTrue(stand.contains(.line(x: 29.0966, y: 40.3184)))

        let screen = try XCTUnwrap(SVGPath.parse("M11 26.0742C11 22.303 11 20.4174 12.1716 19.2458C13.3431 18.0742 15.2288 18.0742 19 18.0742H29C32.7712 18.0742 34.6569 18.0742 35.8284 19.2458C37 20.4174 37 22.303 37 26.0742V28.0742C37 31.8455 37 33.7311 35.8284 34.9026C34.6569 36.0742 32.7712 36.0742 29 36.0742H19C15.2288 36.0742 13.3431 36.0742 12.1716 34.9026C11 33.7311 11 31.8455 11 28.0742V26.0742Z"))
        XCTAssertEqual(screen.count, 14)
        XCTAssertTrue(screen.contains(.line(x: 37, y: 28.0742)))
    }
}
