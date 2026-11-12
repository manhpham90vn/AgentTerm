import AgentTermEditor
import XCTest

final class MarkdownHTMLTests: XCTestCase {
    func testPlainMarkdownIsLeftAlone() {
        let text = "# Title\n\nSome *text* and a [link](https://example.com).\n\n- one\n- two\n\nAn autolink: <https://example.com>, and 1 < 2.\n"
        XCTAssertEqual(MarkdownHTML.flatten(text), text)
    }

    func testImagesAndLinksBecomeMarkdown() {
        XCTAssertEqual(
            MarkdownHTML.flatten(#"<img src="docs/a.png" alt="The app" width="900">"#),
            "![The app](docs/a.png#agentterm-width=900)"
        )
        XCTAssertEqual(MarkdownHTML.flatten("<img width=200 src='b.png'>"), "![](b.png#agentterm-width=200)")
        XCTAssertEqual(MarkdownHTML.flatten("<img src='b.png' width=\"50%\">"), "![](b.png)", "only a width in points is carried")
        XCTAssertEqual(MarkdownHTML.width(in: "b.png#agentterm-width=200"), 200)
        XCTAssertNil(MarkdownHTML.width(in: "b.png#section"))
        XCTAssertEqual(
            MarkdownHTML.flatten(#"See <a href="https://example.com">the <b>site</b></a>."#),
            "See [the **site**](https://example.com)."
        )
        XCTAssertEqual(
            MarkdownHTML.flatten(#"<a href="https://x.y"><img src="badge.svg" alt="CI"></a>"#),
            "[![CI](badge.svg)](https://x.y)"
        )
    }

    func testBlocksThatOnlyArrangeThingsAreDropped() {
        let text = """
            <div align="center">

            # AgentTerm

            **A terminal.**

            <img src="docs/mac.png" alt="Mac" width="900">

            </div>

            ## Next
            """
        XCTAssertEqual(
            MarkdownHTML.flatten(text),
            """

            # AgentTerm

            **A terminal.**

            ![Mac](docs/mac.png#agentterm-width=900)

            ## Next
            """)
    }

    func testAParagraphOfImages() {
        let text = "<p>\n<img src=\"1.png\" alt=\"One\" width=\"200\">\n<img src=\"2.png\" alt=\"Two\" width=\"200\">\n</p>\n\nAfter."
        XCTAssertEqual(MarkdownHTML.flatten(text), "\n![One](1.png#agentterm-width=200)\n![Two](2.png#agentterm-width=200)\n\nAfter.")
    }

    func testInlineTags() {
        XCTAssertEqual(MarkdownHTML.flatten("Press <kbd>Esc</kbd>, <em>then</em> <strong>wait</strong>.<br>Done<br/>."), "Press `Esc`, *then* **wait**.  \nDone  \n.")
        XCTAssertEqual(MarkdownHTML.flatten("H<sub>2</sub>O is <span style=\"color:red\">wet</span>"), "H2O is wet")
        XCTAssertEqual(MarkdownHTML.flatten("<h2 align=\"center\">Title</h2>"), "\n## Title\n")
        XCTAssertEqual(MarkdownHTML.flatten("a <!-- hidden --> b"), "a  b")
    }

    func testDetailsKeepTheirText() {
        let text = "<details>\n<summary>More</summary>\n\nHidden *text*.\n\n</details>"
        XCTAssertEqual(MarkdownHTML.flatten(text), "\nMore\n\nHidden *text*.\n")
    }

    func testCodeIsNotTouched() {
        let text = "Use `<br>` for a break.\n\n```html\n<div align=\"center\">\n  <img src=\"a.png\">\n</div>\n```\n\n<b>bold</b>"
        XCTAssertEqual(MarkdownHTML.flatten(text), "Use `<br>` for a break.\n\n```html\n<div align=\"center\">\n  <img src=\"a.png\">\n</div>\n```\n\n**bold**")
    }

    func testScriptsAreNotRunOnlyShownOrDropped() {
        // Nothing interprets this: the tag is unknown and stays as text for the reader to see.
        let text = "<script>alert(1)</script>"
        XCTAssertEqual(MarkdownHTML.flatten(text), text)
    }
}
