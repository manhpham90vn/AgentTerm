import AgenttyProtocol
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
            .kill(session: 7),
            .pair(code: "c0de", device: "iPhone của Mạnh"),
            .createPairingCode,
            .cancelPairingCode,
            .listDevices,
            .revokeDevice(id: "d-1"),
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
            .welcome(version: agenttyProtocolVersion, host: "Mac"),
            .sessions([info]),
            .agents([AgentInfo(id: "claude", name: "Claude Code", path: "/usr/local/bin/claude"), AgentInfo(id: "agy", name: "Antigravity", path: nil)]),
            .folders(["/Users/me/app"]),
            .attached(info),
            .resized(session: 3, size: TermSize(cols: 48, rows: 30), driver: true),
            .exited(session: 3, status: 130),
            .error("nope"),
            .paired(device: "d-1", token: "t0ken"),
            .pairingCode(code: "c0de", expiresAt: Date(timeIntervalSince1970: 1_800_000_300)),
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
        XCTAssertEqual(info.url.scheme, "agentty")
        XCTAssertEqual(PairingInfo(url: info.url), info)
    }

    func testPairingURLRejectsIncompleteLinks() {
        XCTAssertNil(PairingInfo(url: URL(string: "agentty://pair?host=mac&port=7717")!))
        XCTAssertNil(PairingInfo(url: URL(string: "agentty://pair?host=mac&port=7717&token=old-style")!), "links from before pairing codes")
        XCTAssertNil(PairingInfo(url: URL(string: "https://pair?host=mac&port=7717&code=x")!))
        XCTAssertNil(PairingInfo(url: URL(string: "agentty://pair?host=mac&port=99999&code=x")!))
    }

    func testSizeIsClamped() {
        XCTAssertEqual(TermSize(cols: 0, rows: -3).clamped, TermSize(cols: 2, rows: 2))
        XCTAssertEqual(TermSize(cols: 5000, rows: 30).clamped, TermSize(cols: 1000, rows: 30))
    }
}
