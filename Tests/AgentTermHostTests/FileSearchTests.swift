import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// Finding files by name and lines by what is in them (#45).
final class FileSearchTests: XCTestCase {
    private var root: URL!
    private var project: URL { root.appendingPathComponent("project") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-search-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for name in ["GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"] { unsetenv(name) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func git(_ arguments: String..., in directory: URL? = nil) -> String {
        let result = Subprocess.run("/usr/bin/git", ["-C", (directory ?? project).path] + arguments, timeout: 60, mergeErrors: true)
        return String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ path: String, _ text: String, in directory: URL? = nil) throws {
        let url = (directory ?? project).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func repository(_ directory: URL? = nil) {
        git("init", "-q", "-b", "main", in: directory)
        git("config", "user.name", "Test", in: directory)
        git("config", "user.email", "test@example.com", in: directory)
        git("config", "commit.gpgsign", "false", in: directory)
    }

    /// Every line found, as "file:line: text".
    private func search(_ query: String, caseSensitive: Bool = false, limit: Int = FileSearch.maxMatches, in directory: URL? = nil) -> (lines: [String], ending: FileSearch.Ending) {
        var lines: [String] = []
        let ending = FileSearch.text(query, in: (directory ?? project).path, caseSensitive: caseSensitive, limit: limit, isCancelled: { false }) { matches in
            lines += matches.map { "\($0.file):\($0.line): \($0.text)" }
        }
        return (lines.sorted(), ending)
    }

    /// FIND-1: the files of a repository are what git tracks and what it
    /// does not track and does not ignore; not `.git`, not AgentTerm's own
    /// folder, not a file that was deleted.
    func testTheFilesOfARepositoryLeaveOutWhatGitIgnores() throws {
        repository()
        try write("README.md", "read me\n")
        try write("Sources/App/Main.swift", "print(1)\n")
        try write("Sources/App/Gone.swift", "gone\n")
        try write(".gitignore", "build/\n*.log\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        try write("Sources/App/New.swift", "new\n")
        try write("build/out.o", "object\n")
        try write("debug.log", "log\n")
        try write(".agentterm/handoffs/x.md", "handoff\n")
        try FileManager.default.removeItem(at: project.appendingPathComponent("Sources/App/Gone.swift"))

        XCTAssertEqual(FileSearch.files(in: project.path).sorted(), [".gitignore", "README.md", "Sources/App/Main.swift", "Sources/App/New.swift"])
        // From a folder inside it, named from there.
        XCTAssertEqual(FileSearch.files(in: project.appendingPathComponent("Sources").path).sorted(), ["App/Main.swift", "App/New.swift"])
    }

    /// FIND-2: a folder that is no repository is walked, without `.git`
    /// and AgentTerm's folder.
    func testTheFilesOfAFolderThatIsNoRepository() throws {
        try write("a.txt", "a\n")
        try write("deep/er/b.txt", "b\n")
        try write(".agentterm/x", "x\n")
        try write(".hidden", "h\n")
        XCTAssertEqual(FileSearch.files(in: project.path).sorted(), [".hidden", "a.txt", "deep/er/b.txt"])
    }

    /// FIND-3: files by name, best first: the name whole before its
    /// letters apart, the start of a word before its middle, the name
    /// before the folders, a query with a slash against the path.
    func testFilesAreRankedByHowWellTheirNameMatches() {
        let files = [
            "Sources/AgentTermHost/GitDiff.swift", "Sources/AgentTermMac/DiffView.swift", "Sources/AgentTermHost/HostServer.swift",
            "docs/DESIGN.md", "Tests/AgentTermHostTests/GitDiffTests.swift", "Sources/Different/unrelated.txt", "README.md",
        ]
        XCTAssertEqual(
            FileSearch.rank(files, query: "diff"),
            [
                "Sources/AgentTermMac/DiffView.swift", "Sources/AgentTermHost/GitDiff.swift", "Tests/AgentTermHostTests/GitDiffTests.swift",
                "Sources/Different/unrelated.txt",
            ], "the name that starts with it, the names that hold it, then the folder that does")
        XCTAssertEqual(FileSearch.rank(files, query: "GDS").first, "Sources/AgentTermHost/GitDiff.swift", "letters apart, in their order")
        XCTAssertEqual(FileSearch.rank(files, query: "hostserver"), ["Sources/AgentTermHost/HostServer.swift"])
        XCTAssertEqual(FileSearch.rank(files, query: "mac/diff"), ["Sources/AgentTermMac/DiffView.swift"])
        XCTAssertEqual(FileSearch.rank(files, query: "read me"), ["README.md"], "blanks are not letters")
        XCTAssertEqual(FileSearch.rank(files, query: "zzz"), [])
        XCTAssertEqual(FileSearch.rank(files, query: "  "), [])
        XCTAssertEqual(FileSearch.rank(files, query: "s", limit: 2).count, 2)
    }

    /// FIND-4: text in the files of a repository: each line with its file
    /// and number, case-sensitive or not, as written and not as a pattern;
    /// untracked files too; not what git ignores, binary files, or files
    /// larger than the editor opens.
    func testTextIsFoundInARepositorysFiles() throws {
        repository()
        try write("a.swift", "let total = 1\n    let Total = 2 // Total\nnothing\n")
        try write("docs/b.md", "The total is a.b (really)\n")
        try write(".gitignore", "ignored.txt\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
        try write("new.txt", "a total of three\n")
        try write("ignored.txt", "total ignored\n")
        try Data([0x74, 0x6F, 0x74, 0x61, 0x6C, 0x00, 0x01]).write(to: project.appendingPathComponent("binary.bin"))
        try write("large.txt", "total\n" + String(repeating: "x", count: FileBrowser.maxTextBytes))

        let found = search("total")
        XCTAssertEqual(found.lines, ["a.swift:1: let total = 1", "a.swift:2: let Total = 2 // Total", "docs/b.md:1: The total is a.b (really)", "new.txt:1: a total of three"])
        XCTAssertEqual(found.ending, FileSearch.Ending())
        XCTAssertEqual(search("Total", caseSensitive: true).lines, ["a.swift:2: let Total = 2 // Total"])
        // As written: a dot is a dot, a parenthesis a parenthesis.
        XCTAssertEqual(search("a.b (").lines, ["docs/b.md:1: The total is a.b (really)"])
        XCTAssertEqual(search("a.swift").lines, [])
        XCTAssertEqual(search("").lines, [])

        // Where the text is in the line, after the blanks in front were cut.
        var matches: [TextMatch] = []
        _ = FileSearch.text("Total", in: project.path, caseSensitive: true, isCancelled: { false }) { matches += $0 }
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(match.text, "let Total = 2 // Total")
        XCTAssertEqual(String(Array(match.text)[match.start..<match.start + match.length]), "Total")
        XCTAssertEqual(match.start, 4)
    }

    /// FIND-5: no more lines than the most that are given, and it says so;
    /// a search that is stopped ends without more.
    func testASearchStopsAtItsLimitAndWhenStopped() throws {
        repository()
        for index in 0..<30 { try write("f\(index).txt", String(repeating: "needle here\n", count: 10)) }
        let limited = search("needle", limit: 25)
        XCTAssertEqual(limited.lines.count, 25)
        XCTAssertTrue(limited.ending.truncated)
        XCTAssertFalse(search("needle", limit: 1000).ending.truncated)

        var count = 0
        let ending = FileSearch.text("needle", in: project.path, caseSensitive: false, isCancelled: { true }) { count += $0.count }
        XCTAssertEqual(count, 0)
        XCTAssertNil(ending.problem)
    }

    /// FIND-6: a very long line is cut to what is around the text.
    func testALongLineIsCutAroundTheText() throws {
        repository()
        try write("min.js", String(repeating: "a", count: 5000) + "NEEDLE" + String(repeating: "b", count: 5000) + "\n")
        var matches: [TextMatch] = []
        _ = FileSearch.text("NEEDLE", in: project.path, caseSensitive: true, isCancelled: { false }) { matches += $0 }
        let match = try XCTUnwrap(matches.first)
        XCTAssertLessThanOrEqual(match.text.count, FileSearch.maxLineLength + 2)
        XCTAssertTrue(match.text.hasPrefix("…") && match.text.hasSuffix("…"))
        XCTAssertEqual(String(Array(match.text)[match.start..<match.start + match.length]), "NEEDLE")
    }

    /// FIND-7: a folder that is no repository is searched too, the same way.
    func testTextIsFoundInAFolderThatIsNoRepository() throws {
        try write("a.txt", "one\n  Two words\nthree\n")
        try write("deep/b.txt", "two again\n")
        try write(".agentterm/x.txt", "two hidden\n")
        try Data([0x74, 0x77, 0x6F, 0x00]).write(to: project.appendingPathComponent("binary.bin"))
        XCTAssertEqual(search("two").lines, ["a.txt:2: Two words", "deep/b.txt:1: two again"])
        XCTAssertEqual(search("two", caseSensitive: true).lines, ["deep/b.txt:1: two again"])
        XCTAssertTrue(search("two", limit: 1).ending.truncated)
    }

    /// FIND-8: a submodule's files are the folder's: found by name and by
    /// what is in them, named from the folder.
    func testASubmodulesFilesAreSearchedToo() throws {
        setenv("GIT_CONFIG_COUNT", "1", 1)
        setenv("GIT_CONFIG_KEY_0", "protocol.file.allow", 1)
        setenv("GIT_CONFIG_VALUE_0", "always", 1)
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        repository(library)
        try write("lib.swift", "let inLibrary = true\n", in: library)
        git("add", ".", in: library)
        git("commit", "-q", "-m", "library", in: library)
        repository()
        try write("app.swift", "let inApp = true\n")
        git("submodule", "add", "-q", library.path, "libs/library")
        git("add", ".")
        git("commit", "-q", "-m", "init")

        XCTAssertEqual(FileSearch.files(in: project.path).sorted(), [".gitmodules", "app.swift", "libs/library/lib.swift"])
        XCTAssertEqual(search("= true").lines, ["app.swift:1: let inApp = true", "libs/library/lib.swift:1: let inLibrary = true"])
    }
}
