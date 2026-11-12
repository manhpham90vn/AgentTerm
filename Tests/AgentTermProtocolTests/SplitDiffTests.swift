import AgentTermProtocol
import XCTest

final class SplitDiffTests: XCTestCase {
    /// A row as text: "12 old | 12 new", with "~" before a changed line.
    private func show(_ rows: [SplitDiffRow]) -> [String] {
        rows.map { row in
            if let hunk = row.hunk { return hunk }
            func side(_ line: SplitDiffRow.Line?) -> String { line.map { "\($0.changed ? "~" : "")\($0.number) \($0.text)" } ?? "" }
            return side(row.left) + " | " + side(row.right)
        }
    }

    func testChangedLinesFaceEachOtherAndSharedLinesShareARow() {
        let patch = """
            @@ -10,5 +10,6 @@ func greet()
             let name = "a"
            -print("hello")
            -print("bye")
            +print("xin chào")
            +print("tạm biệt")
            +print("hẹn gặp lại")
             return
            -old tail
            """
        XCTAssertEqual(
            show(SplitDiff.rows(for: patch)),
            [
                "@@ -10,5 +10,6 @@ func greet()",
                "10 let name = \"a\" | 10 let name = \"a\"",
                "~11 print(\"hello\") | ~11 print(\"xin chào\")",
                "~12 print(\"bye\") | ~12 print(\"tạm biệt\")",
                " | ~13 print(\"hẹn gặp lại\")",
                "13 return | 14 return",
                "~14 old tail | ",
            ])
    }

    func testANewFileHasOnlyARightSideAndADeletedOneOnlyALeft() {
        XCTAssertEqual(show(SplitDiff.rows(for: "@@ -0,0 +1,2 @@\n+one\n+two")), ["@@ -0,0 +1,2 @@", " | ~1 one", " | ~2 two"])
        XCTAssertEqual(show(SplitDiff.rows(for: "@@ -1,2 +0,0 @@\n-one\n-two")), ["@@ -1,2 +0,0 @@", "~1 one | ", "~2 two | "])
    }

    func testSeveralHunksKeepTheirOwnNumbersAndEmptyLinesStay() {
        let patch = "@@ -1,3 +1,3 @@\n a\n-b\n+B\n \n@@ -40 +40,2 @@ later\n-x\n+y\n+z\n\\ No newline at end of file\n"
        XCTAssertEqual(
            show(SplitDiff.rows(for: patch)),
            ["@@ -1,3 +1,3 @@", "1 a | 1 a", "~2 b | ~2 B", "3  | 3 ", "@@ -40 +40,2 @@ later", "~40 x | ~40 y", " | ~41 z"])
    }

    func testAddedThenRemovedLinesAreTwoChanges() {
        XCTAssertEqual(
            show(SplitDiff.rows(for: "@@ -1,2 +1,2 @@\n+new first\n-old first\n same")),
            ["@@ -1,2 +1,2 @@", " | ~1 new first", "~1 old first | ", "2 same | 2 same"])
    }

    func testWhatIsNotADiffIsShownAsANote() {
        XCTAssertEqual(show(SplitDiff.rows(for: "Binary file changed")), ["Binary file changed"])
        XCTAssertEqual(SplitDiff.rows(for: ""), [])
        XCTAssertEqual(SplitDiff.rows(for: "@@ -1,3 +1,3 @@\n a\n b\n c", limit: 2).count, 2)
    }
}
