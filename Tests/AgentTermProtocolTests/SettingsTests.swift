import AgentTermProtocol
import XCTest

/// What 0.4.0 added to the protocol, and that what an older host sends still reads.
final class SettingsTests: XCTestCase {
    func testTheNewMessagesRoundTrip() {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        let client: [ClientMessage] = [
            .gitPush(path: "/Users/me/app"),
            .gitPull(path: "/Users/me/app"),
            .setStartAtLogin(true),
            .attach(session: 3, size: TermSize(cols: 48, rows: 30), have: 123_456_789_012),
            .writeCommitMessage(path: "/Users/me/app"),
            .cancelCommitMessage(path: "/Users/me/app"),
            .setCommitWriter(CommitWriterSettings(agent: "codex", model: "gpt-x", prompt: "Viết bằng tiếng Việt.")),
            .setCommitWriter(CommitWriterSettings()),
            .setKeepAwakeOptions(KeepAwakeOptions(display: true, onlyOnPower: true, minutes: 120, until: until)),
            .sshHosts,
            .connectSSH(host: "build-server", size: TermSize(cols: 48, rows: 30)),
        ]
        for message in client {
            XCTAssertEqual(MessageCoding.decode(ClientMessage.self, from: MessageCoding.encode(message)), message)
        }
        let server: [ServerMessage] = [
            .keepAwakeOptions(KeepAwakeOptions(display: true, minutes: 60, until: until)),
            .commitWriter(CommitWriterSettings(agent: "claude")),
            .commitMessage(path: "/Users/me/app", message: "feat: thêm dòng\n\nchi tiết"),
            .commitMessage(path: "/Users/me/app", message: nil),
            .sshHosts(["build-server", "web-1"]),
            .gitSynced(path: "/Users/me/app"),
            .startAtLogin(true),
            .replaying(session: 3, from: 123_456_789_012),
            .diff(
                path: "/Users/me/app",
                snapshot: DiffSnapshot(isRepository: true, branch: "main", files: [], upstream: "origin/main", ahead: 2, behind: 1)),
        ]
        for message in server {
            XCTAssertEqual(MessageCoding.decode(ServerMessage.self, from: MessageCoding.encode(message)), message)
        }
    }

    func testAnAttachWithoutAPlaceStillReads() throws {
        // As every client wrote it before a terminal could say where it is.
        let old = #"{"attach":{"session":7,"size":{"cols":120,"rows":40}}}"#
        XCTAssertEqual(MessageCoding.decode(ClientMessage.self, from: Data(old.utf8)), .attach(session: 7, size: TermSize(cols: 120, rows: 40)))
    }

    func testWhatAnOlderHostSendsStillReads() throws {
        // A folder's changes as 0.3 wrote them: without what 0.4 added.
        let changes = #"{"isRepository":true,"branch":"main","files":[]}"#
        let snapshot = try XCTUnwrap(MessageCoding.decode(DiffSnapshot.self, from: Data(changes.utf8)))
        XCTAssertNil(snapshot.upstream)
        XCTAssertFalse(snapshot.canPush)
        XCTAssertFalse(snapshot.canPull)
    }

    func testWhereABranchCanGo() {
        func snapshot(branch: String? = "main", upstream: String? = nil, pushRemote: String? = nil) -> DiffSnapshot {
            DiffSnapshot(isRepository: true, branch: branch, files: [], upstream: upstream, pushRemote: pushRemote)
        }
        XCTAssertTrue(snapshot(upstream: "origin/main").canPush && snapshot(upstream: "origin/main").canPull)
        XCTAssertTrue(snapshot(pushRemote: "origin").canPush, "a first push has somewhere to go")
        XCTAssertFalse(snapshot(pushRemote: "origin").canPull, "there is nothing to pull from yet")
        XCTAssertFalse(snapshot().canPush, "no remote at all")
        XCTAssertFalse(snapshot(branch: nil, upstream: "origin/main").canPush, "a detached HEAD is not a branch")
    }

    func testTheMacsOwnFiguresAreSaidShortly() {
        let stats = SystemStats(memoryUsed: 13_314_398_618, memoryTotal: 34_359_738_368, temperature: 54.4, bootedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(stats.memoryText, "12.4 / 32 GB")
        XCTAssertEqual(stats.memoryPercent, 38.75, accuracy: 0.1)
        XCTAssertEqual(stats.temperatureText, "54°C")
        XCTAssertEqual(stats.temperatureText(unit: SystemStats.fahrenheit), "130°F")
        XCTAssertEqual(stats.temperatureText(unit: SystemStats.celsius), "54°C")
        XCTAssertEqual(SystemStats(thermalState: "fair").temperatureText(unit: SystemStats.fahrenheit), "Warm", "words have no unit")
        XCTAssertFalse(stats.isHot)
        // Without a sensor, what macOS says about the Mac's heat.
        XCTAssertEqual(SystemStats(thermalState: "nominal").temperatureText, "Normal")
        XCTAssertEqual(SystemStats(thermalState: "serious").temperatureText, "Hot")
        XCTAssertTrue(SystemStats(thermalState: "serious").isHot)
        XCTAssertTrue(SystemStats(temperature: 99).isHot)
        XCTAssertEqual(SystemStats.speed(0), "0 KB/s")
        XCTAssertEqual(SystemStats.speed(860_160), "840 KB/s")
        XCTAssertEqual(SystemStats.speed(12_897_484), "12.3 MB/s")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SystemStats.uptime(since: start, now: start.addingTimeInterval(8 * 60 + 30)), "8m")
        XCTAssertEqual(SystemStats.uptime(since: start, now: start.addingTimeInterval(5 * 3600 + 12 * 60)), "5h 12m")
        XCTAssertEqual(SystemStats.uptime(since: start, now: start.addingTimeInterval(3 * 86400 + 4 * 3600 + 59)), "3d 4h")
        let message = ServerMessage.systemStats(SystemStats(cpuPercent: 12, batteryPercent: 80, isCharging: true, bootedAt: start))
        XCTAssertEqual(MessageCoding.decode(ServerMessage.self, from: MessageCoding.encode(message)), message)
    }

    func testCommitWriterDefaults() {
        XCTAssertEqual(CommitWriterSettings().effectivePrompt, CommitWriterSettings.defaultPrompt)
        XCTAssertEqual(CommitWriterSettings(prompt: "  \n ").effectivePrompt, CommitWriterSettings.defaultPrompt)
        XCTAssertEqual(CommitWriterSettings(prompt: " Ngắn gọn. ").effectivePrompt, "Ngắn gọn.")
        XCTAssertTrue(CommitWriterSettings.defaultPrompt.contains("Conventional Commits"))
        XCTAssertEqual(CommitWriterSettings.defaultModel(for: "claude"), "haiku")
        XCTAssertNil(CommitWriterSettings.defaultModel(for: "codex"))
    }

    func testKeepAwakeLengthsAreNamed() {
        XCTAssertEqual(KeepAwakeOptions.label(minutes: nil), "Until turned off")
        XCTAssertEqual(KeepAwakeOptions.label(minutes: 60), "1 hour")
        XCTAssertEqual(KeepAwakeOptions.label(minutes: 240), "4 hours")
        XCTAssertEqual(KeepAwakeOptions.label(minutes: 45), "45 minutes")
        // Options an older app saved read with the rest left as it was.
        XCTAssertEqual(MessageCoding.decode(KeepAwakeOptions.self, from: Data(#"{"display":true,"onlyOnPower":false}"#.utf8)), KeepAwakeOptions(display: true))
    }
}
