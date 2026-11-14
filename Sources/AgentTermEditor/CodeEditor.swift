import Highlightr
import MarkdownUI
import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#endif

/// Names highlight.js knows, by file name. Anything else is shown as plain text.
public enum FileLanguage {
    private static let byExtension: [String: String] = [
        "swift": "swift", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript", "py": "python", "pyi": "python", "rb": "ruby", "go": "go", "rs": "rust",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "scala": "scala", "groovy": "groovy", "gradle": "gradle",
        "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "m": "objectivec", "mm": "objectivec", "cs": "csharp", "php": "php", "dart": "dart", "lua": "lua", "luau": "lua",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash", "ps1": "powershell",
        "json": "json", "jsonc": "json", "jsonl": "json", "yml": "yaml", "yaml": "yaml", "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini",
        "xml": "xml", "plist": "xml", "svg": "xml", "html": "xml", "htm": "xml", "vue": "xml", "xib": "xml", "storyboard": "xml",
        "css": "css", "scss": "scss", "less": "less", "sql": "sql", "md": "markdown", "markdown": "markdown", "mdx": "markdown",
        "r": "r", "pl": "perl", "tex": "latex", "diff": "diff", "patch": "diff", "proto": "protobuf", "graphql": "graphql",
        "cmake": "cmake", "ex": "elixir", "exs": "elixir", "erl": "erlang", "hs": "haskell", "clj": "clojure", "nim": "nim", "zig": "zig",
    ]
    private static let byName: [String: String] = [
        "dockerfile": "dockerfile", "makefile": "makefile", "cmakelists.txt": "cmake", "gemfile": "ruby", "podfile": "ruby",
        "rakefile": "ruby", ".zshrc": "bash", ".bashrc": "bash", ".profile": "bash", ".env": "bash", ".gitignore": "bash",
        "package.swift": "swift",
    ]

    public static func forFile(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        return byName[name] ?? byExtension[(name as NSString).pathExtension] ?? "plaintext"
    }

    public static func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased())
    }

    /// A file that is one Mermaid diagram.
    public static func isMermaid(_ path: String) -> Bool {
        ["mmd", "mermaid"].contains((path as NSString).pathExtension.lowercased())
    }
}

/// Colors the editor and the previews share: the terminal's background, so a
/// file next to a terminal does not look like another app.
public enum EditorStyle {
    public static let background = PlatformColor(red: 0.075, green: 0.078, blue: 0.098, alpha: 1)
    public static let text = PlatformColor(white: 0.86, alpha: 1)
}

/// One highlighter for the app: it loads highlight.js into a JavaScript
/// context, which is not worth doing per file.
@MainActor
enum Highlighting {
    static let theme = "atom-one-dark"

    static let shared: Highlightr? = {
        let highlightr = Highlightr()
        highlightr?.setTheme(to: theme)
        return highlightr
    }()

    static func font(size: CGFloat) -> PlatformFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

    /// The largest text that is colored, in UTF-16 units: about half a
    /// megabyte. Coloring a file of 5 MB held the window for five seconds
    /// when it opened, and a quarter of a second at each key (#21).
    static let largestColored = 512 * 1024

    /// Whether a file's text is colored: one in a language the highlighter
    /// knows, and not too large.
    static func colors(_ path: String, length: Int) -> Bool {
        length <= largestColored && FileLanguage.forFile(path) != "plaintext"
    }

    /// Text storage that recolors what is edited; a plain one for text
    /// that is not colored, or if the highlighter could not be loaded.
    static func storage(for path: String, fontSize: CGFloat, length: Int) -> NSTextStorage {
        guard colors(path, length: length), let highlightr = shared else { return NSTextStorage() }
        highlightr.theme.setCodeFont(font(size: fontSize))
        let highlighted = CodeAttributedString(highlightr: highlightr)
        highlighted.language = FileLanguage.forFile(path)
        return highlighted
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
/// A plain text editor with syntax coloring.
public struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    /// What the text belongs to. A change means another file was opened.
    let path: String
    var fontSize: CGFloat

    /// The line to show, when one was asked for.
    var target: LineTarget?

    public init(text: Binding<String>, path: String, fontSize: CGFloat = 12.5, target: LineTarget? = nil) {
        _text = text
        self.path = path
        self.fontSize = fontSize
        self.target = target
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let storage = Highlighting.storage(for: path, fontSize: fontSize, length: text.utf16.count)
        let layout = NSLayoutManager()
        // Only what is on show is laid out: a file of megabytes opens at once.
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        // Lines are not wrapped: code reads better scrolled sideways.
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Highlighting.font(size: fontSize)
        textView.textColor = EditorStyle.text
        textView.backgroundColor = EditorStyle.background
        textView.insertionPointColor = .white
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        // Code is not prose: none of the typing aids.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorStyle.background
        context.coordinator.textView = textView
        context.coordinator.path = path
        context.coordinator.held = text
        context.coordinator.go(to: target)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if context.coordinator.path != path {
            // Another file: its own language, and no undo into the last one.
            context.coordinator.path = path
            (textView.textStorage as? CodeAttributedString)?.language = FileLanguage.forFile(path)
            textView.string = text
            context.coordinator.held = text
            textView.undoManager?.removeAllActions()
            textView.scrollToBeginningOfDocument(nil)
        } else if context.coordinator.held != text {
            // Changed from outside the editor, such as discarding edits. Told
            // by what the editor last gave or was given, which is the same
            // text in memory when nothing changed: asking the view for all
            // of its text at each key is what made typing in a large file slow.
            context.coordinator.held = text
            if textView.string != text { textView.string = text }
        }
        context.coordinator.go(to: target)
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        var path = ""
        /// The text the editor last gave its owner, or was given by it.
        var held = ""
        private var shown: Int?

        /// Scrolls to a line and marks it, once for each time it is asked
        /// for; after the view was laid out, which it is not yet when made.
        func go(to target: LineTarget?) {
            guard let target, target.token != shown, textView?.string.isEmpty == false else { return }
            shown = target.token
            DispatchQueue.main.async { [weak self] in
                guard let textView = self?.textView else { return }
                let range = LineTarget.range(ofLine: target.line, in: textView.string as NSString)
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
                textView.showFindIndicator(for: range)
            }
        }

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // What the view holds now, kept as the one text both sides
            // have: the view is not asked for it again, nor compared with
            // it, when this change comes back round as an update (#21).
            let now = textView.string
            held = now
            parent.text = now
        }
    }
}
#else
/// A plain text editor with syntax coloring.
public struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    /// What the text belongs to. A change means another file was opened.
    let path: String
    var fontSize: CGFloat

    /// The line to show, when one was asked for.
    var target: LineTarget?

    public init(text: Binding<String>, path: String, fontSize: CGFloat = 13, target: LineTarget? = nil) {
        _text = text
        self.path = path
        self.fontSize = fontSize
        self.target = target
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeUIView(context: Context) -> UITextView {
        let storage = Highlighting.storage(for: path, fontSize: fontSize, length: text.utf16.count)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        // Lines wrap: a phone is too narrow to scroll code sideways while typing.
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = UITextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.font = Highlighting.font(size: fontSize)
        textView.textColor = EditorStyle.text
        textView.backgroundColor = EditorStyle.background
        textView.tintColor = .white
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.keyboardAppearance = .dark
        // Code is not prose: none of the typing aids.
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.accessibilityIdentifier = "code-editor"
        textView.text = text
        context.coordinator.path = path
        // A bar above the keyboard with a button that hides it: a phone's
        // keyboard has no key for that, and it covers half of the file.
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let hide = UIBarButtonItem(
            image: UIImage(systemName: "keyboard.chevron.compact.down"), style: .plain, target: textView,
            action: #selector(UIResponder.resignFirstResponder))
        hide.accessibilityLabel = "Hide Keyboard"
        hide.accessibilityIdentifier = "hide-keyboard"
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), hide]
        bar.sizeToFit()
        textView.inputAccessoryView = bar
        context.coordinator.go(to: target, in: textView)
        return textView
    }

    public func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.path != path {
            context.coordinator.path = path
            (textView.textStorage as? CodeAttributedString)?.language = FileLanguage.forFile(path)
            textView.text = text
            textView.undoManager?.removeAllActions()
            textView.setContentOffset(.zero, animated: false)
        } else if textView.text != text, textView.markedTextRange == nil {
            // Changed from outside the editor, such as discarding edits. Not
            // while a character is being composed, which this would break.
            textView.text = text
        }
        context.coordinator.go(to: target, in: textView)
    }

    public final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        var path = ""
        private var shown: Int?

        /// Scrolls to a line and selects it, once for each time it is asked
        /// for, and not before the file's text is there.
        func go(to target: LineTarget?, in textView: UITextView) {
            guard let target, target.token != shown, !textView.text.isEmpty else { return }
            shown = target.token
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                let range = LineTarget.range(ofLine: target.line, in: textView.text as NSString)
                textView.selectedRange = range
                textView.scrollRangeToVisible(range)
            }
        }

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        public func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text { parent.text = textView.text }
        }
    }
}
#endif

/// Colors code blocks in a Markdown preview with the editor's highlighter.
struct PreviewCodeHighlighter: CodeSyntaxHighlighter {
    func highlightCode(_ code: String, language: String?) -> Text {
        // SwiftUI builds views on the main thread, where the highlighter lives.
        let attributed = MainActor.assumeIsolated { () -> AttributedString? in
            guard let highlightr = Highlighting.shared else { return nil }
            let name = language?.lowercased()
            let known = name.flatMap { highlightr.supportedLanguages().contains($0) ? $0 : nil }
            guard let highlighted = highlightr.highlight(code, as: known ?? "plaintext") else { return nil }
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return try? AttributedString(highlighted, including: \.appKit)
            #else
            return try? AttributedString(highlighted, including: \.uiKit)
            #endif
        }
        return attributed.map { Text($0) } ?? Text(code)
    }
}

/// A rendered Markdown document.
public struct MarkdownPreview: View {
    let text: String
    /// Folder of the document, so links and images relative to it resolve.
    let baseURL: URL?

    public init(text: String, baseURL: URL?) {
        self.text = text
        self.baseURL = baseURL
    }

    /// GitHub's look, with code blocks marked "mermaid" drawn as diagrams.
    private static let theme = MarkdownUI.Theme.gitHub
        .text { BackgroundColor(nil) }
        .codeBlock { configuration in
            if configuration.language?.lowercased() == "mermaid" {
                MermaidView(code: configuration.content)
                    .markdownMargin(top: 0, bottom: 16)
            } else {
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.225))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.85))
                        }
                        .padding(14)
                }
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: 0, bottom: 16)
            }
        }

    public var body: some View {
        ScrollView {
            // HTML mixed into the Markdown is turned into Markdown first.
            Markdown(MarkdownHTML.flatten(text), baseURL: baseURL)
                .markdownTheme(Self.theme)
                .markdownImageProvider(PreviewImageProvider())
                .markdownCodeSyntaxHighlighter(PreviewCodeHighlighter())
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(EditorStyle.background))
    }
}

/// A line of the file to go to (#45): the editor scrolls to it and marks
/// it. `token` changes each time one is asked for, the same line too.
public struct LineTarget: Equatable, Sendable {
    public var line: Int
    public var token: Int

    public init(line: Int, token: Int) {
        self.line = line
        self.token = token
    }

    /// Where a line is in a text, by its number from 1; the last line for
    /// a number past the end.
    public static func range(ofLine line: Int, in text: NSString) -> NSRange {
        var start = 0
        var current = 1
        while current < line, start < text.length {
            let range = text.lineRange(for: NSRange(location: start, length: 0))
            guard NSMaxRange(range) > start, NSMaxRange(range) < text.length else { break }
            start = NSMaxRange(range)
            current += 1
        }
        var range = text.lineRange(for: NSRange(location: min(start, text.length), length: 0))
        // Without the line break at its end.
        while range.length > 0, let last = UnicodeScalar(text.character(at: NSMaxRange(range) - 1)), CharacterSet.newlines.contains(last) { range.length -= 1 }
        return range
    }
}
