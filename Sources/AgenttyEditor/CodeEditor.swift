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

    /// Text storage that recolors what is edited, or a plain one if the
    /// highlighter could not be loaded.
    static func storage(for path: String, fontSize: CGFloat) -> NSTextStorage {
        guard let highlightr = shared else { return NSTextStorage() }
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

    public init(text: Binding<String>, path: String, fontSize: CGFloat = 12.5) {
        _text = text
        self.path = path
        self.fontSize = fontSize
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let storage = Highlighting.storage(for: path, fontSize: fontSize)
        let layout = NSLayoutManager()
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
            textView.undoManager?.removeAllActions()
            textView.scrollToBeginningOfDocument(nil)
        } else if textView.string != text {
            // Changed from outside the editor, such as discarding edits.
            textView.string = text
        }
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        var path = ""

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
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

    public init(text: Binding<String>, path: String, fontSize: CGFloat = 13) {
        _text = text
        self.path = path
        self.fontSize = fontSize
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeUIView(context: Context) -> UITextView {
        let storage = Highlighting.storage(for: path, fontSize: fontSize)
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
    }

    public final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        var path = ""

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
            Markdown(text, baseURL: baseURL)
                .markdownTheme(Self.theme)
                .markdownCodeSyntaxHighlighter(PreviewCodeHighlighter())
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(EditorStyle.background))
    }
}
