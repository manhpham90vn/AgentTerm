import AgentTermProtocol
import SwiftUI

/// The parts of one file's change (#40): its hunks, each with its lines. A
/// hunk is staged, unstaged or discarded whole, or only the lines of it
/// that are ticked. It reads the change as the diff's tab has it, so what
/// was applied is gone from it the next moment.
struct PartsSheet: View {
    @EnvironmentObject private var model: AppModel
    /// The change as it was when the sheet opened: which file, and whether
    /// its staged part or what is not staged.
    let file: FileDiff
    let close: () -> Void
    /// The lines ticked in each hunk, by the hunk's header and place: a
    /// hunk is another once something of it was applied.
    @State private var picked: [String: Set<Int>] = [:]
    /// The part the user is asked about before it is discarded.
    @State private var discarding: (hunk: PatchHunk, picked: Set<Int>?)?

    /// The change as it is now: the diff tab's, while it is still this file's.
    private var current: FileDiff? {
        guard let now = model.diffTabFile, now.path == file.path, now.isStaged == file.isStaged else { return nil }
        return now
    }

    private var hunks: [PatchHunk] { PatchParts.hunks(of: current?.patch ?? "") }

    private func key(_ hunk: PatchHunk) -> String { "\(hunk.id):\(hunk.header)" }

    private func ticked(_ hunk: PatchHunk) -> Set<Int> { picked[key(hunk)] ?? [] }

    private func toggle(_ line: Int, in hunk: PatchHunk) {
        var lines = ticked(hunk)
        if lines.contains(line) { lines.remove(line) } else { lines.insert(line) }
        picked[key(hunk)] = lines
    }

    /// Applies a hunk, or its ticked lines when there are some.
    private func apply(_ use: PatchParts.Use, _ hunk: PatchHunk) {
        guard let current else { return }
        let lines = ticked(hunk)
        model.apply(use, hunk: hunk, picked: lines.isEmpty ? nil : lines, of: current)
        picked[key(hunk)] = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(file.isStaged ? "STAGED" : "CHANGES")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.raised))
                Text(file.path).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("parts-done")
            }
            .padding(12)
            Theme.hairline.frame(height: 1)
            if hunks.isEmpty {
                Text(file.isStaged ? "Nothing of this file is staged any more." : "This file has no change left that is not staged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(hunks) { hunk in
                            HunkCard(
                                hunk: hunk, staged: file.isStaged, ticked: ticked(hunk), toggle: { toggle($0, in: hunk) }, apply: { apply($0, hunk) },
                                discard: {
                                    let lines = ticked(hunk)
                                    discarding = (hunk, lines.isEmpty ? nil : lines)
                                })
                        }
                    }
                    .padding(12)
                }
            }
            Theme.hairline.frame(height: 1)
            Text("Tick lines to take only those; with none ticked, a button takes its whole hunk.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 420, idealHeight: 560)
        .background(Theme.panel)
        // Asked first: what is discarded does not come back.
        .confirmationDialog(
            discardTitle, isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }), titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                if let asked = discarding, let current {
                    model.apply(.discard, hunk: asked.hunk, picked: asked.picked, of: current)
                    picked[key(asked.hunk)] = nil
                }
                discarding = nil
            }
            Button("Cancel", role: .cancel) { discarding = nil }
        } message: {
            Text("They go from the file, which cannot be undone. The rest of the file's changes stay.")
        }
    }

    private var discardTitle: String {
        guard let asked = discarding else { return "" }
        if let lines = asked.picked { return "Discard \(lines.count) \(lines.count == 1 ? "line" : "lines") of \((file.path as NSString).lastPathComponent)?" }
        return "Discard this hunk of \((file.path as NSString).lastPathComponent)?"
    }
}

/// One hunk: where it is, what can be done with it, and its lines.
private struct HunkCard: View {
    let hunk: PatchHunk
    let staged: Bool
    let ticked: Set<Int>
    let toggle: (Int) -> Void
    let apply: (PatchParts.Use) -> Void
    let discard: () -> Void

    /// "Hunk" for the whole of it, "3 Lines" for what is ticked.
    private var what: String { ticked.isEmpty ? "Hunk" : "\(ticked.count) \(ticked.count == 1 ? "Line" : "Lines")" }

    private var title: String {
        let place = "Line \(max(hunk.newStart, 1))"
        return hunk.section.isEmpty ? place : place + " · " + hunk.section
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                DiffCount(added: hunk.added, deleted: hunk.removed)
                Spacer(minLength: 8)
                if staged {
                    Button("Unstage \(what)") { apply(.unstage) }
                        .accessibilityIdentifier("part-unstage-\(hunk.id)")
                } else {
                    Button("Discard \(what)…", role: .destructive, action: discard)
                        .accessibilityIdentifier("part-discard-\(hunk.id)")
                    Button("Stage \(what)") { apply(.stage) }
                        .accessibilityIdentifier("part-stage-\(hunk.id)")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Theme.hairline.frame(height: 1)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
                        PartLine(line: line, ticked: ticked.contains(index)) { toggle(index) }
                            .accessibilityIdentifier("part-line-\(hunk.id)-\(index)")
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hunk-\(hunk.id)")
    }
}

/// One line of a hunk. A line that is a change has a box to tick.
private struct PartLine: View {
    let line: String
    let ticked: Bool
    let toggle: () -> Void

    private var isChange: Bool { line.hasPrefix("+") || line.hasPrefix("-") }

    private var color: Color {
        if line.hasPrefix("+") { return Theme.added }
        if line.hasPrefix("-") { return Theme.removed }
        return Color.white.opacity(0.72)
    }

    private var tint: Color {
        if line.hasPrefix("+") { return Theme.added.opacity(ticked ? 0.22 : 0.10) }
        if line.hasPrefix("-") { return Theme.removed.opacity(ticked ? 0.22 : 0.10) }
        return .clear
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ticked ? "checkmark.square.fill" : "square")
                .font(.system(size: 11))
                .foregroundStyle(ticked ? Color.accentColor : Color.secondary)
                .opacity(isChange ? 1 : 0)
                .frame(width: 16)
            Text(line.isEmpty ? " " : line.replacingOccurrences(of: "\t", with: "    "))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint)
        .contentShape(Rectangle())
        .onTapGesture { if isChange { toggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((ticked ? "Ticked, " : "") + line)
        .accessibilityAddTraits(isChange ? .isButton : [])
        .accessibilityAction { if isChange { toggle() } }
    }
}
