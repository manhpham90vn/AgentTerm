#if os(macOS)
import Foundation

/// The `PATH` the user's login shell has.
///
/// The host is started by the app or by launchd, so its own `PATH` is the
/// system's short one: nothing from Homebrew, nvm or whatever the user's
/// shell adds. Sessions do not mind, since they are started through that
/// shell. What the host runs itself does: git starts credential helpers,
/// hooks and `git-lfs` by name.
final class LoginShellPath: @unchecked Sendable {
    static let shared = LoginShellPath()

    private static let marker = "AGENTTERM_PATH:"

    private let shell: () -> String
    private let lock = NSLock()
    private var asked = false
    private var known: String?

    /// - Parameter shell: the program asked, the user's login shell unless a
    ///   test stands another in for it.
    init(shell: @escaping () -> String = { HostEnvironment.shell }) {
        self.shell = shell
    }

    /// The shell's `PATH`, asked for once and kept. Nil when the shell did
    /// not say. The first call blocks for as long as the shell takes to start.
    func value() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if !asked {
            known = ask()
            asked = true
        }
        return known
    }

    /// Asks again, since a tool may have been installed since. True when the
    /// answer is another one than before.
    func refresh() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = asked ? known : nil
        let found = ask()
        asked = true
        // A shell that fails to answer once does not take away what is known.
        if let found { known = found }
        return found != nil && found != before
    }

    private func ask() -> String? {
        // Interactive too, as sessions are: what the user adds to PATH is
        // often in the file only an interactive shell reads.
        let script = "printf '\(Self.marker)%s\\n' \"$PATH\""
        guard let result = Subprocess.run(shell(), ["-l", "-i", "-c", script], cwd: HostEnvironment.homeDirectory, timeout: 8) else { return nil }
        return Self.parse(String(decoding: result.output, as: UTF8.self))
    }

    /// The path in what the shell printed, which may hold anything else the
    /// user's startup files print.
    static func parse(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let range = line.range(of: marker) else { continue }
            let path = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
        return nil
    }
}
#endif
