import AgentTermProtocol
import XCTest

final class ProtocolTests: XCTestCase {
    func testClientMessagesRoundTrip() {
        let messages: [ClientMessage] = [
            .hello(token: "secret", client: "iPhone"),
            .list,
            .agents(refresh: true),
            .create(CreateRequest(command: "claude", cwd: "/tmp", title: "Claude", size: TermSize(cols: 48, rows: 30))),
            .attach(session: 7, size: TermSize(cols: 120, rows: 40)),
            .detach(session: 7),
            .resize(session: 7, size: TermSize(cols: 50, rows: 20)),
            .takeControl(session: 7, size: TermSize(cols: 50, rows: 20)),
            .kill(session: 7),
            .pair(code: "c0de", device: "iPhone của Mạnh"),
            .createPairingCode,
            .cancelPairingCode,
            .listDevices,
            .revokeDevice(id: "d-1"),
            .diff(path: "/Users/me/app"),
            .diffFile(path: "/Users/me/app", file: "src/a b.swift", staged: true),
            .gitStage(path: "/Users/me/app", files: ["src/a b.swift", "tên.txt"]),
            .gitStage(path: "/Users/me/app", files: []),
            .gitUnstage(path: "/Users/me/app", files: ["src/a b.swift"]),
            .gitCommit(path: "/Users/me/app", message: "feat: thêm dòng\n\nchi tiết"),
            .accountUsage(refresh: true),
            .setTabLayout(TabLayout()),
            .moveFolder(path: "/Users/me/app", before: "/Users/me/web"),
            .moveFolder(path: "/Users/me/app", before: nil),
            .files(path: "/Users/me/app"),
            .readFile(path: "/Users/me/app/ghi chú.md"),
            .writeFile(path: "/Users/me/app/ghi chú.md", text: "# Tiêu đề\n"),
            .createFile(directory: "/Users/me/app", name: "mới.txt", isDirectory: false),
            .renameFile(path: "/Users/me/app/a.txt", name: "b.txt"),
            .trashFile(path: "/Users/me/app/b.txt"),
            .history(path: nil),
            .history(path: "/Users/me/app"),
            .resume(agent: "codex", sessionID: "id-1", cwd: "/Users/me/app", size: .default),
            .handoffPlan(agent: "claude"),
            .handoff(agent: "claude", sessionID: "id-1", cwd: "/Users/me/app", target: "codex", plan: "p-1", prompt: "Đọc file rồi làm tiếp", note: "chỉ viết test", size: .default, folder: "/Users/me/other"),
            .handoff(agent: "claude", sessionID: "id-1", cwd: "/Users/me/app", target: "codex", plan: nil, prompt: nil, note: "", size: .default, folder: nil),
            .listDirectory(path: nil),
            .addFolder(path: "/Users/me/dự án"),
            .removeFolder(path: "/Users/me/dự án"),
        ]
        for message in messages {
            let decoded = MessageCoding.decode(ClientMessage.self, from: MessageCoding.encode(message))
            XCTAssertEqual(decoded, message)
        }
    }

    func testServerMessagesRoundTrip() {
        let info = SessionInfo(id: 3, title: "zsh", cwd: "/Users/me", size: .default, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let messages: [ServerMessage] = [
            .welcome(version: agenttermProtocolVersion, host: "Mac"),
            .sessions([info]),
            .agents([AgentInfo(id: "claude", name: "Claude Code", path: "/usr/local/bin/claude"), AgentInfo(id: "agy", name: "Antigravity", path: nil)]),
            .folders(["/Users/me/app"]),
            .attached(info),
            .resized(session: 3, size: TermSize(cols: 48, rows: 30), driver: true),
            .exited(session: 3, status: 130),
            .error("nope"),
            .paired(device: "d-1", token: "t0ken"),
            .pairingCode(code: "c0de", expiresAt: Date(timeIntervalSince1970: 1_800_000_300)),
            .diff(path: "/Users/me/app", snapshot: DiffSnapshot(isRepository: true, branch: "main", files: [FileDiff(path: "a.txt", added: 1, deleted: 2, isUntracked: false, patch: "")])),
            .diffFile(path: "/Users/me/app", file: nil),
            .files(path: "/Users/me/app", entries: [FileEntry(path: "/Users/me/app/src", name: "src", isDirectory: true)]),
            .file(path: "/Users/me/app/a.png", content: .image, data: Data([0x89, 0x50, 0x4e, 0x47])),
            .file(path: "/Users/me/app/a.txt", content: .text("xin chào"), data: nil),
            .file(path: "/Users/me/app/big.bin", content: .tooLarge(bytes: 3_000_000), data: nil),
            .fileSaved(path: "/Users/me/app/a.txt"),
            .replayed(session: 7),
            .accountUsage([AccountUsage(
                agent: "claude", plan: "Max 5x", showsRemaining: false,
                groups: [AccountUsageGroup(title: nil, note: "ghi chú", limits: [AccountLimit(id: "session-0", title: "Current session", shortTitle: "Session", usedPercent: 55, resetsAt: Date(timeIntervalSince1970: 1_794_397_800), detail: nil)])],
                notes: [AccountUsageNote(label: "Extra usage", value: "Off")], fetchedAt: Date(timeIntervalSince1970: 1_794_380_000), problem: nil
            )]),
            .fileCreated(path: "/Users/me/app/mới.txt", isDirectory: false),
            .history(path: nil, conversations: [Conversation(agent: "agy", sessionID: "c-1", title: "Rà soát", updatedAt: Date(timeIntervalSince1970: 1_800_000_000), cwd: "/Users/me/app")]),
            .handoffPlan(id: "p-1", prompt: "You are taking over…"),
            .directory(DirectoryListing(path: "/Users/me", parent: "/Users", folders: ["Dev", "Tài liệu"], isHome: true)),
            .devices([DeviceInfo(id: "d-1", name: "iPhone", pairedAt: Date(timeIntervalSince1970: 1_800_000_000), lastSeenAt: nil, isConnected: true)]),
        ]
        for message in messages {
            let decoded = MessageCoding.decode(ServerMessage.self, from: MessageCoding.encode(message))
            XCTAssertEqual(decoded, message)
        }
    }

    func testDataFrameRoundTrip() {
        let payload = Data("xin chào tiếng Việt ạ".utf8)
        let frame = DataFrame(kind: .input, session: 0x0102_0304, payload: payload)
        let encoded = frame.encoded()
        XCTAssertEqual([UInt8](encoded.prefix(5)), [1, 1, 2, 3, 4])
        XCTAssertEqual(DataFrame(decoding: encoded), frame)
    }

    func testDataFrameDecodesFromASlice() {
        let encoded = Data([0xff, 0xff]) + DataFrame(kind: .output, session: 9, payload: Data([1, 2, 3])).encoded()
        let frame = DataFrame(decoding: encoded.dropFirst(2))
        XCTAssertEqual(frame?.session, 9)
        XCTAssertEqual(frame?.payload, Data([1, 2, 3]))
        XCTAssertEqual(frame?.payload.startIndex, 0)
    }

    func testDataFrameRejectsGarbage() {
        XCTAssertNil(DataFrame(decoding: Data([0, 0, 0])))
        XCTAssertNil(DataFrame(decoding: Data([9, 0, 0, 0, 1])))
    }

    func testPairingURLRoundTrip() {
        let info = PairingInfo(host: "macbook.tail1234.ts.net", port: 7717, code: "abc-_123", name: "Mạnh's MacBook")
        XCTAssertEqual(info.url.scheme, "agentterm-dev", "the test runner is a development build")
        // Links of the released app are understood too.
        XCTAssertEqual(PairingInfo(url: URL(string: "agentterm://pair?host=mac&port=7717&code=c0de&name=Mac")!)?.code, "c0de")
        XCTAssertNil(PairingInfo(url: URL(string: "https://pair?host=mac&port=7717&code=c0de")!))
        XCTAssertEqual(AppChannel.current, .dev)
        XCTAssertEqual([AppChannel.release.defaultPort, AppChannel.dev.defaultPort], [7717, 7718])
        XCTAssertEqual([AppChannel.release.appName, AppChannel.dev.appName], ["AgentTerm", "AgentTerm Dev"])
        XCTAssertEqual(PairingInfo(url: info.url), info)
    }

    func testPairingURLRejectsIncompleteLinks() {
        XCTAssertNil(PairingInfo(url: URL(string: "agentterm://pair?host=mac&port=7717")!))
        XCTAssertNil(PairingInfo(url: URL(string: "agentterm://pair?host=mac&port=7717&token=old-style")!), "links from before pairing codes")
        XCTAssertNil(PairingInfo(url: URL(string: "https://pair?host=mac&port=7717&code=x")!))
        XCTAssertNil(PairingInfo(url: URL(string: "agentterm://pair?host=mac&port=99999&code=x")!))
    }

    func testSizeIsClamped() {
        XCTAssertEqual(TermSize(cols: 0, rows: -3).clamped, TermSize(cols: 2, rows: 2))
        XCTAssertEqual(TermSize(cols: 5000, rows: 30).clamped, TermSize(cols: 1000, rows: 30))
    }
}
