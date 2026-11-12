import SwiftUI

/// What a view shows while it waits for the Mac: a spinner and what is
/// being waited for. Shared by the Mac and the iPhone, so waiting looks the
/// same everywhere.
///
/// It stays out of sight for a moment, since most answers are there at
/// once and a spinner that flashes by is worse than none. When the wait
/// gets long it says so, and offers to ask again where that can be done:
/// an animation that runs for good tells nothing.
public struct LoadingView: View {
    private let text: String
    private let cover: Color?
    private let retry: (() -> Void)?
    @State private var stage = Stage.waiting

    private enum Stage { case waiting, shown, slow }

    /// How long nothing is shown, and after how long the wait is called long.
    public static let delay: Duration = .milliseconds(300)
    public static let slowAfter: Duration = .seconds(10)

    /// `cover` is put behind it when it lies over something that should
    /// not show through, such as a terminal that is still being filled.
    public init(_ text: String, cover: Color? = nil, retry: (() -> Void)? = nil) {
        self.text = text
        self.cover = cover
        self.retry = retry
    }

    public var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if stage == .slow {
                Text("This is taking longer than usual.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                if let retry {
                    Button("Try Again", action: retry)
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("loading-retry")
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cover)
        .opacity(stage == .waiting ? 0 : 1)
        .animation(.easeIn(duration: 0.15), value: stage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("loading")
        .task {
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            stage = .shown
            try? await Task.sleep(for: Self.slowAfter)
            guard !Task.isCancelled else { return }
            stage = .slow
        }
    }
}
