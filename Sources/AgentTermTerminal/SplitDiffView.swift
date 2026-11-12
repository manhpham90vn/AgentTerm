import AgentTermProtocol
import SwiftUI

/// A file's diff as two panels: what it was on the left, what it is now on
/// the right, changed lines facing each other. The two panels scroll down
/// together and sideways each on its own. Shared by the Mac and the iPhone.
public struct SplitDiffView: View {
    private let patch: String
    private let fontSize: CGFloat

    /// More rows than this are slow to lay out side by side.
    public static let maxRows = 2500

    public init(patch: String, fontSize: CGFloat = 11.5) {
        self.patch = patch
        self.fontSize = fontSize
    }

    public var body: some View {
        // The views around a diff are drawn again every few seconds: the
        // changes are read again, the Mac's figures arrive. A diff that is
        // the same as before is then left as it is, rather than worked out
        // and laid out again, thousands of rows each time.
        SplitDiffPanels(patch: patch, fontSize: fontSize).equatable()
    }
}

/// The two panels of one diff. Worked out from the patch when it is first
/// shown and when the patch or the font size changes, not before.
private struct SplitDiffPanels: View, Equatable {
    let patch: String
    let fontSize: CGFloat

    var body: some View {
        SplitDiffLayout(rows: Rows(patch: patch, fontSize: fontSize), fontSize: fontSize)
    }
}

/// A patch as the rows of the two panels, with how wide they are.
private struct Rows {
    let rows: [SplitDiffRow]
    let truncated: Bool
    /// Width in points of the longest line on each side.
    let leftWidth: CGFloat
    let rightWidth: CGFloat
    let numberWidth: CGFloat

    init(patch: String, fontSize: CGFloat) {
        let maxRows = SplitDiffView.maxRows
        // Tabs have no fixed width in SwiftUI text, which would put the columns off.
        let all = SplitDiff.rows(for: patch.replacingOccurrences(of: "\t", with: "    "), limit: maxRows + 1)
        truncated = all.count > maxRows
        let shown = Array(all.prefix(maxRows))
        rows = shown
        // A monospaced character is about six tenths of the font size wide.
        let character = fontSize * 0.602
        let digits = max(3, String(shown.reduce(0) { max($0, $1.left?.number ?? 0, $1.right?.number ?? 0) }).count)
        numberWidth = CGFloat(digits) * character + 14
        // The hunk headers are written on the left, so they count there.
        let longestLeft = shown.reduce(0) { max($0, $1.left?.text.count ?? 0, $1.hunk?.count ?? 0) }
        let longestRight = shown.reduce(0) { max($0, $1.right?.text.count ?? 0) }
        leftWidth = CGFloat(longestLeft + 2) * character
        rightWidth = CGFloat(longestRight + 2) * character
    }
}

private struct SplitDiffLayout: View {
    let content: Rows
    let fontSize: CGFloat

    private static let added = Color(red: 0.36, green: 0.80, blue: 0.52)
    private static let removed = Color(red: 0.96, green: 0.45, blue: 0.47)
    private static let hunk = Color(red: 0.55, green: 0.67, blue: 0.98)

    init(rows: Rows, fontSize: CGFloat) {
        content = rows
        self.fontSize = fontSize
    }

    private var rows: [SplitDiffRow] { content.rows }
    private var truncated: Bool { content.truncated }
    private var leftWidth: CGFloat { content.leftWidth }
    private var rightWidth: CGFloat { content.rightWidth }
    private var numberWidth: CGFloat { content.numberWidth }
    private var rowHeight: CGFloat { (fontSize * 1.45).rounded() }

    var body: some View {
        GeometryReader { viewport in
            let half = max(60, (viewport.size.width - 1) / 2)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    panel(\.left, hunks: true, width: half, content: leftWidth, tint: Self.removed)
                        .accessibilityIdentifier("split-diff-before")
                    Color.white.opacity(0.10).frame(width: 1)
                    panel(\.right, hunks: false, width: half, content: rightWidth, tint: Self.added)
                        .accessibilityIdentifier("split-diff-after")
                }
                .padding(.vertical, 6)
                if truncated {
                    Text("The rest of this diff is left out. Switch to one panel to see more.")
                        .font(.system(size: fontSize))
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
            }
        }
        .accessibilityIdentifier("split-diff")
    }

    /// One side: its lines with their numbers, as wide as its longest line
    /// and at least as wide as its half of the view.
    private func panel(_ side: KeyPath<SplitDiffRow, SplitDiffRow.Line?>, hunks: Bool, width: CGFloat, content: CGFloat, tint: Color) -> some View {
        let lineWidth = max(content, width - numberWidth)
        return ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    line(row, side: side, hunks: hunks, tint: tint)
                        .frame(width: numberWidth + lineWidth, height: rowHeight, alignment: .leading)
                        .background(background(row, side: side, tint: tint))
                }
            }
        }
        .frame(width: width)
    }

    @ViewBuilder
    private func line(_ row: SplitDiffRow, side: KeyPath<SplitDiffRow, SplitDiffRow.Line?>, hunks: Bool, tint: Color) -> some View {
        if let hunk = row.hunk {
            // The header is said once, on the left; the right keeps the row.
            Text(hunks ? hunk : " ")
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(Self.hunk)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 8)
        } else if let line = row[keyPath: side] {
            HStack(spacing: 0) {
                Text("\(line.number)")
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: numberWidth - 8, alignment: .trailing)
                    .padding(.trailing, 8)
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(line.changed ? tint : Color.white.opacity(0.75))
                    .lineLimit(1)
                    .fixedSize()
            }
        } else {
            Color.clear
        }
    }

    private func background(_ row: SplitDiffRow, side: KeyPath<SplitDiffRow, SplitDiffRow.Line?>, tint: Color) -> Color {
        if row.hunk != nil { return Color.white.opacity(0.04) }
        guard let line = row[keyPath: side] else {
            // Nothing on this side where the other has a line: hatched in
            // other tools, here simply dimmer than the page.
            return Color.black.opacity(0.18)
        }
        return line.changed ? tint.opacity(0.11) : .clear
    }
}
