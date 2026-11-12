import AgentTermProtocol
import XCTest

@testable import AgentTermHost

final class SystemSamplerTests: XCTestCase {
    func testTheMacItselfIsMeasured() throws {
        let sampler = SystemSampler()
        let first = sampler.sample()
        XCTAssertEqual(first.cpuPercent, 0, "nothing to compare with yet")
        XCTAssertEqual(first.downBytesPerSecond, 0)

        // Keep a core busy between the two samples.
        let busy = Process()
        busy.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        busy.standardOutput = FileHandle.nullDevice
        try busy.run()
        defer { busy.terminate() }
        Thread.sleep(forTimeInterval: 1)
        let second = sampler.sample()

        XCTAssertGreaterThan(second.cpuPercent, 0)
        XCTAssertLessThanOrEqual(second.cpuPercent, 100)
        XCTAssertGreaterThan(second.memoryTotal, 1_073_741_824)
        XCTAssertGreaterThan(second.memoryUsed, 0)
        XCTAssertLessThanOrEqual(second.memoryUsed, second.memoryTotal)
        XCTAssertTrue(["nominal", "fair", "serious", "critical"].contains(second.thermalState))
        if let temperature = second.temperature { XCTAssertTrue((1..<130).contains(temperature), "\(temperature)") }
        if let battery = second.batteryPercent { XCTAssertTrue((0...100).contains(battery)) }
        // Started in the past, and not before computers of this kind existed.
        XCTAssertLessThan(second.bootedAt, Date())
        XCTAssertGreaterThan(second.bootedAt, Date(timeIntervalSince1970: 1_500_000_000))
    }
}
