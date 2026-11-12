import CoreText
import Foundation
import SwiftTerm

/// Draws Japanese, Chinese, Korean and other full-width characters at the
/// size their two cells call for.
///
/// A full-width character takes two cells. The terminal's own font has no
/// such characters, so they come from another font at the same point size,
/// and there they are one em wide: 13 points in a slot of 15.6. The slack
/// shows as a gap after every character, and a line of Japanese reads as
/// if it were letter-spaced. Here the same characters are taken from a
/// font sized so that one em is exactly two cells, which is how text in
/// these scripts is meant to sit: each character in its square, the
/// squares touching.
final class WideGlyphs: TerminalGlyphFallbackProvider, @unchecked Sendable {
    static let shared = WideGlyphs()

    let generation: UInt64 = 1
    private let lock = NSLock()
    private var fonts: [CGFloat: CTFont] = [:]

    /// The fonts the characters are drawn in: one per language, tried in
    /// turn, so Japanese, Chinese and Korean are all covered. Their order
    /// follows the languages the user reads, because the Han characters the
    /// three share are drawn a little differently in each, and the first
    /// font that has a character decides. Japanese comes first when none of
    /// them is among the preferred languages.
    private static let fontNames: [String] = {
        let all = ["HiraginoSans-W3", "PingFangSC-Regular", "PingFangTC-Regular", "AppleSDGothicNeo-Regular"]
        var preferred: [String] = []
        for language in Locale.preferredLanguages {
            if language.hasPrefix("ja") {
                preferred.append(all[0])
            } else if language.hasPrefix("zh-Hant") || language.hasPrefix("zh-TW") || language.hasPrefix("zh-HK") {
                preferred.append(all[2])
            } else if language.hasPrefix("zh") {
                preferred.append(all[1])
            } else if language.hasPrefix("ko") {
                preferred.append(all[3])
            }
        }
        var names: [String] = []
        for name in preferred + all where !names.contains(name) { names.append(name) }
        return names
    }()

    /// The scripts that are written in squares: kana, Han characters with
    /// their rarer extensions, Hangul, Bopomofo, their punctuation, and the
    /// full-width forms of Latin letters and digits.
    private static let ranges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7A3,
        0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF01...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x2FFFD, 0x30000...0x3FFFD,
    ]

    func placementPolicy(for scalar: Unicode.Scalar) -> TerminalGlyphPlacementPolicy? {
        guard scalar.value >= 0x1100, Self.ranges.contains(where: { $0.contains(scalar.value) }) else { return nil }
        // Centered in its two cells at its natural size, which is the size
        // chosen below; never stretched to its own outline, or a long
        // vowel mark would come out larger than a kanji.
        return TerminalGlyphPlacementPolicy(placement: .icon)
    }

    func fallbackFont(forPointSize size: CGFloat) -> CTFont? {
        lock.lock()
        defer { lock.unlock() }
        if let font = fonts[size] { return font }
        // Two cells of the terminal's font are this many points wide.
        let terminal = TerminalStyle.font(size: size) as CTFont
        var glyph = CGGlyph(0)
        var character: UniChar = 0x30
        var slot = size * 1.2
        if CTFontGetGlyphsForCharacters(terminal, &character, &glyph, 1) {
            let advance = CTFontGetAdvancesForGlyphs(terminal, .horizontal, &glyph, nil, 1)
            if advance > 0 { slot = advance * 2 }
        }
        // The first font, with the others to fall back on for what it lacks.
        let others = Self.fontNames.dropFirst().map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, slot) }
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontNameAttribute: Self.fontNames[0], kCTFontCascadeListAttribute: others] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, slot, nil)
        fonts[size] = font
        return font
    }
}
