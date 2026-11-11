#if os(macOS)
import Foundation

/// One file or folder in a listing.
public struct FileEntry: Identifiable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var isDirectory: Bool

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// What a file turned out to hold when it was opened.
public enum FileContent: Equatable, Sendable {
    case text(String)
    /// An image the system can draw. The viewer loads it from the path.
    case image
    /// Not text in UTF-8, so not something to edit here.
    case binary
    case tooLarge(bytes: Int)
}

public enum FileBrowserError: Error, Equatable, CustomStringConvertible {
    case invalidName(String)
    case alreadyExists(String)
    case failed(String)

    public var description: String {
        switch self {
        case .invalidName(let name): return name.isEmpty ? "Enter a name." : "\"\(name)\" cannot be used as a name."
        case .alreadyExists(let name): return "\"\(name)\" already exists here."
        case .failed(let reason): return reason
        }
    }
}

/// Looks at and changes the files of a project folder: what the Files tab does.
public enum FileBrowser {
    /// Files larger than this are not opened in the editor.
    public static let maxTextBytes = 2 * 1024 * 1024

    /// Never listed: git's own data and Finder's litter.
    private static let skipped: Set<String> = [".git", ".DS_Store"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "icns", "ico", "pdf"]

    /// The contents of a folder, folders first, by name. Dot files are
    /// listed, since a project's settings live in them.
    public static func list(_ directory: String) -> [FileEntry] {
        let url = URL(fileURLWithPath: directory)
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return urls.compactMap { item -> FileEntry? in
            let name = item.lastPathComponent
            guard !skipped.contains(name) else { return nil }
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return FileEntry(path: item.path, name: name, isDirectory: isDirectory)
        }
        .sorted { a, b in
            a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public static func read(_ path: String) -> FileContent {
        let url = URL(fileURLWithPath: path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if imageExtensions.contains(url.pathExtension.lowercased()) { return .image }
        guard size <= maxTextBytes else { return .tooLarge(bytes: size) }
        guard let data = try? Data(contentsOf: url) else { return .binary }
        // A zero byte does not occur in text, and decides quickly for most binaries.
        guard !data.prefix(8192).contains(0), let text = String(data: data, encoding: .utf8) else { return .binary }
        return .text(text)
    }

    public static func write(_ text: String, to path: String) throws {
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw FileBrowserError.failed(error.localizedDescription)
        }
    }

    /// Creates an empty file and returns its path.
    @discardableResult
    public static func createFile(named name: String, in directory: String) throws -> String {
        let path = try freePath(for: name, in: directory)
        guard FileManager.default.createFile(atPath: path, contents: Data()) else {
            throw FileBrowserError.failed("Could not create \"\(name)\".")
        }
        return path
    }

    @discardableResult
    public static func createFolder(named name: String, in directory: String) throws -> String {
        let path = try freePath(for: name, in: directory)
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        } catch {
            throw FileBrowserError.failed(error.localizedDescription)
        }
        return path
    }

    /// Gives a file or folder another name in the same place. Returns the new path.
    @discardableResult
    public static func rename(_ path: String, to name: String) throws -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (path as NSString).lastPathComponent else { return path }
        let target = try freePath(for: name, in: directory)
        do {
            try FileManager.default.moveItem(atPath: path, toPath: target)
        } catch {
            throw FileBrowserError.failed(error.localizedDescription)
        }
        return target
    }

    /// Moves a file or folder to the Trash, where it can be put back from.
    public static func trash(_ path: String) throws {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            throw FileBrowserError.failed(error.localizedDescription)
        }
    }

    /// A name is one path component: no slashes, not "." or "..".
    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/") && !trimmed.contains("\0") && trimmed.utf8.count <= 255
    }

    private static func freePath(for name: String, in directory: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(trimmed) else { throw FileBrowserError.invalidName(trimmed) }
        let path = (directory as NSString).appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: path) else { throw FileBrowserError.alreadyExists(trimmed) }
        return path
    }
}
#endif
