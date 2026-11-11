import AgenttyHost
import AgenttyProtocol
import XCTest

final class SizeArbiterTests: XCTestCase {
    private let mac = TermSize(cols: 160, rows: 48)
    private let phone = TermSize(cols: 48, rows: 30)

    func testLastClientToAttachDrives() {
        var arbiter = SizeArbiter()
        XCTAssertTrue(arbiter.report(1, size: mac))
        XCTAssertEqual(arbiter.currentSize, mac)
        XCTAssertTrue(arbiter.report(2, size: phone))
        XCTAssertEqual(arbiter.driver, 2)
        XCTAssertEqual(arbiter.currentSize, phone)
    }

    func testTypingTakesControlBack() {
        var arbiter = SizeArbiter()
        arbiter.report(1, size: mac)
        arbiter.report(2, size: phone)
        XCTAssertTrue(arbiter.activity(1))
        XCTAssertEqual(arbiter.driver, 1)
        XCTAssertEqual(arbiter.currentSize, mac)
        XCTAssertFalse(arbiter.activity(1), "the driver typing again changes nothing")
    }

    func testDriverLeavingHandsOverToThePreviousClient() {
        var arbiter = SizeArbiter()
        arbiter.report(1, size: mac)
        arbiter.report(2, size: phone)
        XCTAssertTrue(arbiter.remove(2))
        XCTAssertEqual(arbiter.driver, 1)
        XCTAssertEqual(arbiter.currentSize, mac)
    }

    func testSizeIsKeptWhenEveryoneLeaves() {
        var arbiter = SizeArbiter()
        arbiter.report(2, size: phone)
        XCTAssertFalse(arbiter.remove(2))
        XCTAssertTrue(arbiter.isEmpty)
        XCTAssertEqual(arbiter.currentSize, phone)
    }

    func testNonDriverLeavingChangesNothing() {
        var arbiter = SizeArbiter()
        arbiter.report(1, size: mac)
        arbiter.report(2, size: phone)
        XCTAssertFalse(arbiter.remove(1))
        XCTAssertEqual(arbiter.currentSize, phone)
    }

    func testUnknownClientActivityIsIgnored() {
        var arbiter = SizeArbiter()
        arbiter.report(1, size: mac)
        XCTAssertFalse(arbiter.activity(99))
        XCTAssertEqual(arbiter.driver, 1)
    }

    func testSameSizeFromTwoClientsIsNotAChange() {
        var arbiter = SizeArbiter()
        arbiter.report(1, size: mac)
        XCTAssertFalse(arbiter.report(2, size: mac))
        XCTAssertEqual(arbiter.driver, 2)
    }
}
