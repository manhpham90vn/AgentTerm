import MarkdownUI
import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
private typealias PlatformImage = NSImage
#else
import UIKit
private typealias PlatformImage = UIImage
#endif

/// Shows the pictures of a Markdown preview: files next to the document are
/// read from disk, anything else is fetched. A width asked for in the
/// source (`<img width="200">`, carried in the address by `MarkdownHTML`) is
/// kept, and no picture is drawn larger than it is.
struct PreviewImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        PreviewImage(url: url)
    }
}

private struct PreviewImage: View {
    let url: URL?

    /// The width asked for, taken out of the address again.
    private var width: CGFloat? { url.flatMap { MarkdownHTML.width(in: $0.absoluteString) }.map { CGFloat($0) } }

    var body: some View {
        if let url, url.isFileURL {
            if let image = PlatformImage(contentsOfFile: url.path) {
                #if canImport(AppKit) && !targetEnvironment(macCatalyst)
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(width ?? image.size.width, image.size.width))
                #else
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(width ?? image.size.width, image.size.width))
                #endif
            }
        } else if let width {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Color.clear.frame(height: 1)
            }
            .frame(maxWidth: width)
        } else {
            DefaultImageProvider.default.makeImage(url: url)
        }
    }
}
