import XCTest

@testable import AgentTermHost

final class DeviceRegistryTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let local = "local-token-0123456789abcdef0123456789"

    private func registry(file: URL? = nil) -> DeviceRegistry {
        DeviceRegistry(localToken: local, file: file, now: { [unowned self] in self.clock })
    }

    func testACodePairsOneDeviceOnce() throws {
        let registry = registry()
        let created = registry.createCode()
        XCTAssertEqual(created.expiresAt, clock.addingTimeInterval(300))
        XCTAssertGreaterThanOrEqual(created.code.count, 40, "long enough that guessing is not a concern")

        XCTAssertNil(registry.redeem(code: "wrong", deviceName: "intruder"))
        let paired = try XCTUnwrap(registry.redeem(code: created.code, deviceName: "  iPhone của Mạnh \n"))
        XCTAssertEqual(paired.device.name, "iPhone của Mạnh")
        XCTAssertNotEqual(paired.token, created.code)
        XCTAssertNil(registry.redeem(code: created.code, deviceName: "second phone"), "a code is used up by the first device")
        XCTAssertEqual(registry.devices().map(\.name), ["iPhone của Mạnh"])
    }

    func testCodesExpireAndCanBeCancelledOrReplaced() {
        let registry = registry()
        let first = registry.createCode()
        clock += 299
        let second = registry.createCode()
        XCTAssertNil(registry.redeem(code: first.code, deviceName: "a"), "a new code replaces the old one")

        clock += 300
        XCTAssertNil(registry.redeem(code: second.code, deviceName: "a"), "expired")

        let third = registry.createCode()
        registry.cancelCode()
        XCTAssertNil(registry.redeem(code: third.code, deviceName: "a"), "cancelled")
        XCTAssertTrue(registry.devices().isEmpty)
    }

    func testTheLocalTokenOnlyWorksOnThisMac() throws {
        let registry = registry()
        XCTAssertEqual(registry.authenticate(token: local, isLocal: true), .local)
        XCTAssertNil(registry.authenticate(token: local, isLocal: false), "useless to another machine even if it leaks")
        XCTAssertNil(registry.authenticate(token: "nope", isLocal: true))

        let paired = try XCTUnwrap(registry.redeem(code: registry.createCode().code, deviceName: "iPhone"))
        XCTAssertNil(registry.devices()[0].lastSeenAt)
        clock += 60
        XCTAssertEqual(registry.authenticate(token: paired.token, isLocal: false), .device(id: paired.device.id))
        XCTAssertEqual(registry.authenticate(token: paired.token, isLocal: true), .device(id: paired.device.id), "a device is never the Mac, wherever it connects from")
        XCTAssertEqual(registry.devices()[0].lastSeenAt, clock)
        XCTAssertNil(registry.authenticate(token: paired.device.id, isLocal: false), "the id is not a credential")
    }

    func testRevokingADeviceEndsItsAccess() throws {
        let registry = registry()
        let one = try XCTUnwrap(registry.redeem(code: registry.createCode().code, deviceName: "one"))
        let two = try XCTUnwrap(registry.redeem(code: registry.createCode().code, deviceName: "two"))
        XCTAssertTrue(registry.revoke(one.device.id))
        XCTAssertFalse(registry.revoke(one.device.id))
        XCTAssertNil(registry.authenticate(token: one.token, isLocal: false))
        XCTAssertEqual(registry.authenticate(token: two.token, isLocal: false), .device(id: two.device.id))
        XCTAssertEqual(registry.devices(connected: [two.device.id]).map(\.isConnected), [true])
    }

    func testDevicesSurviveARestartWithoutTheirTokensOnDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = registry(file: file)
        let code = first.createCode()
        let paired = try XCTUnwrap(first.redeem(code: code.code, deviceName: "iPhone"))

        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.contains(paired.token), "only a hash of the token is stored")
        XCTAssertFalse(saved.contains(code.code))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        let second = registry(file: file)
        XCTAssertEqual(second.devices().map(\.id), [paired.device.id])
        XCTAssertEqual(second.authenticate(token: paired.token, isLocal: false), .device(id: paired.device.id))
        XCTAssertNil(second.redeem(code: code.code, deviceName: "x"), "pairing codes do not survive a restart")
    }
}
