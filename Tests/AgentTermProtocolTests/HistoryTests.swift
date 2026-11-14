import XCTest

@testable import AgentTermProtocol

/// What History shows of the conversations, and says of one (#46): the
/// same on both apps.
final class HistoryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()
    /// Saturday 14 November 2026, noon.
    private let now = Date(timeIntervalSince1970: 1_794_657_600)

    private func conversation(_ id: String, agent: String = "claude", cwd: String = "/code/app", hoursAgo: Double) -> Conversation {
        Conversation(agent: agent, sessionID: id, title: "title \(id)", updatedAt: now.addingTimeInterval(-hoursAgo * 3600), cwd: cwd)
    }

    private var all: [Conversation] {
        [
            conversation("a", hoursAgo: 1), conversation("b", agent: "codex", hoursAgo: 2), conversation("c", cwd: "/code/other", hoursAgo: 30),
            conversation("d", agent: "codex", cwd: "/code/app/.agentterm/worktrees/x", hoursAgo: 100), conversation("e", hoursAgo: 24 * 20),
        ]
    }

    private func ids(_ filter: HistoryFilter, pinned: Set<String> = [], hidden: Set<String> = []) -> [String] {
        filter.groups(all, pinned: pinned, hidden: hidden, agentNames: [("claude", "Claude Code"), ("codex", "Codex")], now: now, calendar: calendar)
            .map { $0.title + ": " + $0.conversations.map(\.sessionID).joined(separator: ",") }
    }

    /// HIST-15: the conversations filtered by agent, by folder, a
    /// worktree of it included, and by when.
    func testConversationsAreFilteredByAgentFolderAndWhen() {
        XCTAssertEqual(ids(HistoryFilter()), ["Claude Code: a,c,e", "Codex: b,d"])
        XCTAssertFalse(HistoryFilter().isActive)
        XCTAssertEqual(ids(HistoryFilter(agent: "codex")), ["Codex: b,d"])
        XCTAssertEqual(ids(HistoryFilter(folder: "/code/app")), ["Claude Code: a,e", "Codex: b,d"], "a worktree of the folder is the folder's")
        XCTAssertEqual(ids(HistoryFilter(when: .today)), ["Claude Code: a", "Codex: b"])
        XCTAssertEqual(ids(HistoryFilter(when: .thisWeek)), ["Claude Code: a,c", "Codex: b,d"], "since Monday")
        XCTAssertEqual(ids(HistoryFilter(when: .day(now.addingTimeInterval(-30 * 3600)))), ["Claude Code: c"])
        XCTAssertEqual(ids(HistoryFilter(agent: "codex", folder: "/code/other")), [])
        XCTAssertTrue(HistoryFilter(when: .today).isActive)
    }

    /// HIST-16: grouped by day, the newest first, with today and
    /// yesterday named; the pinned ones first in either grouping; a hidden
    /// one left out unless hidden ones are shown.
    func testConversationsAreGroupedByDayPinnedFirstAndHiddenLeftOut() {
        let byDay = ids(HistoryFilter(grouping: .day))
        XCTAssertEqual(byDay.count, 4)
        XCTAssertEqual(byDay[0], "Today: a,b")
        XCTAssertEqual(byDay[1], "Yesterday: c")
        XCTAssertTrue(byDay[2].hasSuffix(": d") && byDay[3].hasSuffix(": e"))
        XCTAssertEqual(ids(HistoryFilter(), pinned: ["claude:e", "codex:b"]), ["Pinned: b,e", "Claude Code: a,c", "Codex: d"])
        XCTAssertEqual(ids(HistoryFilter(grouping: .day), pinned: ["claude:a"]).prefix(2), ["Pinned: a", "Today: b"])
        XCTAssertEqual(ids(HistoryFilter(), hidden: ["claude:a", "codex:b"]), ["Claude Code: c,e", "Codex: d"])
        XCTAssertEqual(ids(HistoryFilter(showsHidden: true), hidden: ["claude:a"]), ["Claude Code: a,c,e", "Codex: b,d"])
        // An agent that is not among the known ones still has its group.
        let unknown = HistoryFilter().groups([conversation("z", agent: "new", hoursAgo: 1)], agentNames: [("claude", "Claude Code")], now: now, calendar: calendar)
        XCTAssertEqual(unknown.map(\.title), ["new"])
    }

    /// HIST-17: what is said of a conversation's length and tokens, what
    /// is asked before one is deleted, twice, and that what was read of
    /// one goes over the wire and back.
    func testWhatIsSaidOfAConversation() throws {
        XCTAssertEqual(ConversationDetails.words(for: 40), "40 s")
        XCTAssertEqual(ConversationDetails.words(for: 12 * 60 + 20), "12 min")
        XCTAssertEqual(ConversationDetails.words(for: 2 * 3600), "2 h")
        XCTAssertEqual(ConversationDetails.words(for: 2 * 3600 + 5 * 60), "2 h 5 min")
        XCTAssertEqual(ConversationDetails.words(forTokens: 512), "512")
        XCTAssertEqual(ConversationDetails.words(forTokens: 34_400), "34k")
        XCTAssertEqual(ConversationDetails.words(forTokens: 1_250_000), "1.2M")

        var details = ConversationDetails(conversation: conversation("d", agent: "codex", cwd: "/code/app/.agentterm/worktrees/agentterm/codex-1", hoursAgo: 1))
        XCTAssertEqual(details.worktree, "codex-1")
        XCTAssertEqual(details.facts.map { "\($0.name): \($0.value)" }, ["Worktree: codex-1", "Tools run: 0", "Files changed: not recorded by this agent"])
        details.files = []
        details.entries = [TranscriptEntry(id: 0, kind: .user, text: "hello"), TranscriptEntry(id: 1, kind: .tool, text: "ls `x`", tool: "exec")]
        details.omitted = 3
        XCTAssertEqual(details.facts.last?.value, "none")
        XCTAssertTrue(details.markdown(agentName: "Codex").contains("_3 earlier entries are left out._"))
        XCTAssertTrue(details.markdown(agentName: "Codex").contains("> **exec** `ls 'x'`"))
        XCTAssertNil(ConversationDetails(conversation: conversation("a", hoursAgo: 1)).worktree)
        XCTAssertEqual(try JSONDecoder().decode(ConversationDetails.self, from: JSONEncoder().encode(details)), details)

        let first = DeleteConversationQuestion(conversation("a", hoursAgo: 1), agentName: "Claude Code", again: false)
        XCTAssertEqual(first.title, "Delete this conversation?")
        XCTAssertTrue(first.message.contains("hide it instead"))
        let second = DeleteConversationQuestion(conversation("a", hoursAgo: 1), agentName: "Claude Code", again: true)
        XCTAssertEqual(second.title, "Delete it for good from Claude Code?")
        XCTAssertEqual(second.confirm, "Delete Conversation")
    }
}
