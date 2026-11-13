#if os(macOS)
import CoreServices
import Foundation

/// Calls back when anything changes in a folder or below it, a few tenths
/// of a second after, once for a burst of changes (FSEvents). What the side
/// panel shows is read again then, rather than on a timer (#21). A git
/// repository's own folder, which may be elsewhere (a worktree's), is
/// watched with it, so that staging from a terminal is seen too.
public final class FolderWatch {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    /// - Parameter latency: How long a burst of changes is gathered for.
    public init?(paths: [String], latency: TimeInterval = 0.3, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot))
        else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    /// The folder and, for a git repository, git's own folder for it.
    public static func paths(for folder: String) -> [String] {
        var paths = [folder]
        if let result = Subprocess.run("/usr/bin/git", ["-C", folder, "rev-parse", "--absolute-git-dir"], timeout: 5), result.status == 0 {
            let gitDirectory = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !gitDirectory.isEmpty, !gitDirectory.hasPrefix(folder + "/") { paths.append(gitDirectory) }
        }
        return paths
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
#endif
