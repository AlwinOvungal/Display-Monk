import XCTest
@testable import DisplayMonkCore

final class BrightnessSyncTests: XCTestCase {
    private let on = BrightnessSync(isEnabled: true)
    private let off = BrightnessSync(isEnabled: false)

    func testTurningOnMatchesTheReferenceDisplay() {
        let writes = on.match(levels: ["A": 0.4, "B": 0.7], to: "B")
        XCTAssertEqual(writes, ["A": 0.7])
    }

    func testMatchingSkipsDisplaysAlreadyAtTheLevel() {
        XCTAssertEqual(on.match(levels: ["A": 0.6, "B": 0.6], to: "A"), [:])
        XCTAssertEqual(on.match(levels: ["A": 0.6, "B": 0.603, "C": 0.2], to: "A"), ["C": 0.6])
    }

    func testChangesFlowInBothDirections() {
        XCTAssertEqual(on.follow("A", changedTo: 0.75, levels: ["A": 0.75, "B": 0.6]), ["B": 0.75])
        XCTAssertEqual(on.follow("B", changedTo: 0.3, levels: ["A": 0.75, "B": 0.3]), ["A": 0.3])
    }

    func testNeverWritesBackToTheDisplayThatChanged() {
        // Even if its published level hasn't caught up yet, the changed display gets no write,
        // so a write can't come back around as another change.
        let writes = on.follow("A", changedTo: 0.5, levels: ["A": 0.9, "B": 0.9, "C": 0.9])
        XCTAssertEqual(writes, ["B": 0.5, "C": 0.5])
        XCTAssertNil(writes["A"])
    }

    func testFollowingAMatchedChangeWritesNothing() {
        // The second display already took the level: applying its update changes nothing.
        XCTAssertEqual(on.follow("B", changedTo: 0.75, levels: ["A": 0.75, "B": 0.75]), [:])
    }

    func testOffWritesNothing() {
        XCTAssertEqual(off.follow("A", changedTo: 0.2, levels: ["A": 0.2, "B": 0.9]), [:])
        XCTAssertEqual(off.match(levels: ["A": 0.2, "B": 0.9], to: "A"), [:])
        XCTAssertEqual(off.matchNewcomers(["B"], levels: ["A": 0.2, "B": 0.9], reference: "A"), [:])
    }

    func testOneDisplayNeedsNoWrites() {
        XCTAssertEqual(on.follow("A", changedTo: 0.2, levels: ["A": 0.2]), [:])
        XCTAssertEqual(on.match(levels: ["A": 0.2], to: "A"), [:])
        XCTAssertEqual(on.matchNewcomers(["A"], levels: ["A": 0.2], reference: "A"), [:])
    }

    func testReconnectedDisplayTakesTheConnectedDisplaysLevel() {
        XCTAssertEqual(on.matchNewcomers(["B"], levels: ["A": 0.55, "B": 1], reference: "A"), ["B": 0.55])
        XCTAssertEqual(on.matchNewcomers(["B"], levels: ["A": 0.55, "B": 0.552], reference: "A"), [:])
    }

    func testOnlyNewcomersChangeWhenOthersWereConnected() {
        // C drifted while connected; plugging in B doesn't silently change C.
        let writes = on.matchNewcomers(["B"], levels: ["A": 0.5, "B": 1, "C": 0.8], reference: "A")
        XCTAssertEqual(writes, ["B": 0.5])
    }

    func testAtLaunchEveryoneMatchesTheReference() {
        let writes = on.matchNewcomers(["A", "B", "C"], levels: ["A": 0.5, "B": 1, "C": 0.5], reference: "A")
        XCTAssertEqual(writes, ["B": 0.5])
    }

    func testLevelsAreClamped() {
        XCTAssertEqual(on.follow("A", changedTo: 1.4, levels: ["A": 1, "B": 0.5]), ["B": 1])
        XCTAssertEqual(on.follow("A", changedTo: -1, levels: ["A": 0, "B": 0.5]), ["B": 0])
    }

    func testIsMatched() {
        XCTAssertTrue(BrightnessSync.isMatched([0.5, 0.504]))
        XCTAssertFalse(BrightnessSync.isMatched([0.5, 0.52]))
        XCTAssertTrue(BrightnessSync.isMatched([Double]()))
        XCTAssertTrue(BrightnessSync.isMatched([0.3]))
    }
}
