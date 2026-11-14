import XCTest

@testable import AgentTermEditor

final class EditorTests: XCTestCase {
    /// FIND-12 (#45): where a line is in a text, for the editor to show it:
    /// by its number from 1, without the line break at its end; the last
    /// line for a number past the end.
    func testWhereALineIsInAText() {
        let text = "one\ntwo\n\nfour" as NSString
        XCTAssertEqual(text.substring(with: LineTarget.range(ofLine: 1, in: text)), "one")
        XCTAssertEqual(text.substring(with: LineTarget.range(ofLine: 2, in: text)), "two")
        XCTAssertEqual(LineTarget.range(ofLine: 3, in: text), NSRange(location: 8, length: 0), "an empty line")
        XCTAssertEqual(text.substring(with: LineTarget.range(ofLine: 4, in: text)), "four")
        XCTAssertEqual(text.substring(with: LineTarget.range(ofLine: 40, in: text)), "four", "past the end: the last line")
        XCTAssertEqual(text.substring(with: LineTarget.range(ofLine: 0, in: text)), "one")
        XCTAssertEqual(LineTarget.range(ofLine: 3, in: "" as NSString), NSRange(location: 0, length: 0))
        let windows = "a\r\nb\r\n" as NSString
        XCTAssertEqual(windows.substring(with: LineTarget.range(ofLine: 2, in: windows)), "b")
    }

    /// PERF-11 (#21): text is colored when it is in a language the
    /// highlighter knows and not larger than half a megabyte; a larger file,
    /// and plain text of any size, is shown without, since coloring 5 MB
    /// held the window for seconds.
    @MainActor
    func testLargeAndPlainTextIsNotColored() {
        XCTAssertTrue(Highlighting.colors("/p/main.swift", length: 20_000))
        XCTAssertTrue(Highlighting.colors("/p/main.swift", length: Highlighting.largestColored))
        XCTAssertFalse(Highlighting.colors("/p/main.swift", length: Highlighting.largestColored + 1))
        XCTAssertFalse(Highlighting.colors("/p/notes.txt", length: 10), "plain text has nothing to color")
        XCTAssertFalse(Highlighting.colors("/p/large.log", length: 5 * 1024 * 1024))
        // The storage made for each: the one that colors, or a plain one.
        func colors(_ storage: NSTextStorage) -> Bool { String(describing: type(of: storage)).contains("CodeAttributedString") }
        XCTAssertFalse(colors(Highlighting.storage(for: "/p/notes.txt", fontSize: 12, length: 10)))
        XCTAssertFalse(colors(Highlighting.storage(for: "/p/main.swift", fontSize: 12, length: Highlighting.largestColored + 1)))
        if Highlighting.shared != nil { XCTAssertTrue(colors(Highlighting.storage(for: "/p/main.swift", fontSize: 12, length: 10))) }
    }
}
