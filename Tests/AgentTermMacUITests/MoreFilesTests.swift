import AgentTermProtocol
import XCTest

/// Making, renaming and removing files, and the kinds of file that are not plain text.
final class MoreFilesTests: MacUITestCase {
    override func makeFixtures() throws {
        try super.makeFixtures()
        try write("# Guide\n\nSome words.\n\n```mermaid\ngraph TD; A-->B;\n```\n", to: "docs/guide.md")
        // The smallest picture there is: one pixel.
        let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        try XCTUnwrap(Data(base64Encoded: pixel)).write(to: project.appendingPathComponent("pixel.png"))
        try Data([0, 159, 146, 150, 255, 254, 0, 1]).write(to: project.appendingPathComponent("blob.bin"))
        try String(repeating: "0123456789abcdef\n", count: 140_000).write(to: project.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
    }

    /// A file's row in the tree, as apart from its tab.
    private func row(_ name: String) -> MacDriver.Query { .idEnding("/project/" + name) }

    func testMakingRenamingAndRemovingFiles() throws {
        app.press(.button("Files"))
        app.wait(for: .button("notes.txt"))
        // FILE-2: a new file, which opens.
        app.press(.button("New file"))
        app.write("made-here.txt", into: .role(kAXTextFieldRole as String))
        app.press(.button("Create"))
        wait("the file on disk") { FileManager.default.fileExists(atPath: self.project.appendingPathComponent("made-here.txt").path) }
        app.wait(for: .button("made-here.txt"))
        // A name that is taken is refused, and nothing is overwritten.
        app.press(.button("New file"))
        app.write("notes.txt", into: .role(kAXTextFieldRole as String))
        app.press(.button("Create"))
        app.wait(for: .button("OK"))
        XCTAssertEqual(read("notes.txt"), "first line\nsecond line\n", "a file was overwritten by one of the same name")
        app.press(.button("OK"))
        // A new folder.
        app.press(.button("New folder"))
        app.write("assets", into: .role(kAXTextFieldRole as String))
        app.press(.button("Create"))
        var isDirectory: ObjCBool = false
        wait("the folder on disk") { FileManager.default.fileExists(atPath: self.project.appendingPathComponent("assets").path, isDirectory: &isDirectory) }
        XCTAssertTrue(isDirectory.boolValue)
        // Renamed.
        app.perform("Rename", on: row("made-here.txt"))
        app.write("renamed.txt", into: .role(kAXTextFieldRole as String))
        app.press(.button("Rename"))
        wait("the new name on disk") { FileManager.default.fileExists(atPath: self.project.appendingPathComponent("renamed.txt").path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("made-here.txt").path))
        // Moved to the Trash, after asking.
        app.perform("Move to Trash", on: row("renamed.txt"))
        app.press(.button("Move to Trash"))
        wait("the file gone from the project") { !FileManager.default.fileExists(atPath: self.project.appendingPathComponent("renamed.txt").path) }
        app.waitGone(row("renamed.txt"))
    }

    func testFilesThatAreNotPlainText() throws {
        app.press(.button("Files"))
        app.wait(for: .button("notes.txt"))
        // FILE-5: a picture is shown.
        app.press(.button("pixel.png"))
        app.wait(for: .role(kAXImageRole as String), timeout: 10)
        // What is not text says so, and so does what is too large.
        app.press(.button("blob.bin"))
        app.wait(for: .containing("This file is not text"))
        app.press(.button("big.txt"))
        app.wait(for: .containing("too large to open by itself"))
        // FILE-4: Markdown opens as a preview, with its source one switch away.
        app.press(.button("docs, folder, collapsed"))
        app.press(.button("guide.md"))
        app.wait(for: .text("Some words."), timeout: 15)
        XCTAssertFalse(app.exists(.role(kAXTextAreaRole as String)), "a Markdown file opened as its source")
        app.press(.button("Edit"))
        wait("the source") { self.app.value(of: .role(kAXTextAreaRole as String))?.hasPrefix("# Guide") ?? false }
    }
}
