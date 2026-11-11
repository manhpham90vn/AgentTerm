@testable import AgenttyHost
import XCTest

final class FileBrowserTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentty-files-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    func testListingPutsFoldersFirstAndLeavesOutGitData() throws {
        for folder in ["src", ".git", "Docs"] { try FileManager.default.createDirectory(atPath: path(folder), withIntermediateDirectories: true) }
        for file in ["b.txt", "a10.txt", "a2.txt", ".env", ".DS_Store"] { FileManager.default.createFile(atPath: path(file), contents: Data()) }
        let entries = FileBrowser.list(root.path)
        XCTAssertEqual(entries.map(\.name), ["Docs", "src", ".env", "a2.txt", "a10.txt", "b.txt"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, true, false, false, false, false])
        XCTAssertTrue(FileBrowser.list("/nonexistent/place").isEmpty)
    }

    func testCreateWriteReadRoundTrip() throws {
        let file = try FileBrowser.createFile(named: " ghi chú.md ", in: root.path)
        XCTAssertEqual(file, path("ghi chú.md"))
        XCTAssertEqual(FileBrowser.read(file), .text(""))
        try FileBrowser.write("# Tiêu đề\nnội dung\n", to: file)
        XCTAssertEqual(FileBrowser.read(file), .text("# Tiêu đề\nnội dung\n"))

        let folder = try FileBrowser.createFolder(named: "mới", in: root.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    func testNamesAreCheckedAndNothingIsOverwritten() throws {
        try FileBrowser.createFile(named: "a.txt", in: root.path)
        try FileBrowser.write("keep me", to: path("a.txt"))
        XCTAssertThrowsError(try FileBrowser.createFile(named: "a.txt", in: root.path)) { XCTAssertEqual($0 as? FileBrowserError, .alreadyExists("a.txt")) }
        XCTAssertThrowsError(try FileBrowser.createFolder(named: "a.txt", in: root.path))
        XCTAssertEqual(FileBrowser.read(path("a.txt")), .text("keep me"))
        for bad in ["", "  ", ".", "..", "a/b", "../escape"] {
            XCTAssertThrowsError(try FileBrowser.createFile(named: bad, in: root.path), bad)
            XCTAssertFalse(FileBrowser.isValidName(bad), bad)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    func testRenameKeepsContentAndRefusesATakenName() throws {
        try FileBrowser.createFile(named: "old.txt", in: root.path)
        try FileBrowser.write("content", to: path("old.txt"))
        try FileBrowser.createFile(named: "taken.txt", in: root.path)

        XCTAssertThrowsError(try FileBrowser.rename(path("old.txt"), to: "taken.txt"))
        XCTAssertEqual(try FileBrowser.rename(path("old.txt"), to: "old.txt"), path("old.txt"), "the same name is not a change")
        let renamed = try FileBrowser.rename(path("old.txt"), to: "new.txt")
        XCTAssertEqual(renamed, path("new.txt"))
        XCTAssertEqual(FileBrowser.read(renamed), .text("content"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("old.txt")))

        try FileManager.default.createDirectory(atPath: path("dir/inner"), withIntermediateDirectories: true)
        XCTAssertEqual(try FileBrowser.rename(path("dir"), to: "moved"), path("moved"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("moved/inner")))
    }

    func testWhatCannotBeEditedIsToldApart() throws {
        FileManager.default.createFile(atPath: path("data.bin"), contents: Data([0x00, 0x01, 0xff, 0xfe]))
        XCTAssertEqual(FileBrowser.read(path("data.bin")), .binary)
        FileManager.default.createFile(atPath: path("latin1.txt"), contents: Data([0x63, 0x61, 0x66, 0xe9]))
        XCTAssertEqual(FileBrowser.read(path("latin1.txt")), .binary, "not UTF-8")
        FileManager.default.createFile(atPath: path("logo.PNG"), contents: Data([0x89, 0x50]))
        XCTAssertEqual(FileBrowser.read(path("logo.PNG")), .image)
        FileManager.default.createFile(atPath: path("big.log"), contents: Data(count: FileBrowser.maxTextBytes + 1))
        XCTAssertEqual(FileBrowser.read(path("big.log")), .tooLarge(bytes: FileBrowser.maxTextBytes + 1))
        XCTAssertEqual(FileBrowser.read(path("missing.txt")), .binary)
    }
}
