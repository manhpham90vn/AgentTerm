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

    /// How far each side is scrolled sideways.
    @State private var leftOffset: CGFloat = 0
    @State private var rightOffset: CGFloat = 0

    // A long diff has thousands of rows, and only the few dozen in view are
    // made: the rows are in one lazy stack that scrolls down, both sides of
    // a row together. A lazy stack inside a view that scrolls sideways
    // would not be lazy, so the sides do not scroll themselves. Over each
    // lies an empty view that does, and the rows are moved by as much.
    var body: some View {
        GeometryReader { viewport in
            let half = max(60, (viewport.size.width - 1) / 2)
            let leftLine = max(leftWidth, half - numberWidth)
            let rightLine = max(rightWidth, half - numberWidth)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(alignment: .top, spacing: 0) {
                            side(row, \.left, hunks: true, width: half, lineWidth: leftLine, offset: leftOffset, tint: Self.removed)
                            Color.white.opacity(0.10).frame(width: 1)
                            side(row, \.right, hunks: false, width: half, lineWidth: rightLine, offset: rightOffset, tint: Self.added)
                        }
                        .frame(height: rowHeight)
                    }
                }
                .overlay {
                    HStack(spacing: 0) {
                        SidewaysScroller(contentWidth: numberWidth + leftLine, offset: $leftOffset)
                            .frame(width: half)
                            .accessibilityIdentifier("split-diff-before")
                        Color.clear.frame(width: 1)
                        SidewaysScroller(contentWidth: numberWidth + rightLine, offset: $rightOffset)
                            .frame(width: half)
                            .accessibilityIdentifier("split-diff-after")
                    }
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

    /// One side of a row: its line with its number, as wide as the side's
    /// longest line, shown through its half of the view from where that
    /// side is scrolled to.
    private func side(
        _ row: SplitDiffRow, _ side: KeyPath<SplitDiffRow, SplitDiffRow.Line?>, hunks: Bool, width: CGFloat, lineWidth: CGFloat, offset: CGFloat,
        tint: Color
    ) -> some View {
        line(row, side: side, hunks: hunks, tint: tint)
            .frame(width: numberWidth + lineWidth, height: rowHeight, alignment: .leading)
            .background(background(row, side: side, tint: tint))
            .offset(x: -offset)
            .frame(width: width, alignment: .leading)
            .clipped()
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
                // As digits only: a number put in a text gets the separators of
                // the language, 1,176, and the column is as wide as its digits.
                Text(verbatim: String(line.number))
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

/// Scrolls sideways over one side of the diff and says how far, with
/// nothing in it to draw: the rows under it are moved by that much.
private struct SidewaysScroller: View {
    let contentWidth: CGFloat
    @Binding var offset: CGFloat
    @State private var space = UUID()

    private struct Offset: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    var body: some View {
        ScrollView(.horizontal) {
            Color.clear
                .frame(width: contentWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .background(GeometryReader { content in Color.clear.preference(key: Offset.self, value: -content.frame(in: .named(space)).minX) })
        }
        .coordinateSpace(name: space)
        .onPreferenceChange(Offset.self) { offset = $0 }
    }
}
