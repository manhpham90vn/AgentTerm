import Foundation

/// One thing in a conversation as it is read (#46): what the user asked,
/// what the agent answered, or a tool the agent ran.
public struct TranscriptEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user
        case agent
        case tool
    }

    /// Its place in the conversation.
    public var id: Int
    public var kind: Kind
    /// What was said; for a tool, what it was run on: a command, a file.
    public var text: String
    /// The tool's name, for a tool.
    public var tool: String?
    public var at: Date?

    public init(id: Int, kind: Kind, text: String, tool: String? = nil, at: Date? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.tool = tool
        self.at = at
    }
}

/// A conversation read from its agent's own file (#46): what was said and
/// run in it, and what the file tells about it. What an agent does not
/// record is nil here, and shown as not known.
public struct ConversationDetails: Codable, Equatable, Sendable {
    public var conversation: Conversation
    /// Oldest first. A long conversation is given by its end.
    public var entries: [TranscriptEntry]
    /// How many earlier entries were left out.
    public var omitted: Int
    /// When its first and last lines were written.
    public var startedAt: Date?
    public var endedAt: Date?
    public var model: String?
    /// Tokens the agent says it read and wrote, where it says.
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// What it cost, where the agent says, in US dollars.
    public var cost: Double?
    /// The branch it ran on, where the agent says.
    public var branch: String?
    /// The files its tools wrote to, as far as the agent's record tells;
    /// nil when it does not tell.
    public var files: [String]?
    /// How many tools it ran.
    public var tools: Int

    public init(
        conversation: Conversation, entries: [TranscriptEntry] = [], omitted: Int = 0, startedAt: Date? = nil, endedAt: Date? = nil, model: String? = nil,
        inputTokens: Int? = nil, outputTokens: Int? = nil, cost: Double? = nil, branch: String? = nil, files: [String]? = nil, tools: Int = 0
    ) {
        self.conversation = conversation
        self.entries = entries
        self.omitted = omitted
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cost = cost
        self.branch = branch
        self.files = files
        self.tools = tools
    }

    /// The worktree it ran in, when AgentTerm made one for it.
    public var worktree: String? {
        WorktreePath.project(of: conversation.cwd) == nil ? nil : (conversation.cwd as NSString).lastPathComponent
    }

    /// How long it ran, from its first line to its last.
    public var duration: TimeInterval? {
        guard let startedAt = startedAt ?? conversation.startedAt else { return nil }
        let length = (endedAt ?? conversation.updatedAt).timeIntervalSince(startedAt)
        return length >= 0 ? length : nil
    }

    /// "2 h 5 min", "12 min", "40 s".
    public static func words(for duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// "1.2M", "34k", "512": a count of tokens, short.
    public static func words(forTokens count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1000 { return "\(Int((Double(count) / 1000).rounded()))k" }
        return "\(count)"
    }

    /// What is known about it, a line each as a name and what it is: for
    /// the top of the transcript on both apps.
    public var facts: [(name: String, value: String)] {
        var facts: [(String, String)] = []
        if let duration { facts.append(("Ran for", Self.words(for: duration))) }
        if let model { facts.append(("Model", model)) }
        if inputTokens != nil || outputTokens != nil {
            let read = inputTokens.map { Self.words(forTokens: $0) + " in" }
            let written = outputTokens.map { Self.words(forTokens: $0) + " out" }
            facts.append(("Tokens", [read, written].compactMap { $0 }.joined(separator: ", ")))
        }
        if let cost { facts.append(("Cost", String(format: "$%.2f", cost))) }
        if let branch, !branch.isEmpty { facts.append(("Branch", branch)) }
        if let worktree { facts.append(("Worktree", worktree)) }
        facts.append(("Tools run", "\(tools)"))
        if let files {
            facts.append(("Files changed", files.isEmpty ? "none" : "\(files.count)"))
        } else {
            facts.append(("Files changed", "not recorded by this agent"))
        }
        return facts.map { (name: $0.0, value: $0.1) }
    }

    /// The conversation as a document to copy or to keep: Markdown, with
    /// what is known about it first.
    public func markdown(agentName: String) -> String {
        var text = "# \(conversation.title)\n\n"
        text += "- Agent: \(agentName)\n- Folder: \(conversation.cwd)\n"
        for fact in facts { text += "- \(fact.name): \(fact.value)\n" }
        if let files, !files.isEmpty { text += "\nFiles changed:\n\n" + files.map { "- `\($0)`" }.joined(separator: "\n") + "\n" }
        if omitted > 0 { text += "\n_\(omitted) earlier entries are left out._\n" }
        for entry in entries {
            switch entry.kind {
            case .user: text += "\n## You\n\n\(entry.text)\n"
            case .agent: text += "\n## \(agentName)\n\n\(entry.text)\n"
            case .tool: text += "\n> **\(entry.tool ?? "Tool")** \(entry.text.isEmpty ? "" : "`\(entry.text.replacingOccurrences(of: "`", with: "'"))`")\n"
            }
        }
        return text
    }
}

/// A conversation found by a search of History (#46): where the words
/// are, when they are in what was said and not only in its title.
public struct HistoryHit: Codable, Equatable, Identifiable, Sendable {
    public var conversation: Conversation
    /// A piece of what was said, around the first place the words are.
    public var snippet: String?
    /// How many of its entries hold the words.
    public var count: Int

    public var id: String { conversation.id }

    public init(conversation: Conversation, snippet: String? = nil, count: Int = 0) {
        self.conversation = conversation
        self.snippet = snippet
        self.count = count
    }
}

/// Which conversations History shows, and how they are grouped (#46). The
/// same on both apps, which filter what the host listed.
public struct HistoryFilter: Equatable, Sendable {
    public enum When: Equatable, Sendable {
        case any
        case today
        case thisWeek
        /// One day.
        case day(Date)

        public var title: String {
            switch self {
            case .any: return "Any Time"
            case .today: return "Today"
            case .thisWeek: return "This Week"
            case .day(let date): return date.formatted(date: .abbreviated, time: .omitted)
            }
        }
    }

    public enum Grouping: String, CaseIterable, Sendable {
        case agent
        case day

        public var title: String { self == .agent ? "By Agent" : "By Day" }
    }

    /// An agent's id, nil for all of them.
    public var agent: String?
    /// A folder, nil for all of them. A conversation in a worktree
    /// AgentTerm made for the folder is the folder's.
    public var folder: String?
    public var when = When.any
    public var grouping = Grouping.agent
    /// Hidden conversations are shown too.
    public var showsHidden = false

    public init(agent: String? = nil, folder: String? = nil, when: When = .any, grouping: Grouping = .agent, showsHidden: Bool = false) {
        self.agent = agent
        self.folder = folder
        self.when = when
        self.grouping = grouping
        self.showsHidden = showsHidden
    }

    /// Whether anything is left out by it.
    public var isActive: Bool { agent != nil || folder != nil || when != .any }

    public func allows(_ conversation: Conversation, hidden: Set<String> = [], now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if !showsHidden, hidden.contains(conversation.id) { return false }
        if let agent, conversation.agent != agent { return false }
        if let folder, !WorktreePath.belongs(conversation.cwd, to: folder) { return false }
        switch when {
        case .any: return true
        case .today: return calendar.isDate(conversation.updatedAt, inSameDayAs: now)
        case .thisWeek:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return true }
            return week.contains(conversation.updatedAt)
        case .day(let day): return calendar.isDate(conversation.updatedAt, inSameDayAs: day)
        }
    }

    /// One group of the list: its title and its conversations, newest first.
    public struct Group: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var conversations: [Conversation]
    }

    /// The conversations it allows, grouped: the pinned ones first in a
    /// group of their own, then by agent in the order given, or by day,
    /// the newest day first.
    public func groups(
        _ conversations: [Conversation], pinned: Set<String> = [], hidden: Set<String> = [], agentNames: [(id: String, name: String)],
        now: Date = Date(), calendar: Calendar = .current
    ) -> [Group] {
        let allowed = conversations.filter { allows($0, hidden: hidden, now: now, calendar: calendar) }.sorted { $0.updatedAt > $1.updatedAt }
        var groups: [Group] = []
        let kept = allowed.filter { pinned.contains($0.id) }
        if !kept.isEmpty { groups.append(Group(id: "pinned", title: "Pinned", conversations: kept)) }
        let rest = allowed.filter { !pinned.contains($0.id) }
        switch grouping {
        case .agent:
            var known = agentNames
            for conversation in rest where !known.contains(where: { $0.id == conversation.agent }) { known.append((conversation.agent, conversation.agent)) }
            for agent in known {
                let own = rest.filter { $0.agent == agent.id }
                if !own.isEmpty { groups.append(Group(id: "agent:" + agent.id, title: agent.name, conversations: own)) }
            }
        case .day:
            var order: [Date] = []
            var byDay: [Date: [Conversation]] = [:]
            for conversation in rest {
                let day = calendar.startOfDay(for: conversation.updatedAt)
                if byDay[day] == nil { order.append(day) }
                byDay[day, default: []].append(conversation)
            }
            for day in order {
                groups.append(Group(id: "day:\(Int(day.timeIntervalSince1970))", title: Self.title(of: day, now: now, calendar: calendar), conversations: byDay[day] ?? []))
            }
        }
        return groups
    }

    /// "Today", "Yesterday", or the date.
    public static func title(of day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }
}

/// What is asked before a conversation is deleted (#46): twice, since its
/// file is the agent's own record and nothing else keeps it.
public struct DeleteConversationQuestion: Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirm: String

    /// - Parameter again: The second question, after the first was confirmed.
    public init(_ conversation: Conversation, agentName: String, again: Bool) {
        if again {
            title = "Delete it for good from \(agentName)?"
            message =
                "“\(conversation.title)” can then no longer be resumed, read or handed off, in AgentTerm or in \(agentName) itself. Its file is moved to the Trash of the Mac, from where it can be put back by hand."
            confirm = "Delete Conversation"
        } else {
            title = "Delete this conversation?"
            message =
                "This deletes \(agentName)'s own record of “\(conversation.title)”, not only its row here. To take it out of this list and keep it, hide it instead."
            confirm = "Delete…"
        }
    }
}
