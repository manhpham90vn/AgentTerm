#if os(macOS)
import Foundation

/// One visible row of the changes list when it is shown as a folder tree.
public struct DiffTreeRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case folder(expanded: Bool)
        case file(FileDiff)
    }

    /// The full path. Folders end in "/", so a folder and a file never clash.
    public var id: String
    public var name: String
    public var depth: Int
    public var added: Int
    public var deleted: Int
    public var kind: Kind
}

/// Arranges changed files by folder, the way a file explorer would.
public enum DiffTree {
    private final class Node {
        var folders: [String: Node] = [:]
        var files: [FileDiff] = []
    }

    /// Flattens the tree into the rows to draw, skipping the contents of
    /// collapsed folders. Folders come before files, both sorted by name. A
    /// folder whose only content is another folder is merged with it
    /// ("Sources/AgenttyHost"), so deep paths do not cost one row per level.
    public static func rows(for files: [FileDiff], collapsed: Set<String> = []) -> [DiffTreeRow] {
        let root = Node()
        for file in files {
            var node = root
            for component in file.path.split(separator: "/").dropLast() {
                let name = String(component)
                if let next = node.folders[name] {
                    node = next
                } else {
                    let next = Node()
                    node.folders[name] = next
                    node = next
                }
            }
            node.files.append(file)
        }
        var rows: [DiffTreeRow] = []
        append(root, prefix: "", depth: 0, collapsed: collapsed, to: &rows)
        return rows
    }

    private static func append(_ node: Node, prefix: String, depth: Int, collapsed: Set<String>, to rows: inout [DiffTreeRow]) {
        for name in node.folders.keys.sorted(by: order) {
            var folder = node.folders[name]!
            var label = name
            while folder.files.isEmpty, folder.folders.count == 1, let only = folder.folders.first {
                label += "/" + only.key
                folder = only.value
            }
            let id = prefix + label + "/"
            let totals = totals(of: folder)
            let expanded = !collapsed.contains(id)
            rows.append(DiffTreeRow(id: id, name: label, depth: depth, added: totals.added, deleted: totals.deleted, kind: .folder(expanded: expanded)))
            if expanded {
                append(folder, prefix: id, depth: depth + 1, collapsed: collapsed, to: &rows)
            }
        }
        for file in node.files.sorted(by: { order(name(of: $0), name(of: $1)) }) {
            rows.append(DiffTreeRow(id: file.path, name: name(of: file), depth: depth, added: file.added, deleted: file.deleted, kind: .file(file)))
        }
    }

    private static func totals(of node: Node) -> (added: Int, deleted: Int) {
        var added = node.files.reduce(0) { $0 + $1.added }
        var deleted = node.files.reduce(0) { $0 + $1.deleted }
        for child in node.folders.values {
            let nested = totals(of: child)
            added += nested.added
            deleted += nested.deleted
        }
        return (added, deleted)
    }

    private static func name(of file: FileDiff) -> String {
        (file.path as NSString).lastPathComponent
    }

    private static func order(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}
#endif
