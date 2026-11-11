@testable import AgenttyHost
import XCTest

final class ParsingTests: XCTestCase {
    func testAgentDetectionOutput() {
        let output = """
        some shell startup noise
        AGENTTY_AGENT:claude=/Users/me/.local/bin/claude
        AGENTTY_AGENT:codex=
        AGENTTY_AGENT:agy=/opt/homebrew/bin/agy
        """
        let agents = AgentDetector.parse(output)
        XCTAssertEqual(agents.map(\.id), ["claude", "codex", "agy", "copilot"])
        XCTAssertEqual(agents[0].path, "/Users/me/.local/bin/claude")
        XCTAssertFalse(agents[1].isInstalled)
        XCTAssertTrue(agents[2].isInstalled)
        XCTAssertFalse(agents[3].isInstalled, "an agent missing from the output is not installed")
    }

    func testDiffIsSplitPerFile() {
        let text = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,3 +1,4 @@
         import Foundation
        -let a = 1
        +let a = 2
        +let b = 3
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        index 3333333..0000000
        --- a/old.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
        diff --git a/logo.png b/logo.png
        index 4444444..5555555 100644
        Binary files a/logo.png and b/logo.png differ

        """
        let files = GitDiff.parse(text)
        XCTAssertEqual(files.map(\.path), ["Sources/App.swift", "old.txt", "logo.png"])
        XCTAssertEqual(files[0].added, 2)
        XCTAssertEqual(files[0].deleted, 1)
        XCTAssertTrue(files[0].patch.hasPrefix("@@ -1,3 +1,4 @@"))
        XCTAssertEqual(files[1].added, 0)
        XCTAssertEqual(files[1].deleted, 2)
        XCTAssertEqual(files[2].patch, "Binary file changed")
    }

    func testEmptyDiff() {
        XCTAssertTrue(GitDiff.parse("").isEmpty)
    }

    func testSnapshotOfARealRepository() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentty-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(GitDiff.snapshot(directory: directory.path).isRepository)

        func git(_ arguments: String...) {
            _ = Subprocess.run("/usr/bin/git", ["-C", directory.path, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments)
        }
        git("init", "-q", "-b", "main")
        try "one\ntwo\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        git("add", ".")
        git("commit", "-q", "-m", "init")
        try "one\n2\nthree\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "xin chào\n".write(to: directory.appendingPathComponent("tiếng việt.txt"), atomically: true, encoding: .utf8)

        let snapshot = GitDiff.snapshot(directory: directory.path)
        XCTAssertTrue(snapshot.isRepository)
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(snapshot.files.map(\.path), ["tracked.txt", "tiếng việt.txt"])
        XCTAssertEqual(snapshot.files[0].added, 2)
        XCTAssertEqual(snapshot.files[0].deleted, 1)
        XCTAssertTrue(snapshot.files[1].isUntracked)
        XCTAssertEqual(snapshot.files[1].added, 1)
        XCTAssertTrue(snapshot.files[1].patch.contains("+xin chào"))
    }

    private func file(_ path: String, added: Int = 1, deleted: Int = 0) -> FileDiff {
        FileDiff(path: path, added: added, deleted: deleted, isUntracked: false, patch: "")
    }

    func testTreeGroupsFilesByFolder() {
        let files = [
            file("README.md", added: 2),
            file("Sources/AgenttyHost/GitDiff.swift", added: 3, deleted: 1),
            file("Sources/AgenttyHost/DiffTree.swift", added: 10),
            file("Sources/AgenttyMac/DiffView.swift", added: 5, deleted: 4),
            file("docs/guide/deep/notes.md"),
        ]
        let rows = DiffTree.rows(for: files)
        XCTAssertEqual(rows.map(\.id), [
            "docs/guide/deep/",
            "docs/guide/deep/notes.md",
            "Sources/",
            "Sources/AgenttyHost/",
            "Sources/AgenttyHost/DiffTree.swift",
            "Sources/AgenttyHost/GitDiff.swift",
            "Sources/AgenttyMac/",
            "Sources/AgenttyMac/DiffView.swift",
            "README.md",
        ])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0, 1, 2, 2, 1, 2, 0])
        // A chain of single folders is one row.
        XCTAssertEqual(rows[0].name, "docs/guide/deep")
        // Folders total what is inside them.
        XCTAssertEqual(rows[2].added, 18)
        XCTAssertEqual(rows[2].deleted, 5)
        XCTAssertEqual(rows[3].added, 13)
        XCTAssertEqual(rows.last?.name, "README.md")
    }

    func testCollapsedFoldersHideTheirContents() {
        let files = [file("a/one.txt"), file("a/b/two.txt"), file("c/three.txt")]
        let rows = DiffTree.rows(for: files, collapsed: ["a/"])
        XCTAssertEqual(rows.map(\.id), ["a/", "c/", "c/three.txt"])
        XCTAssertEqual(rows[0].kind, .folder(expanded: false))
        XCTAssertEqual(rows[0].added, 2, "a collapsed folder still shows its totals")
        XCTAssertEqual(rows[1].kind, .folder(expanded: true))
    }

    func testTreeOfRootFilesIsFlat() {
        let rows = DiffTree.rows(for: [file("b.txt"), file("a.txt"), file("a10.txt"), file("a2.txt")])
        XCTAssertEqual(rows.map(\.id), ["a.txt", "a2.txt", "a10.txt", "b.txt"])
        XCTAssertTrue(rows.allSatisfy { $0.depth == 0 })
    }

    func testTailscaleStatus() {
        func status(_ installed: Bool, _ state: String?, _ address: String?, _ name: String? = nil) -> TailscaleStatus {
            Tailscale.status(installed: installed, backendState: state, address: address, dnsName: name)
        }
        XCTAssertEqual(status(false, nil, nil), .notInstalled)
        XCTAssertEqual(status(true, "NeedsLogin", nil), .needsLogin)
        XCTAssertEqual(status(true, "Stopped", nil), .notConnected)
        XCTAssertEqual(status(true, "Starting", nil), .notConnected)
        XCTAssertEqual(status(true, nil, nil), .notConnected, "installed, CLI gave nothing, no address")
        XCTAssertEqual(status(true, "Running", nil), .notConnected, "running without an address yet")
        XCTAssertEqual(status(true, "Stopped", "100.64.0.1"), .notConnected, "a stale address does not count when it is switched off")
        XCTAssertEqual(status(true, "Running", "100.101.102.103", "macbook.tail1234.ts.net."), .ready(host: "macbook.tail1234.ts.net"))
        XCTAssertEqual(status(true, "Running", "100.101.102.103", ""), .ready(host: "100.101.102.103"))
        XCTAssertEqual(status(false, nil, "100.101.102.103"), .ready(host: "100.101.102.103"), "an address proves it works even if the app was not found")
    }
}
