import SwiftUI
import WebKit

/// Draws a Mermaid diagram.
///
/// Mermaid is a JavaScript library, so the drawing happens in a web view.
/// The library ships inside the app and the page loads nothing from the
/// network. The diagram's source is put into the page as text, never as
/// markup, and Mermaid runs in its strict mode, which keeps scripts and
/// click handlers out of diagrams.
struct MermaidView: View {
    let code: String
    /// The diagram's height once it is drawn. A guess until then.
    @State private var height: CGFloat = 160

    var body: some View {
        MermaidWebView(code: code, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }
}

private struct MermaidWebView: NSViewRepresentable {
    let code: String
    @Binding var height: CGFloat

    /// The library's source, read once. About 2.5 MB.
    private static let library: String? = {
        guard let url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "size")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // Shows the panel's own background behind the diagram.
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(code, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.height = $height
        if context.coordinator.shown != code { context.coordinator.load(code, into: webView) }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "size")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var shown: String?

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func load(_ code: String, into webView: WKWebView) {
            shown = code
            guard let library = MermaidWebView.library else {
                webView.loadHTMLString("<body style='color:#aaa;font:13px -apple-system'>Mermaid is missing from this build.</body>", baseURL: nil)
                return
            }
            // As text in the page: "<" in a diagram must not become a tag.
            let escaped = code
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let html = """
            <!doctype html>
            <html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data:; font-src data:">
            <style>
              html, body { margin: 0; background: transparent; color: #d9dbe2; font: 13px -apple-system, sans-serif; }
              #diagram { padding: 8px 0; text-align: center; }
              #diagram svg { max-width: 100%; height: auto; }
              #error { color: #f5787a; white-space: pre-wrap; text-align: left; font: 12px ui-monospace, monospace; }
            </style></head>
            <body>
            <pre id="source" hidden>\(escaped)</pre>
            <div id="diagram"></div>
            <script>\(library)</script>
            <script>
              const report = () => window.webkit.messageHandlers.size.postMessage(Math.ceil(document.documentElement.scrollHeight));
              const target = document.getElementById('diagram');
              mermaid.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'strict' });
              mermaid.render('graph', document.getElementById('source').textContent)
                .then(result => { target.innerHTML = result.svg; report(); })
                .catch(error => { target.innerHTML = '<div id="error"></div>'; document.getElementById('error').textContent = 'This diagram has an error:\\n' + (error.message || error); report(); });
            </script>
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? NSNumber else { return }
            let measured = CGFloat(truncating: value)
            DispatchQueue.main.async { [height] in
                if abs(height.wrappedValue - measured) > 1 { height.wrappedValue = max(40, min(measured, 4000)) }
            }
        }

        /// A diagram has nowhere to go: links open in the browser instead.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased()) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(action.navigationType == .other ? .allow : .cancel)
            }
        }
    }
}
