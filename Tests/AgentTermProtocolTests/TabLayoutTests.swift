import AgentTermProtocol
import XCTest

final class TabLayoutTests: XCTestCase {
    private func layout(_ ids: String...) -> TabLayout {
        var layout = TabLayout()
        layout.sync(with: ids)
        return layout
    }

    /// The strip as text: "[name]" for a group label, the id for a tab.
    private func strip(_ layout: TabLayout, front: String? = nil) -> [String] {
        layout.items(front: front).map {
            switch $0 {
            case .group(let group, let count): return "[\(group.name):\(count)]"
            case .tab(let id): return id
            }
        }
    }

    func testNewTabsGoToTheEndAndGoneOnesDisappear() {
        var tabs = layout("a", "b", "c")
        tabs.move("c", before: "a")
        tabs.sync(with: ["a", "b", "c", "d"])
        XCTAssertEqual(tabs.order, ["c", "a", "b", "d"], "the order chosen is kept; the new tab is last")
        tabs.setPinned("b", true)
        tabs.sync(with: ["a", "d"])
        XCTAssertEqual(tabs.order, ["a", "d"])
        XCTAssertEqual(tabs.pinned, [])
    }

    func testDraggingATabPutsItBeforeTheOneItIsDroppedOn() {
        var tabs = layout("a", "b", "c", "d")
        tabs.move("d", before: "b")
        XCTAssertEqual(tabs.order, ["a", "d", "b", "c"])
        tabs.move("a", before: nil)
        XCTAssertEqual(tabs.order, ["d", "b", "c", "a"], "dropped past the last tab")
        tabs.move("b", before: "b")
        tabs.move("nope", before: "a")
        XCTAssertEqual(tabs.order, ["d", "b", "c", "a"])
    }

    func testPinnedTabsComeFirst() {
        var tabs = layout("a", "b", "c", "d")
        tabs.setPinned("c", true)
        tabs.setPinned("d", true)
        XCTAssertEqual(tabs.order, ["c", "d", "a", "b"])
        // Dropped among the pinned, a tab is pinned; dropped after them, it is not.
        tabs.move("a", before: "d")
        XCTAssertEqual(tabs.order, ["c", "a", "d", "b"])
        XCTAssertEqual(tabs.pinned, ["a", "c", "d"])
        tabs.move("c", before: "b")
        XCTAssertEqual(tabs.order, ["a", "d", "c", "b"])
        XCTAssertFalse(tabs.isPinned("c"))
        tabs.setPinned("a", false)
        XCTAssertEqual(tabs.order, ["d", "a", "c", "b"], "unpinned, it sits right after the pinned ones")
    }

    func testGroupsKeepTheirTabsTogether() {
        var tabs = layout("a", "b", "c", "d", "e")
        let group = tabs.newGroup(with: "b", name: "api")!
        tabs.add("d", toGroup: group)
        XCTAssertEqual(strip(tabs), ["a", "[api:2]", "b", "d", "c", "e"])
        // Dropped on a tab of the group, a tab joins it; dropped elsewhere, it leaves.
        tabs.move("e", before: "d")
        XCTAssertEqual(strip(tabs), ["a", "[api:3]", "b", "e", "d", "c"])
        tabs.move("b", before: "a")
        XCTAssertEqual(strip(tabs), ["b", "a", "[api:2]", "e", "d", "c"])
        tabs.removeFromGroup("e")
        XCTAssertEqual(strip(tabs), ["b", "a", "[api:1]", "d", "e", "c"], "it stays where the group ends")
        // A pinned tab is in no group, and a group without tabs is gone.
        tabs.setPinned("d", true)
        XCTAssertEqual(strip(tabs), ["d", "b", "a", "e", "c"])
        XCTAssertEqual(tabs.groups, [])
    }

    func testACollapsedGroupShowsOnlyItsLabelAndTheTabInFront() {
        var tabs = layout("a", "b", "c", "d")
        let group = tabs.newGroup(with: "b", name: "docs")!
        tabs.add("c", toGroup: group)
        tabs.toggleCollapsed(group)
        XCTAssertEqual(strip(tabs), ["a", "[docs:2]", "d"])
        XCTAssertEqual(strip(tabs, front: "c"), ["a", "[docs:2]", "c", "d"])
        XCTAssertEqual(tabs.visibleTabs(), ["a", "d"], "what Command and a number counts")
        tabs.toggleCollapsed(group)
        XCTAssertEqual(tabs.visibleTabs(), ["a", "b", "c", "d"])
    }

    func testGroupsCanBeRenamedRecoloredAndDissolved() {
        var tabs = layout("a", "b", "c")
        let first = tabs.newGroup(with: "a")!
        let second = tabs.newGroup(with: "c")!
        XCTAssertEqual(tabs.groups.map(\.name), ["Group 1", "Group 2"])
        XCTAssertEqual(tabs.groups.map(\.color), ["blue", "green"], "each new group takes a color not in use")
        tabs.rename(first, to: "  backend ")
        tabs.setColor("red", of: second)
        tabs.setColor("not-a-color", of: first)
        XCTAssertEqual(tabs.groups.map(\.name), ["backend", "Group 2"])
        XCTAssertEqual(tabs.groups.map(\.color), ["blue", "red"])
        tabs.ungroup(first)
        XCTAssertEqual(strip(tabs), ["a", "b", "[Group 2:1]", "c"])
    }

    func testMovingByOnePlace() {
        var tabs = layout("a", "b", "c")
        tabs.move("a", by: 1)
        XCTAssertEqual(tabs.order, ["b", "a", "c"])
        tabs.move("a", by: 1)
        tabs.move("a", by: 1)
        XCTAssertEqual(tabs.order, ["b", "c", "a"], "it stops at the end")
        tabs.move("a", by: -1)
        XCTAssertEqual(tabs.order, ["b", "a", "c"])
        // Stepping next to a grouped tab joins its group, as dropping there would.
        let group = tabs.newGroup(with: "c", name: "g")!
        tabs.move("a", by: 1)
        XCTAssertEqual(tabs.group(of: "a")?.id, group)
        XCTAssertEqual(strip(tabs), ["b", "[g:2]", "c", "a"])
    }

    func testAClientThatKnowsOnlySessionsLeavesOtherTabsAlone() {
        var tabs = layout("s:1:10", "f:/a.md", "s:2:20")
        tabs.setPinned("f:/a.md", true)
        // The phone: session 1 ended, session 3 is new. The file's tab is the Mac's.
        tabs.sync(with: ["s:2:20", "s:3:30"], owns: SessionInfo.isLayoutID)
        XCTAssertEqual(tabs.order, ["f:/a.md", "s:2:20", "s:3:30"])
        XCTAssertTrue(tabs.isPinned("f:/a.md"))
    }

    func testTheLayoutSurvivesBeingSaved() throws {
        var tabs = layout("a", "b", "c")
        tabs.setPinned("c", true)
        tabs.newGroup(with: "a", name: "x")
        let restored = try JSONDecoder().decode(TabLayout.self, from: JSONEncoder().encode(tabs))
        XCTAssertEqual(restored, tabs)
    }
}
