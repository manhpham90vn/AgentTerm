#if os(macOS)
import Darwin
import Foundation

/// Where the host keeps its files and how it starts user programs.
public enum HostEnvironment {
    /// Token, folder list and log live here. `AGENTTY_STATE_DIR` moves them,
    /// which keeps test runs away from the real pairing.
    public static var supportDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["AGENTTY_STATE_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Agentty", isDirectory: true)
    }

    public static var tokenFile: URL { supportDirectory.appendingPathComponent("token") }

    public static var devicesFile: URL { supportDirectory.appendingPathComponent("devices.json") }

    public static var foldersFile: URL { supportDirectory.appendingPathComponent("folders.json") }

    public static var homeDirectory: String { NSHomeDirectory() }

    /// The user's login shell.
    public static var shell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    /// Environment for programs running inside a session.
    public static func sessionEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Agentty"
        env["SHELL"] = shell
        env["HOME"] = homeDirectory
        // A UTF-8 locale is required for Vietnamese and other non-ASCII input
        // to round-trip. GUI-launched processes often have no locale at all.
        let hasUTF8 = ["LC_ALL", "LC_CTYPE", "LANG"].contains { env[$0]?.uppercased().contains("UTF-8") == true }
        if !hasUTF8 {
            env["LANG"] = "en_US.UTF-8"
            env["LC_CTYPE"] = "en_US.UTF-8"
        }
        return env
    }

    /// Arguments that start `command` through the login shell, or a plain
    /// login shell when `command` is nil. Going through the shell gives the
    /// program the same PATH the user has in a regular terminal.
    public static func shellArguments(command: String?) -> [String] {
        let name = (shell as NSString).lastPathComponent
        guard let command, !command.isEmpty else { return ["-" + name] }
        return [name, "-l", "-i", "-c", command]
    }

    /// Returns the Mac's own token, creating it on first use. It lets apps on
    /// this Mac talk to the host and is never given to another device. The
    /// file is readable by the user only.
    public static func loadOrCreateToken() throws -> String {
        let fm = FileManager.default
        if let data = fm.contents(atPath: tokenFile.path),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           token.count >= 32 {
            return token
        }
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let token = DeviceRegistry.randomToken()
        guard fm.createFile(atPath: tokenFile.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return token
    }
}

/// Runs a short helper command and returns its standard output.
enum Subprocess {
    static func run(_ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 10) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Read before waiting so a full pipe cannot stall the child.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return (process.terminationStatus, output)
    }
}
#endif
