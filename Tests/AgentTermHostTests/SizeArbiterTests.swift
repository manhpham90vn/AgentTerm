import AgentTermHost
import AgentTermProtocol
import XCTest

final class SizeArbiterTests: XCTestCase {
    private let mac = TermSize(cols: 160, rows: 48)
    private let phone = TermSize(cols: 48, rows: 30)

    func testTheClientThatTakesControlDrives() {
        var arbiter = SizeArbiter()
        XCTAssertTrue(arbiter.takeControl(1, size: mac))
        XCTAssertEqual(arbiter.currentSize, mac)
        XCTAssertTrue(arbiter.takeControl(2, size: phone))
        XCTAssertEqual(arbiter.driver, 2)
        XCTAssertEqual(arbiter.currentSize, phone)
    }

    func testWatchingDoesNotTakeTheSizeAway() {
        var arbiter = SizeArbiter()
        arbiter.takeControl(2, size: phone)
        // The Mac app attaches to a session a phone is using.
        XCTAssertFalse(arbiter.update(1, size: mac))
        XCTAssertEqual(arbiter.driver, 2)
        XCTAssertEqual(arbiter.currentSize, phone)
        // Its window is resized: still the phone's session.
        XCTAssertFalse(arbiter.update(1, size: TermSize(cols: 200, rows: 60)))
        XCTAssertEqual(arbiter.currentSize, phone)
        // The phone's keyboard comes up: its own change applies.
        let withKeyboard = TermSize(cols: 48, rows: 16)
        XCTAssertTrue(arbiter.update(2, size: withKeyboard))
        XCTAssertEqual(arbiter.currentSize, withKeyboard)
        // Typing on the Mac takes control at the size it last reported.
        XCTAssertTrue(arbiter.activity(1))
        XCTAssertEqual(arbiter.currentSize, TermSize(cols: 200, rows: 60))
    }

    func testTheFirstWatcherSetsTheSize() {
        var arbiter = SizeArbiter()
        XCTAssertTrue(arbiter.update(1, size: mac), "with nobody else there, the watcher's size is used")
        XCTAssertEqual(arbiter.driver, 1)
        XCTAssertFalse(arbiter.update(2, size: phone))
        XCTAssertEqual(arbiter.driver, 1)
        XCTAssertTrue(arbiter.remove(1), "the remaining watcher takes over")
        XCTAssertEqual(arbiter.currentSize, phone)
    }

    func testTypingTakesControlBack() {
        var arbiter = SizeArbiter()
        arbiter.takeControl(1, size: mac)
        arbiter.takeControl(2, size: phone)
        XCTAssertTrue(arbiter.activity(1))
        XCTAssertEqual(arbiter.driver, 1)
        XCTAssertEqual(arbiter.currentSize, mac)
        XCTAssertFalse(arbiter.activity(1), "the driver typing again changes nothing")
    }

    func testDriverLeavingHandsOverToThePreviousClient() {
        var arbiter = SizeArbiter()
        arbiter.takeControl(1, size: mac)
        arbiter.takeControl(2, size: phone)
        XCTAssertTrue(arbiter.remove(2))
        XCTAssertEqual(arbiter.driver, 1)
        XCTAssertEqual(arbiter.currentSize, mac)
    }

    func testSizeIsKeptWhenEveryoneLeaves() {
        var arbiter = SizeArbiter()
        arbiter.takeControl(2, size: phone)
        XCTAssertFalse(arbiter.remove(2))
        XCTAssertTrue(arbiter.isEmpty)
        XCTAssertEqual(arbiter.currentSize, phone)
    }

    func testNonDriverLeavingChangesNothing() {
        var arbiter = SizeArbiter()
        arbiter.takeControl(1, size: mac)
        arbiter.takeControl(2, size: phone)
        XCTAssertFalse(arbiter.remove(1))
        XCTAssertEqual(arbiter.currentSize, phone)
    }

    func testUnknownClientActivityIsIgnored() {
        var arbiter = SizeArbiter()
        arbiter.takeControl(1, size: mac)
        XCTAssertFalse(arbiter.activity(99))
        XCTAssertEqual(arbiter.driver, 1)
    }

    func testSameSizeFromTwoClientsIsNotAChange() {
        var arbiter = SizeArbiter()
        arbiter.takeControl(1, size: mac)
        XCTAssertFalse(arbiter.takeControl(2, size: mac))
        XCTAssertEqual(arbiter.driver, 2)
    }
}
