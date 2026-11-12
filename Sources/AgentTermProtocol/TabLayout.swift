import Foundation

/// A named, colored run of tabs that belong together.
public struct TabGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// One of `TabLayout.colors`.
    public var color: String
    /// A collapsed group shows only its label, and the tab in front if it is one of its own.
    public var isCollapsed: Bool

    public init(id: String, name: String, color: String, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
    }
}

/// How the tabs of a window are arranged: their order, which are pinned and
/// which are grouped. Tabs are named by opaque ids; what a tab shows is not
/// this type's business.
///
/// Two rules always hold. Pinned tabs come first, and are in no group. The
/// tabs of a group sit next to each other.
public struct TabLayout: Codable, Equatable, Sendable {
    public private(set) var order: [String] = []
    public private(set) var pinned: Set<String> = []
    /// The group each grouped tab is in, by tab id.
    public private(set) var groupOf: [String: String] = [:]
    public private(set) var groups: [TabGroup] = []

    public static let colors = ["blue", "green", "orange", "red", "purple", "teal", "pink", "gray"]

    public init() {}

    /// What the strip shows, from left to right.
    public enum Item: Equatable, Sendable {
        /// The label of a group, before its tabs, with how many it holds.
        case group(TabGroup, count: Int)
        case tab(String)
    }

    // MARK: Reading

    public func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    public func group(of id: String) -> TabGroup? {
        groupOf[id].flatMap { groupID in groups.first { $0.id == groupID } }
    }

    public func members(of groupID: String) -> [String] {
        order.filter { groupOf[$0] == groupID }
    }

    /// The strip's contents. A collapsed group keeps its label; of its tabs
    /// only the one in front, if any, stays on show.
    public func items(front: String? = nil) -> [Item] {
        var items: [Item] = []
        var announced: Set<String> = []
        for id in order {
            if let group = group(of: id) {
                if announced.insert(group.id).inserted {
                    items.append(.group(group, count: members(of: group.id).count))
                }
                if group.isCollapsed, id != front { continue }
            }
            items.append(.tab(id))
        }
        return items
    }

    /// The tabs on show, in order: what Command and a number counts.
    public func visibleTabs(front: String? = nil) -> [String] {
        items(front: front).compactMap { if case .tab(let id) = $0 { return id } else { return nil } }
    }

    // MARK: Keeping up with the tabs that exist

    /// Drops tabs that are gone and adds new ones at the end. A client that
    /// knows only some kinds of tab says which with `owns`; tabs of other
    /// kinds are left alone, for the client that knows them.
    public mutating func sync(with live: [String], owns: (String) -> Bool = { _ in true }) {
        let existing = Set(live).union(order.filter { !owns($0) })
        order.removeAll { !existing.contains($0) }
        for id in live where !order.contains(id) { order.append(id) }
        pinned.formIntersection(existing)
        groupOf = groupOf.filter { existing.contains($0.key) }
        normalize()
    }

    // MARK: Arranging

    /// Moves a tab to just before another, or to the end when `target` is
    /// nil. It takes on the place it lands in: pinned among the pinned, and
    /// in the group of the tab it is put next to.
    public mutating func move(_ id: String, before target: String?) {
        guard order.contains(id), id != target else { return }
        order.removeAll { $0 == id }
        if let target, let index = order.firstIndex(of: target) {
            order.insert(id, at: index)
            adopt(id, placeOf: target)
        } else {
            order.append(id)
            pinned.remove(id)
            groupOf[id] = nil
        }
        normalize()
    }

    /// Moves a tab to just after another, taking on that one's place as in
    /// `move(_:before:)`.
    public mutating func move(_ id: String, after target: String) {
        guard id != target, order.contains(target), let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        let to = order.firstIndex(of: target).map { $0 + 1 } ?? order.count
        order.insert(id, at: to)
        adopt(id, placeOf: target)
        normalize()
    }

    /// Moves a tab one place to the left (-1) or right (+1) among the tabs on show.
    public mutating func move(_ id: String, by offset: Int, front: String? = nil) {
        let visible = visibleTabs(front: front)
        guard let index = visible.firstIndex(of: id), visible.indices.contains(index + offset) else { return }
        let neighbor = visible[index + offset]
        if offset < 0 { move(id, before: neighbor) } else { move(id, after: neighbor) }
    }

    private mutating func adopt(_ id: String, placeOf other: String) {
        if pinned.contains(other) {
            pinned.insert(id)
            groupOf[id] = nil
        } else {
            pinned.remove(id)
            groupOf[id] = groupOf[other]
        }
    }

    public mutating func setPinned(_ id: String, _ isPinned: Bool) {
        guard order.contains(id) else { return }
        if isPinned {
            pinned.insert(id)
        } else {
            pinned.remove(id)
            // Lands right after the pinned tabs, where it was in view.
            order.removeAll { $0 == id }
            order.insert(id, at: order.filter { pinned.contains($0) }.count)
        }
        normalize()
    }

    // MARK: Groups

    /// Starts a group with one tab in it. Returns the group's id.
    @discardableResult
    public mutating func newGroup(with id: String, name: String? = nil) -> String? {
        guard order.contains(id) else { return nil }
        let used = Set(groups.map(\.color))
        let color = Self.colors.first { !used.contains($0) } ?? Self.colors[groups.count % Self.colors.count]
        let group = TabGroup(id: UUID().uuidString, name: name ?? "Group \(groups.count + 1)", color: color)
        groups.append(group)
        pinned.remove(id)
        groupOf[id] = group.id
        normalize()
        return group.id
    }

    /// Puts a tab at the end of a group.
    public mutating func add(_ id: String, toGroup groupID: String) {
        guard order.contains(id), groups.contains(where: { $0.id == groupID }), groupOf[id] != groupID else { return }
        pinned.remove(id)
        order.removeAll { $0 == id }
        let last = order.lastIndex { groupOf[$0] == groupID }
        order.insert(id, at: last.map { $0 + 1 } ?? order.count)
        groupOf[id] = groupID
        normalize()
    }

    /// Takes a tab out of its group. It stays where the group ends.
    public mutating func removeFromGroup(_ id: String) {
        guard let groupID = groupOf[id] else { return }
        groupOf[id] = nil
        order.removeAll { $0 == id }
        let last = order.lastIndex { groupOf[$0] == groupID }
        order.insert(id, at: last.map { $0 + 1 } ?? min(order.count, order.filter { pinned.contains($0) }.count))
        normalize()
    }

    /// Dissolves a group. Its tabs stay where they are.
    public mutating func ungroup(_ groupID: String) {
        groupOf = groupOf.filter { $0.value != groupID }
        normalize()
    }

    public mutating func rename(_ groupID: String, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func setColor(_ color: String, of groupID: String) {
        guard Self.colors.contains(color), let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].color = color
    }

    public mutating func toggleCollapsed(_ groupID: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].isCollapsed.toggle()
    }

    // MARK: The rules

    private mutating func normalize() {
        for id in pinned { groupOf[id] = nil }
        // A group with no tabs left is gone.
        let used = Set(groupOf.values)
        groups.removeAll { !used.contains($0.id) }
        let known = Set(groups.map(\.id))
        groupOf = groupOf.filter { known.contains($0.value) }

        var arranged = order.filter { pinned.contains($0) }
        var placed = Set(arranged)
        for id in order where !placed.contains(id) {
            if let groupID = groupOf[id] {
                // The whole group follows its first tab.
                for member in order where groupOf[member] == groupID && placed.insert(member).inserted {
                    arranged.append(member)
                }
            } else {
                arranged.append(id)
                placed.insert(id)
            }
        }
        order = arranged
    }
}

extension SessionInfo {
    /// This session's name in a `TabLayout`. A session's number starts over
    /// with every host, so the moment it was started is part of the name: a
    /// pin or a group never lands on another session that gets the same number.
    /// Whether a name in a `TabLayout` is a session's.
    public static func isLayoutID(_ id: String) -> Bool { id.hasPrefix("s:") }

    public var layoutID: String { "s:\(id):\(Int(createdAt.timeIntervalSince1970))" }
}
