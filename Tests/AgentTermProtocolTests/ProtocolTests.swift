import AgentTermProtocol
import XCTest

final class ProtocolTests: XCTestCase {
    func testAHostOfAnotherVersionIsToldApart() {
        XCTAssertEqual(ProtocolMatch(host: agenttermProtocolVersion), .same)
        XCTAssertEqual(ProtocolMatch(host: agenttermProtocolVersion - 1), .hostOlder)
        XCTAssertEqual(ProtocolMatch(host: agenttermProtocolVersion + 1), .hostNewer)
    }

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
            .gitDiscard(path: "/Users/me/app", files: ["src/a b.swift"]),
            .gitDiscard(path: "/Users/me/app", files: []),
            .gitFetch(path: "/Users/me/app", automatic: true),
            .gitPull(path: "/Users/me/app", mode: "rebase"),
            .gitPush(path: "/Users/me/app", force: true),
            .gitForcePushPreview(path: "/Users/me/app"),
            .gitBranches(path: "/Users/me/app"),
            .gitSwitch(path: "/Users/me/app", branch: "origin/feature/login"),
            .gitCreateBranch(path: "/Users/me/app", name: "feature/x", from: nil, checkout: true),
            .gitRenameBranch(path: "/Users/me/app", from: "a", to: "b"),
            .gitDeleteBranch(path: "/Users/me/app", name: "old", force: false),
            .gitUnstage(path: "/Users/me/app", files: ["src/a b.swift"]),
            .gitCommit(path: "/Users/me/app", message: "feat: thêm dòng\n\nchi tiết"),
            .accountUsage(refresh: true),
            .setTabLayout(TabLayout()),
            .setKeepAwake(true),
            .moveFolder(path: "/Users/me/app", before: "/Users/me/web"),
            .moveFolder(path: "/Users/me/app", before: nil),
            .files(path: "/Users/me/app"),
            .readFile(path: "/Users/me/app/ghi chú.md"),
            .readFile(path: "/Users/me/app/five.log", anyway: true),
            .writeFile(path: "/Users/me/app/ghi chú.md", text: "# Tiêu đề\n"),
            .createFile(directory: "/Users/me/app", name: "mới.txt", isDirectory: false),
            .renameFile(path: "/Users/me/app/a.txt", name: "b.txt"),
            .trashFile(path: "/Users/me/app/b.txt"),
            .history(path: nil),
            .history(path: "/Users/me/app"),
            .resume(agent: "codex", sessionID: "id-1", cwd: "/Users/me/app", size: .default),
            .handoffPlan(agent: "claude"),
            .handoff(
                agent: "claude", sessionID: "id-1", cwd: "/Users/me/app", target: "codex", plan: "p-1", prompt: "Đọc file rồi làm tiếp", note: "chỉ viết test", size: .default,
                folder: "/Users/me/other"),
            .handoff(agent: "claude", sessionID: "id-1", cwd: "/Users/me/app", target: "codex", plan: nil, prompt: nil, note: "", size: .default, folder: nil),
            .listDirectory(path: nil),
            .addFolder(path: "/Users/me/dự án"),
            .removeFolder(path: "/Users/me/dự án"),
            .dismissFailure(id: "f-1"),
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
            .accountUsage([
                AccountUsage(
                    agent: "claude", plan: "Max 5x", showsRemaining: false,
                    groups: [
                        AccountUsageGroup(
                            title: nil, note: "ghi chú",
                            limits: [AccountLimit(id: "session-0", title: "Current session", shortTitle: "Session", usedPercent: 55, resetsAt: Date(timeIntervalSince1970: 1_794_397_800), detail: nil)]
                        )
                    ],
                    notes: [AccountUsageNote(label: "Extra usage", value: "Off")], fetchedAt: Date(timeIntervalSince1970: 1_794_380_000), problem: nil
                )
            ]),
            .fileCreated(path: "/Users/me/app/mới.txt", isDirectory: false),
            .history(path: nil, conversations: [Conversation(agent: "agy", sessionID: "c-1", title: "Rà soát", updatedAt: Date(timeIntervalSince1970: 1_800_000_000), cwd: "/Users/me/app")]),
            .handoffPlan(id: "p-1", prompt: "You are taking over…"),
            .directory(DirectoryListing(path: "/Users/me", parent: "/Users", folders: ["Dev", "Tài liệu"], isHome: true)),
            .devices([DeviceInfo(id: "d-1", name: "iPhone", pairedAt: Date(timeIntervalSince1970: 1_800_000_000), lastSeenAt: nil, isConnected: true)]),
            .failures([]),
            .failures([
                PartFailure(
                    id: "f-1", part: .host, at: Date(timeIntervalSince1970: 1_800_000_000),
                    ended: [EndedSession(name: "Sửa lỗi đăng nhập", cwd: "/Users/me/app", agent: "claude"), EndedSession(name: "zsh", cwd: "/Users/me")], restarted: true),
                PartFailure(
                    id: "f-2", part: PartFailure.Part(rawValue: "statusLineRelay"), at: Date(timeIntervalSince1970: 1_800_000_060), restarted: false, broken: true,
                    reason: "It stopped three times in a minute."),
            ]),
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

    /// A part added to the protocol later still reads, by its name.
    func testAFailureOfAPartNotKnownYetStillReads() {
        let json = #"{"failures":{"_0":[{"id":"f","part":"sessionProgram","name":"build","at":1800000000,"ended":[],"restarted":false,"broken":false}]}}"#
        guard case .failures(let list)? = MessageCoding.decode(ServerMessage.self, from: Data(json.utf8)) else { return XCTFail("did not decode") }
        XCTAssertEqual(list.first?.part.rawValue, "sessionProgram")
        XCTAssertEqual(list.first?.name, "build")
    }

    /// HOST-3, HOST-8: what both apps say of a host that died.
    func testAFailureInWords() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var failure = PartFailure(part: .host, at: at, ended: [EndedSession(name: "build", cwd: "/p"), EndedSession(name: "tests", cwd: "/p")], restarted: true)
        let headline = failure.headline(on: "First Mac", now: at)
        XCTAssertTrue(headline.hasPrefix("The host on First Mac stopped unexpectedly at "), headline)
        XCTAssertTrue(headline.hasSuffix(" and was started again."), headline)
        XCTAssertTrue(failure.headline(now: at).hasPrefix("The AgentTerm host stopped unexpectedly"))
        XCTAssertEqual(failure.details, "Its 2 sessions ended: build, tests.")
        failure.ended = [EndedSession(name: "build", cwd: "/p")]
        XCTAssertEqual(failure.details, "Its session ended: build.")
        failure.ended = []
        failure.reason = "It was killed."
        XCTAssertEqual(failure.details, "No session was running in it. It was killed.")
        failure.restarted = false
        failure.broken = true
        XCTAssertTrue(failure.headline(now: at).hasSuffix("and keeps stopping, so it is not started again by itself."))
        // Another day says which.
        XCTAssertTrue(failure.headline(now: at.addingTimeInterval(3 * 86400)).contains("stopped unexpectedly on "))
    }

    /// SES-23, AWAKE-4, USE-5: the other parts, in words.
    func testTheOtherPartsInWords() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let killed = PartFailure(
            part: .session, name: "build", at: at, ended: [EndedSession(name: "build", cwd: "/p")], restarted: false, reason: "It was killed (SIGKILL).")
        XCTAssertTrue(killed.headline(on: "First Mac", now: at).hasPrefix("The program of “build” on First Mac stopped unexpectedly at "))
        XCTAssertEqual(killed.details, "Its session ended. It was killed (SIGKILL).")

        var awake = PartFailure(part: .keepAwake, at: at, restarted: false, reason: "macOS would not hold it.")
        XCTAssertTrue(awake.headline(now: at).hasPrefix("The Mac could not be kept awake at "))
        XCTAssertTrue(awake.headline(now: at).hasSuffix("."))
        XCTAssertEqual(awake.details, "macOS would not hold it.", "nothing ends with the hold")
        awake.restarted = true
        XCTAssertTrue(awake.headline(now: at).hasSuffix(", and is kept awake again."))

        let usage = PartFailure(part: .statusLine, name: "review", at: at, restarted: false)
        XCTAssertTrue(usage.headline(now: at).hasPrefix("The usage of “review” could not be saved at "))
        XCTAssertEqual(usage.details, "")
    }

    /// NOTE-1: an agent that is done or waits is told once; one that asks
    /// something else is told again; one that keeps waiting, or works, is not.
    func testWhatIsToldOfTheAgents() {
        func session(_ id: SessionID, _ state: AgentState?) -> SessionInfo {
            SessionInfo(id: id, title: "s\(id)", cwd: "/p", size: .default, createdAt: Date(), state: state)
        }
        let permission = AgentState.waitingForPermission(AgentQuestion(text: "make test"))
        let done = AgentState.done(said: "All tests pass.")
        var told: [SessionID: AgentState] = [:]
        // On connecting: what waits or is done, at once.
        XCTAssertEqual(AgentNotice.notices(in: [session(1, permission), session(2, .working(since: Date())), session(3, nil)], told: &told).map(\.session), [1])
        XCTAssertEqual(AgentNotice.notices(in: [session(1, permission)], told: &told), [], "keeps waiting: told once")
        XCTAssertEqual(AgentNotice.notices(in: [session(1, .working(since: Date()))], told: &told), [])
        let again = AgentNotice.notices(in: [session(1, done)], told: &told)
        XCTAssertEqual(again.map(\.why), ["is done"])
        XCTAssertEqual(again.first?.detail, "All tests pass.")
        XCTAssertTrue(again.first?.takesAReply == true)
        // Asked something else, told again.
        let question = AgentState.waitingForAnswer(AgentQuestion(text: "Which colour?", choices: ["Red", "Blue"]))
        XCTAssertEqual(AgentNotice.notices(in: [session(1, question)], told: &told).first?.detail, "Which colour?\nRed · Blue")
        XCTAssertFalse(AgentNotice(session: 1, name: "", folder: "", state: permission).takesAReply, "a permission is answered in the session")
        // Ended: forgotten.
        _ = AgentNotice.notices(in: [], told: &told)
        XCTAssertTrue(told.isEmpty)
    }

    /// NOTE-8 (#55): a notification's body is the question alone, and each
    /// choice is a button of its own, so that iOS, which shows a few lines,
    /// does not cut the choices off after a long question.
    func testAQuestionsChoicesAreButtonsOfItsNotification() {
        let asked = AgentQuestion(text: "Which colour?", choices: ["Red", "Blue"])
        let question = AgentNotice(session: 1, name: "s", folder: "/p", state: .waitingForAnswer(asked))
        XCTAssertEqual(question.words, "Which colour?", "the choices are not in the body")
        XCTAssertEqual(question.buttons.map(\.title), ["Red", "Blue"])
        XCTAssertEqual(question.buttons.map { question.choice(ofButton: $0.id) }, ["Red", "Blue"])
        XCTAssertNil(question.choice(ofButton: "choice-2"), "not one of its choices")
        XCTAssertNil(question.choice(ofButton: "reply"))

        // More choices than a notification has room for: the first ones,
        // the text reply taking the place that is left.
        let many = AgentNotice(session: 1, name: "s", folder: "/p", state: .waitingForAnswer(AgentQuestion(text: "?", choices: (1...20).map(String.init))))
        XCTAssertEqual(many.buttons.count, AgentNotice.mostButtons)
        XCTAssertEqual(many.buttons.last?.title, String(AgentNotice.mostButtons))

        // Only a question has them.
        let done = AgentNotice(session: 1, name: "s", folder: "/p", state: .done(said: "All tests pass."))
        XCTAssertEqual(done.words, "All tests pass.")
        XCTAssertTrue(done.buttons.isEmpty)
        let permission = AgentNotice(session: 1, name: "s", folder: "/p", state: .waitingForPermission(AgentQuestion(text: "make test", choices: ["Yes"])))
        XCTAssertEqual(permission.words, "make test")
        XCTAssertTrue(permission.buttons.isEmpty, "a permission is answered in the session")
        XCTAssertNil(permission.choice(ofButton: "choice-0"))
    }

    /// LIVE-1: the Live Activity shows only while the phone is connected, no
    /// one is at the Mac, and an agent works or waits; it ends at once when
    /// the connection ends or the Mac is used, and shows "done" at the end.
    func testWhenTheLiveActivityShows() {
        func session(_ state: AgentState?) -> SessionInfo { SessionInfo(id: 1, title: "s", cwd: "/p", size: .default, createdAt: Date(), state: state) }
        let working = [session(.working(since: Date()))]
        let waiting = [session(.waitingForAnswer(AgentQuestion(text: "?")))]
        XCTAssertEqual(LiveActivityRule.decide(enabled: true, connected: true, macInUse: false, sessions: working), .show)
        XCTAssertEqual(LiveActivityRule.decide(enabled: true, connected: true, macInUse: false, sessions: waiting), .show)
        XCTAssertEqual(LiveActivityRule.decide(enabled: true, connected: true, macInUse: true, sessions: working), .endNow, "someone is at the Mac")
        XCTAssertEqual(LiveActivityRule.decide(enabled: true, connected: false, macInUse: false, sessions: working), .endNow, "no connection to keep it true")
        XCTAssertEqual(LiveActivityRule.decide(enabled: false, connected: true, macInUse: false, sessions: working), .endNow, "switched off")
        XCTAssertEqual(LiveActivityRule.decide(enabled: true, connected: true, macInUse: false, sessions: [session(.done(said: nil)), session(nil)]), .endShowingDone)
    }

    /// PERF-1: a message larger than a frame may be is sent in pieces, none
    /// larger than 256 KB, and joined whole; one that fits is not split.
    func testALargeMessageIsSentInPiecesAndJoined() throws {
        XCTAssertNil(MessageParts.frames(for: Data(count: 1000), id: 1))
        let message = Data((0..<(1_000_000)).map { UInt8($0 % 251) })
        let frames = try XCTUnwrap(MessageParts.frames(for: message, id: 7))
        XCTAssertEqual(frames.count, 4)
        XCTAssertTrue(frames.allSatisfy { $0.encoded().count <= MessageParts.limit })
        XCTAssertEqual(frames.map(\.kind), [.messagePart, .messagePart, .messagePart, .messageEnd])
        var joiner = MessageParts.Joiner()
        var whole: Data?
        for frame in frames { whole = joiner.add(DataFrame(decoding: frame.encoded())!) ?? whole }
        XCTAssertEqual(whole, message)
        // Pieces of a message that never ended are not taken for the next.
        _ = joiner.add(frames[0])
        let other = try XCTUnwrap(MessageParts.frames(for: Data(repeating: 1, count: 300_000), id: 8))
        var second: Data?
        for frame in other { second = joiner.add(frame) ?? second }
        XCTAssertEqual(second, Data(repeating: 1, count: 300_000))
    }

    /// MCP-19: what keeps the agents from opening shells, in words, and a
    /// cause this build does not know still read.
    func testAnAgentShellsFaultInWords() throws {
        let install = AgentShellsFault(cause: .install, agents: ["Codex", "Copilot CLI"])
        XCTAssertEqual(install.headline(), "AgentTerm's shells could not be set up in Codex and Copilot CLI.")
        XCTAssertEqual(install.headline(on: "Studio"), "AgentTerm's shells could not be set up in Codex and Copilot CLI on Studio.")
        XCTAssertEqual(AgentShellsFault(cause: .signIn).headline(), "An agent's MCP server was refused by the AgentTerm host.")
        XCTAssertTrue(AgentShellsFault(cause: .signIn).advice.contains("Start that agent's session again"))
        let message = ServerMessage.agentShellsFaults([install, AgentShellsFault(cause: .init(rawValue: "later"))])
        let back = try XCTUnwrap(MessageCoding.decode(ServerMessage.self, from: MessageCoding.encode(message)))
        XCTAssertEqual(back, message)
        XCTAssertEqual(AgentShellsFault(cause: .init(rawValue: "later")).headline(), "Agents cannot open shells you see (later).")
    }

    /// WT-12 (#56): a worktree's row is short: the name of its folder
    /// stands for its path.
    func testAWorktreesRowNamesItsFolderNotItsPath() {
        let own = WorktreeInfo(path: "/Users/someone/code/project", branch: "main", isMain: true, changed: 1)
        XCTAssertEqual(own.menuTitle, "project · main")
        XCTAssertEqual(own.menuDetail, "1 changed")
        let made = WorktreeInfo(path: "/Users/someone/code/project/.agentterm/worktrees/agentterm/claude-1", branch: "agentterm/claude-1", isMain: false, ahead: 2, inUse: true, isAgentTerm: true)
        XCTAssertEqual(made.menuDetail, "2 ahead, in use")
        let elsewhere = WorktreeInfo(
            path: "/Users/someone/a/long/path/to/the/worktrees/of/project/review-copy", branch: "feature/login", isMain: false, ahead: 2, changed: 3, inUse: true)
        XCTAssertEqual(elsewhere.menuTitle, "feature/login")
        XCTAssertEqual(elsewhere.menuDetail, "2 ahead, 3 changed, in review-copy, in use")
        XCTAssertFalse(elsewhere.menuDetail.contains("/"), "no path in the row")
        // A folder named as its branch is not said twice.
        XCTAssertEqual(WorktreeInfo(path: "/Users/someone/wt/hotfix", branch: "hotfix", isMain: false).menuDetail, "")
        XCTAssertEqual(WorktreeInfo(path: "/gone", branch: "old", isMain: false, missing: true).menuDetail, "missing: its folder is gone")
    }

    /// NOTE-13 (#62): what an agent said at the end is told by its end,
    /// and all of it is there for where it can be read.
    func testAllOfWhatAnAgentSaidCanBeHad() {
        let long = "First I looked at the tests. " + String(repeating: "Then more was done. ", count: 40) + "All 290 tests pass."
        let done = AgentNotice(session: 1, name: "fix", folder: "/p", state: .done(said: long))
        XCTAssertEqual(done.detail?.count, AgentNotice.detailLength)
        XCTAssertTrue(done.detail?.hasSuffix("All 290 tests pass.") == true)
        XCTAssertEqual(done.full, long)
        XCTAssertTrue(done.detailIsCut)
        let short = AgentNotice(session: 1, name: "fix", folder: "/p", state: .done(said: "Done."))
        XCTAssertEqual(short.full, "Done.")
        XCTAssertFalse(short.detailIsCut)
        XCTAssertFalse(AgentNotice(session: 1, name: "fix", folder: "/p", state: .done(said: nil)).detailIsCut)
        let asked = AgentNotice(session: 1, name: "fix", folder: "/p", state: .waitingForAnswer(AgentQuestion(text: "Which one?", choices: ["A", "B"])))
        XCTAssertEqual(asked.full, "Which one?\nA · B")
        XCTAssertFalse(asked.detailIsCut)
    }

    /// GIT-21 (#39): what is asked before changes are discarded, the same
    /// on the Mac and the iPhone.
    func testWhatIsAskedBeforeDiscarding() {
        let changed = FileDiff(path: "src/notes.txt", added: 1, deleted: 0, isUntracked: false, patch: "")
        let new = FileDiff(path: "docs/new guide.md", added: 3, deleted: 0, isUntracked: true, patch: "")
        let one = DiscardQuestion(files: [changed])
        XCTAssertEqual(one.title, "Discard the changes to notes.txt?")
        XCTAssertTrue(one.message.contains("cannot be undone"))
        XCTAssertEqual(one.confirm, "Discard Changes")
        let trashed = DiscardQuestion(files: [new])
        XCTAssertEqual(trashed.title, "Move new guide.md to the Trash?")
        XCTAssertTrue(trashed.message.contains("put back from the Trash"))
        XCTAssertEqual(trashed.confirm, "Move to Trash")
        let all = DiscardQuestion(files: [changed, changed, new])
        XCTAssertEqual(all.title, "Discard all 3 changes?")
        XCTAssertEqual(
            all.message, "2 files go back to what is staged or to the last commit, which cannot be undone. 1 new file is moved to the Trash of the Mac.")
        XCTAssertEqual(all.confirm, "Discard All")
        XCTAssertEqual(DiscardQuestion(files: [new, new]).message, "2 new files are moved to the Trash of the Mac.")
        XCTAssertEqual(changed.discardLabel, "Discard changes to notes.txt")
        XCTAssertEqual(new.discardLabel, "Move new guide.md to the Trash")
    }

    /// GIT-27 (#35): a branch in words, and what is asked before one is
    /// deleted: once when nothing is lost, twice when its commits would be.
    func testABranchInWordsAndWhatIsAskedBeforeDeletingOne() throws {
        let merged = BranchInfo(name: "spare", isMerged: true)
        let own = BranchInfo(name: "feature/x", upstream: "origin/feature/x", ahead: 2, behind: 1)
        XCTAssertEqual(own.tracking, "2 ahead, 1 behind")
        XCTAssertEqual(BranchInfo(name: "old", upstream: "origin/old", upstreamGone: true).tracking, "its remote branch is gone")
        XCTAssertEqual(merged.tracking, "")
        XCTAssertEqual(BranchInfo(name: "origin/feature/login", isRemote: true).localName, "feature/login")
        XCTAssertEqual(own.localName, "feature/x")
        XCTAssertNotEqual(BranchInfo(name: "x").id, BranchInfo(name: "x", isRemote: true).id)

        let once = DeleteBranchQuestion(branch: merged, into: "main")
        XCTAssertEqual(once.title, "Delete the branch “spare”?")
        XCTAssertEqual(once.message, "Everything on it is on “main” too, so nothing is lost.")
        XCTAssertEqual(once.confirm, "Delete Branch")
        let first = DeleteBranchQuestion(branch: own, into: "main")
        XCTAssertTrue(first.message.contains("asked once more"))
        XCTAssertEqual(first.confirm, "Delete…")
        let second = DeleteBranchQuestion(branch: own, into: "main", again: true)
        XCTAssertEqual(second.title, "Delete “feature/x” and lose its commits?")
        XCTAssertEqual(second.confirm, "Delete and Lose Its Commits")

        let message = ServerMessage.gitBranches(path: "/p", branches: [merged, own])
        XCTAssertEqual(try XCTUnwrap(MessageCoding.decode(ServerMessage.self, from: MessageCoding.encode(message))), message)
    }

    /// GIT-33 (#37): what is asked before a push is forced, and the setting
    /// that fetches by itself, on unless turned off.
    func testWhatIsAskedBeforeAForcedPush() throws {
        let one = ForcePushQuestion(branch: "main", upstream: "origin/main", loses: ["abc1234 theirs: a line"])
        XCTAssertEqual(one.title, "Force push “main” to origin/main?")
        XCTAssertTrue(one.message.hasPrefix("This commit on origin/main is not in “main” and will be gone from it there:\n\n• abc1234 theirs: a line"), one.message)
        XCTAssertTrue(one.isNeeded)
        XCTAssertEqual(one.confirm, "Force Push")
        let many = ForcePushQuestion(branch: "main", upstream: "origin/main", loses: (1...11).map { "h\($0) commit \($0)" })
        XCTAssertTrue(many.message.contains("These 11 commits on origin/main are not in “main”"))
        XCTAssertTrue(many.message.contains("• h8 commit 8\n… and 3 more"), many.message)
        XCTAssertFalse(many.message.contains("commit 9"))
        let none = ForcePushQuestion(branch: "main", upstream: "origin/main", loses: [])
        XCTAssertFalse(none.isNeeded)
        XCTAssertTrue(none.message.contains("a push without force does the same"))

        XCTAssertTrue(DisplaySettings().fetchAutomatically)
        let old = try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"temperatureUnit":"celsius","diffLayout":"split","changesView":"tree"}"#.utf8))
        XCTAssertTrue(old.fetchAutomatically, "on for settings saved before there was the choice")
        var off = DisplaySettings()
        off.fetchAutomatically = false
        XCTAssertFalse(try JSONDecoder().decode(DisplaySettings.self, from: JSONEncoder().encode(off.checked)).fetchAutomatically)
        for message in [ServerMessage.gitFetched(path: "/p", problem: "no route", automatic: true), .gitForcePushPreview(path: "/p", upstream: nil, loses: [])] {
            XCTAssertEqual(try XCTUnwrap(MessageCoding.decode(ServerMessage.self, from: MessageCoding.encode(message))), message)
        }
    }
}
