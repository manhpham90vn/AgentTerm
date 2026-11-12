import Foundation

/// Markdown files, READMEs above all, mix in HTML: an image with a width, a
/// centered block, a line break. The preview draws Markdown, not HTML, so the
/// HTML that has a Markdown meaning is turned into it and the tags that only
/// arrange things are dropped, leaving what they hold. Nothing in a file is
/// run: no scripts, no styles.
///
/// What is lost is what Markdown cannot say: alignment, sizes, and tables
/// written as HTML, which come out as their text.
public enum MarkdownHTML {
    private static let widthKey = "agentterm-width="

    /// The width a picture's address carries, if `flatten` put one there.
    public static func width(in address: String) -> Int? {
        guard let range = address.range(of: "#" + widthKey) else { return nil }
        return Int(address[range.upperBound...])
    }

    public static func flatten(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var out: [String] = []
        var fence: String?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                // Inside a code block nothing is touched.
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == open.first }) { fence = nil }
                out.append(line)
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                out.append(line)
            } else {
                out.append(convertOutsideCode(line))
            }
        }
        return squeezeBlankLines(out.joined(separator: "\n"))
    }

    /// Leaves `inline code` alone and converts the rest of a line.
    private static func convertOutsideCode(_ line: String) -> String {
        guard line.contains("<") else { return line }
        // Odd pieces are between backticks.
        let pieces = line.components(separatedBy: "`")
        guard pieces.count > 1, pieces.count % 2 == 1 else { return convert(line) }
        return pieces.enumerated().map { $0.offset % 2 == 0 ? convert($0.element) : $0.element }.joined(separator: "`")
    }

    private static func convert(_ source: String) -> String {
        var text = source
        text = replace(text, #"<!--.*?-->"#) { _ in "" }
        text = replace(text, #"<br\s*/?>"#) { _ in "  \n" }
        text = replace(text, #"<hr\s*/?>"#) { _ in "\n\n---\n\n" }
        text = replace(text, #"<img\b([^>]*)>"#) { groups in
            guard let source = attribute("src", in: groups[1]), !source.isEmpty else { return "" }
            // Markdown has no way to say how wide a picture is. The width
            // rides along in the address, where the preview finds it.
            var address = source
            if let asked = attribute("width", in: groups[1]), let width = Int(asked.replacingOccurrences(of: "px", with: "")), width > 0, !source.contains("#") {
                address += "#\(widthKey)\(width)"
            }
            return "![\(attribute("alt", in: groups[1]) ?? "")](\(address))"
        }
        text = replace(text, #"<a\b([^>]*)>(.*?)</a>"#) { groups in
            guard let link = attribute("href", in: groups[1]), !link.isEmpty else { return groups[2] }
            return "[\(groups[2])](\(link))"
        }
        for (tag, mark) in [("strong", "**"), ("b", "**"), ("em", "*"), ("i", "*"), ("code", "`"), ("kbd", "`"), ("del", "~~"), ("s", "~~")] {
            text = replace(text, "<\(tag)>(.*?)</\(tag)>") { groups in
                groups[1].trimmingCharacters(in: .whitespaces).isEmpty ? groups[1] : mark + groups[1] + mark
            }
        }
        for level in 1...6 {
            text = replace(text, "<h\(level)\\b[^>]*>(.*?)</h\(level)>") { groups in
                "\n\n" + String(repeating: "#", count: level) + " " + groups[1].trimmingCharacters(in: .whitespaces) + "\n\n"
            }
        }
        text = replace(text, #"<li\b[^>]*>"#) { _ in "\n- " }
        text = replace(text, #"</?(?:td|th)\b[^>]*>"#) { _ in " " }
        // What starts or ends a block becomes a paragraph break.
        text = replace(text, #"</?(?:p|div|center|details|summary|table|thead|tbody|tr|ul|ol|blockquote|section|header|footer|picture|figure|figcaption)\b[^>]*>"#) { _ in "\n\n" }
        // What only styles its text goes, and the text stays.
        text = replace(text, #"</?(?:span|font|sub|sup|small|big|u|li|source|a|strong|b|em|i|code|kbd|del|s|h[1-6]|img)\b[^>]*>"#) { _ in "" }
        return text
    }

    /// The value of an attribute in a tag's inside: `src="a.png"`, `src='a.png'` or `src=a.png`.
    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "(?:^|\\s)\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = expression.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
        else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    /// Replaces every match of `pattern`, given its groups (0 is the whole match).
    private static func replace(_ text: String, _ pattern: String, with make: ([String]) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result) else { continue }
            let groups = (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: result).map { String(result[$0]) } ?? ""
            }
            result.replaceSubrange(whole, with: make(groups))
        }
        return result
    }

    /// Dropping tags leaves runs of empty lines behind; two are a paragraph
    /// break and more say nothing more. Code blocks are left as they are.
    private static func squeezeBlankLines(_ text: String) -> String {
        var out: [String] = []
        var blanks = 0
        var fence: String?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == open.first }) { fence = nil }
                out.append(line)
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = String(trimmed.prefix(3)) }
            // A line of only spaces is a hard break's leftover, not content.
            if trimmed.isEmpty, !line.hasSuffix("  ") || out.last?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                blanks += 1
                if blanks <= 1 { out.append("") }
            } else {
                blanks = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }
}
