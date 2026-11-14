import AgentTermProtocol
import XCTest

/// The Files tab of the Mac app and the files open in the middle pane.
final class FilesTests: MacUITestCase {
    func testOpeningEditingAndSavingAFile() throws {
        app.press(.button("Files"))
        // FILE-1: folders first, then files; git's own data is not listed.
        app.wait(for: .button("notes.txt"))
        let names = app.nodes().filter { $0.role == kAXButtonRole as String && ["docs, folder, collapsed", "notes.txt", "new.txt"].contains($0.label) }.map(\.label)
        XCTAssertEqual(names.first, "docs, folder, collapsed", "folders do not come first")
        XCTAssertFalse(app.exists(.containing(".git")))

        // A folder opens in place.
        app.press(.button("docs, folder, collapsed"))
        app.wait(for: .button("guide.md"))

        // FILE-3: a file opens in the editor, as a tab.
        app.press(.button("notes.txt"))
        let editor = MacDriver.Query.role(kAXTextAreaRole as String)
        wait("the file's text in the editor") { self.app.value(of: editor) == "first line\nsecond line\n" }
        // Edited, it is not on disk until it is saved.
        app.write("first line\nsecond line\nthird line, from the app\n", into: editor)
        XCTAssertEqual(read("notes.txt"), "first line\nsecond line\n")
        app.menu(["File", "Save"])
        wait("the file on disk") { self.read("notes.txt") == "first line\nsecond line\nthird line, from the app\n" }

        // FILE-6: an open file without edits of its own follows the disk.
        try write("rewritten by an agent\n", to: "notes.txt")
        app.press(.button("Refresh"))
        wait("the editor to follow the disk", timeout: 15) { self.app.value(of: editor) == "rewritten by an agent\n" }

        // FILE-7: the file is open again the next time the app starts.
        try relaunchApp()
        app.wait(for: .button("notes.txt"), timeout: 15)
        XCTAssertFalse(app.all(.button("notes.txt")).isEmpty, "the file that was open did not come back as a tab")
    }

    /// FIND-9 (#45): Go to File finds a file by part of its name and opens
    /// it; Find in Files finds a word with its file and line, and opens the
    /// file there, a Markdown file in its source.
    func testFilesAreFoundByNameAndByWhatIsInThem() throws {
        try write("one\ntwo\nthe needle is here\nfour\n", to: "Sources/deep/haystack.txt")
        app.wait(for: .text("project, folder"), timeout: 15)
        app.menu(["File", "Go to File…"])
        app.wait(for: .id("search-field"))
        app.wait(for: .containing("Type part of a file's name."))
        app.write("hayst", into: .id("search-field"))
        app.wait(for: .id("found-Sources/deep/haystack.txt"))
        XCTAssertFalse(app.exists(.id("found-notes.txt")))
        shot("names")
        app.press(.id("found-Sources/deep/haystack.txt"))
        let editor = MacDriver.Query.role(kAXTextAreaRole as String)
        wait("the file in the editor") { self.app.value(of: editor) == "one\ntwo\nthe needle is here\nfour\n" }

        // By what is in them: the same field, the other way.
        app.menu(["File", "Find in Files…"])
        app.write("Needle", into: .id("search-field"))
        app.wait(for: .id("match-Sources/deep/haystack.txt:3"))
        app.wait(for: .containing("1 line in 1 file."))
        // With its case it is not there.
        app.press(.id("search-case"))
        app.wait(for: .containing("Nothing found."))
        app.press(.id("search-case"))
        app.wait(for: .id("match-Sources/deep/haystack.txt:3"))

        // A word of the Markdown file: it opens in its source, at the line.
        app.write("Some words", into: .id("search-field"))
        app.wait(for: .id("match-docs/guide.md:3"))
        shot("text")
        app.press(.id("match-docs/guide.md:3"))
        wait("the Markdown file's source") { self.app.value(of: editor) == "# Guide\n\nSome words.\n" }

        // Closed, the tree is back.
        app.press(.button("Close Search"))
        app.wait(for: .button("notes.txt"))
    }

    /// FILE-9: a text file over the size it is opened at by itself says so,
    /// and opens when asked.
    func testALargeTextFileOpensWhenAsked() throws {
        let line = "a line of a long log\n"
        try write(String(repeating: line, count: 3 * 1024 * 1024 / line.utf8.count), to: "big.log")
        app.press(.button("Files"))
        app.wait(for: .button("notes.txt"))
        // Written after the list was read: looked at again.
        app.press(.button("Refresh"))
        app.press(.button("big.log"), timeout: 15)
        app.wait(for: .containing("too large to open by itself"))
        app.press(.id("open-anyway"))
        let editor = MacDriver.Query.role(kAXTextAreaRole as String)
        wait("the file's text in the editor", timeout: 20) { self.app.value(of: editor)?.hasPrefix("a line of a long log\n") == true }
        XCTAssertFalse(app.exists(.containing("too large to open by itself")))
    }

    func testFilesChangedFromAnotherDeviceShowHere() throws {
        let phone = try device()
        app.press(.button("Files"))
        app.wait(for: .button("notes.txt"))
        // FILE-8: a file made on the phone shows in the Mac's tree.
        phone.send(.createFile(directory: project.path, name: "from-the-phone.txt", isDirectory: false))
        wait("the file on disk") { FileManager.default.fileExists(atPath: self.project.appendingPathComponent("from-the-phone.txt").path) }
        app.press(.button("Refresh"))
        app.wait(for: .button("from-the-phone.txt"), timeout: 15)
        // And what the phone wrote into a file is what the Mac opens.
        phone.send(.writeFile(path: project.appendingPathComponent("from-the-phone.txt").path, text: "written on the phone\n"))
        wait("the text on disk") { self.read("from-the-phone.txt") == "written on the phone\n" }
        app.press(.button("from-the-phone.txt"))
        wait("the phone's text in the editor") { self.app.value(of: .role(kAXTextAreaRole as String)) == "written on the phone\n" }
    }
}
