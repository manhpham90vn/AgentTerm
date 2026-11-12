# Third-party notices

AgentTerm is released under the [MIT License](LICENSE). It is built with the
open source software below, each under its own license. The versions are the
ones `Package.resolved` pins.

## Swift packages

| Package | Used for | License |
|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | The terminal emulator | MIT |
| [Highlightr](https://github.com/raspu/Highlightr) | Syntax coloring in the editor and in previews | MIT |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | The Markdown preview | MIT |
| [NetworkImage](https://github.com/gonzalezreal/NetworkImage) | Pictures in the Markdown preview; a dependency of swift-markdown-ui | MIT |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) | Markdown parsing; a dependency of swift-markdown-ui | BSD 2-Clause, with parts under MIT and other permissive licenses listed in its `COPYING` |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | A dependency of SwiftTerm's tools | Apache 2.0 |
| [swift-png](https://github.com/tayloraswift/swift-png) and [h](https://github.com/rarestype/h) | Dependencies of SwiftTerm | Apache 2.0 |

## Bundled files

| File | What | License |
|---|---|---|
| `highlight.js`, inside Highlightr | [highlight.js](https://highlightjs.org), the syntax highlighter Highlightr runs | BSD 3-Clause |
| `Sources/AgentTermEditor/Resources/mermaid.min.js` | [Mermaid](https://github.com/mermaid-js/mermaid) 11.4.1, draws diagrams from text; the unmodified build | MIT |

The full text of each license is in that project's repository, at the links
above.
