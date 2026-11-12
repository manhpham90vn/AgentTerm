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
