import AgenttyProtocol
import SwiftTerm
import SwiftUI

/// Works out how many columns and rows fit an area before any terminal is
/// shown in it.
///
/// A session has to be started with some size. If that size is a guess, the
/// shell draws its first prompt for the wrong width, and zsh in particular
/// leaves a stray "%" on screen: it prints the mark and then pads the line
/// to what it believes is the width, and the padding wraps when the real
/// width is smaller.
@MainActor
public enum TerminalMetrics {
    private static var cache: [CGFloat: (cell: CGSize, extraWidth: CGFloat)] = [:]

    /// The grid a terminal with this font would pick for an area this large.
    public static func grid(for area: CGSize, fontSize: CGFloat) -> TermSize? {
        guard area.width > 0, area.height > 0 else { return nil }
        let metrics = measure(fontSize: fontSize)
        guard metrics.cell.width > 0, metrics.cell.height > 0 else { return nil }
        let cols = Int((area.width - metrics.extraWidth) / metrics.cell.width)
        let rows = Int(area.height / metrics.cell.height)
        return TermSize(cols: max(cols, 2), rows: max(rows, 2))
    }

    /// Cell size, and the width the view keeps for itself (a scroll bar),
    /// taken from a terminal view rather than from font tables so they match
    /// what the real view will do.
    private static func measure(fontSize: CGFloat) -> (cell: CGSize, extraWidth: CGFloat) {
        if let known = cache[fontSize] { return known }
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        view.font = TerminalStyle.font(size: fontSize)
        // Two widths tell the cell width apart from the fixed extra.
        view.resize(cols: 80, rows: 20)
        let narrow = view.getOptimalFrameSize().size
        view.resize(cols: 160, rows: 40)
        let wide = view.getOptimalFrameSize().size
        let cellWidth = (wide.width - narrow.width) / 80
        let cellHeight = (wide.height - narrow.height) / 20
        let result = (cell: CGSize(width: cellWidth, height: cellHeight), extraWidth: max(0, narrow.width - cellWidth * 80))
        cache[fontSize] = result
        return result
    }
}
