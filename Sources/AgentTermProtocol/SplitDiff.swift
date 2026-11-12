import Foundation

/// One row of a diff shown as two panels: what the file was on the left,
/// what it is now on the right.
public struct SplitDiffRow: Identifiable, Equatable, Sendable {
    /// One side of a row: a line of the file with its number.
    public struct Line: Equatable, Sendable {
        public var number: Int
        public var text: String
        /// True for a line that was removed (left) or added (right).
        public var changed: Bool

        public init(number: Int, text: String, changed: Bool) {
            self.number = number
            self.text = text
            self.changed = changed
        }
    }

    public var id: Int
    /// The hunk header ("@@ -1,4 +1,6 @@ func name") for a row that starts a hunk.
    public var hunk: String?
    /// Nil where the other side has a line this side has none for.
    public var left: Line?
    public var right: Line?

    public init(id: Int, hunk: String? = nil, left: Line? = nil, right: Line? = nil) {
        self.id = id
        self.hunk = hunk
        self.left = left
        self.right = right
    }
}

/// Lays a unified diff out as two panels.
public enum SplitDiff {
    /// The rows for a patch that starts at its first hunk header, which is
    /// how `FileDiff.patch` holds it. Lines the two sides share are on one
    /// row. A run of removed lines followed by added ones is paired line by
    /// line, since that is a change to those lines; what one side has more
    /// of stands alone, facing an empty row.
    public static func rows(for patch: String, limit: Int = .max) -> [SplitDiffRow] {
        var rows: [SplitDiffRow] = []
        var removed: [SplitDiffRow.Line] = []
        var added: [SplitDiffRow.Line] = []
        var leftNumber = 0
        var rightNumber = 0
        var inHunk = false

        func flush() {
            for index in 0..<max(removed.count, added.count) {
                rows.append(SplitDiffRow(id: rows.count, left: index < removed.count ? removed[index] : nil, right: index < added.count ? added[index] : nil))
            }
            removed = []
            added = []
        }

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if rows.count >= limit { break }
            if line.hasPrefix("@@") {
                flush()
                // "@@ -12,7 +12,9 @@": where the hunk starts on each side.
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    leftNumber = start(of: parts[1])
                    rightNumber = start(of: parts[2])
                }
                rows.append(SplitDiffRow(id: rows.count, hunk: String(line)))
                inHunk = true
            } else if line.hasPrefix("-") {
                // Removed lines after added ones start a new change.
                if !added.isEmpty { flush() }
                removed.append(.init(number: leftNumber, text: String(line.dropFirst()), changed: true))
                leftNumber += 1
            } else if line.hasPrefix("+") {
                added.append(.init(number: rightNumber, text: String(line.dropFirst()), changed: true))
                rightNumber += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file" is about the line before it.
                continue
            } else if line.isEmpty, !inHunk || line.endIndex == patch.endIndex {
                // Nothing to show: a blank outside a hunk, or the empty last
                // element of a patch that ends in a newline.
                continue
            } else if line.hasPrefix(" ") || line.isEmpty {
                flush()
                let text = String(line.dropFirst())
                rows.append(
                    SplitDiffRow(
                        id: rows.count, left: .init(number: leftNumber, text: text, changed: false),
                        right: .init(number: rightNumber, text: text, changed: false)))
                leftNumber += 1
                rightNumber += 1
            } else {
                // Not a diff line: a note such as "Binary file changed".
                flush()
                rows.append(SplitDiffRow(id: rows.count, hunk: String(line)))
            }
        }
        flush()
        return limit < rows.count ? Array(rows.prefix(limit)) : rows
    }

    /// The first line number in "-12,7" or "+12".
    private static func start(of range: Substring) -> Int {
        Int(range.dropFirst().split(separator: ",").first ?? "") ?? 0
    }
}
