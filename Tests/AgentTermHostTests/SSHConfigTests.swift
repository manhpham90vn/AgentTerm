import XCTest

@testable import AgentTermHost

final class SSHConfigTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-ssh-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh/conf.d"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(to: home.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func testHostsAreReadInOrderWithoutPatterns() throws {
        try write(
            ".ssh/config",
            """
            # My servers
            Host build
                HostName 10.0.0.5
                User ci
                IdentityFile ~/.ssh/id_build

            host web-1 web_2.example.com
              # Host commented-out
            Host *.internal !bastion ?x
                ProxyJump bastion
            Host=equals
            Host "quoted"   build
            Host *
                ServerAliveInterval 30
            Match host something
            """)
        XCTAssertEqual(SSHConfig.hosts(home: home.path), ["build", "web-1", "web_2.example.com", "equals", "quoted"])
    }

    func testIncludesAreFollowed() throws {
        try write(".ssh/config", "Include conf.d/*.conf\nInclude ~/extra\nInclude \(home.path)/absolute missing-file\nHost last\n")
        try write(".ssh/conf.d/b.conf", "Host from-b\n")
        try write(".ssh/conf.d/a.conf", "Host from-a\nInclude ../config\n")
        try write(".ssh/conf.d/skipped.txt", "Host not-included\n")
        try write("extra", "Host extra\n")
        try write("absolute", "Host absolute\n")
        XCTAssertEqual(SSHConfig.hosts(home: home.path), ["from-a", "from-b", "extra", "absolute", "last"])
    }

    func testNamesThatAreNotPlainAreLeftOut() throws {
        try write(".ssh/config", "Host ok -oProxyCommand=evil a;b $(x) user@host tên\nHost fine.example\n")
        XCTAssertEqual(SSHConfig.hosts(home: home.path), ["ok", "fine.example"])
        XCTAssertFalse(SSHConfig.isSafeHost("-oProxyCommand=evil"))
        XCTAssertFalse(SSHConfig.isSafeHost("a b"))
    }

    func testNoConfigurationMeansNoHosts() {
        XCTAssertEqual(SSHConfig.hosts(home: home.path), [])
    }
}
