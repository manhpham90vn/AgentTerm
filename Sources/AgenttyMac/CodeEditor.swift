import AppKit
import Highlightr
import MarkdownUI
import SwiftUI

/// Names highlight.js knows, by file name. Anything else is shown as plain text.
enum FileLanguage {
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

    static func forFile(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        return byName[name] ?? byExtension[(name as NSString).pathExtension] ?? "plaintext"
    }
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

    static func font(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
}

/// A plain text editor with syntax coloring.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    /// What the text belongs to. A change means another file was opened.
    let path: String
    var fontSize: CGFloat = 12.5

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // The text storage is Highlightr's, which recolors what is edited.
        let storage: NSTextStorage
        if let highlightr = Highlighting.shared {
            highlightr.theme.setCodeFont(Highlighting.font(size: fontSize))
            let highlighted = CodeAttributedString(highlightr: highlightr)
            highlighted.language = FileLanguage.forFile(path)
            storage = highlighted
        } else {
            storage = NSTextStorage()
        }
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
        textView.textColor = NSColor(white: 0.86, alpha: 1)
        textView.backgroundColor = TerminalBackground.color
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
        scroll.backgroundColor = TerminalBackground.color
        context.coordinator.textView = textView
        context.coordinator.path = path
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
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

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        var path = ""

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
        }
    }
}

enum TerminalBackground {
    static let color = NSColor(srgbRed: 0.075, green: 0.078, blue: 0.098, alpha: 1)
}

/// Colors code blocks in a Markdown preview with the editor's highlighter.
struct PreviewCodeHighlighter: CodeSyntaxHighlighter {
    func highlightCode(_ code: String, language: String?) -> Text {
        // SwiftUI builds views on the main thread, where the highlighter lives.
        let attributed = MainActor.assumeIsolated { () -> AttributedString? in
            guard let highlightr = Highlighting.shared else { return nil }
            let name = language?.lowercased()
            let known = name.flatMap { highlightr.supportedLanguages().contains($0) ? $0 : nil }
            guard let highlighted = highlightr.highlight(code, as: known ?? "plaintext") else { return nil }
            return try? AttributedString(highlighted, including: \.appKit)
        }
        return attributed.map { Text($0) } ?? Text(code)
    }
}

/// A rendered Markdown document.
struct MarkdownPreview: View {
    let text: String
    /// Folder of the document, so links and images relative to it resolve.
    let baseURL: URL?

    var body: some View {
        ScrollView {
            Markdown(text, baseURL: baseURL)
                .markdownTheme(.gitHub.text { BackgroundColor(nil) })
                .markdownCodeSyntaxHighlighter(PreviewCodeHighlighter())
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }
}
