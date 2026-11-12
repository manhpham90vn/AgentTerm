import SwiftUI
import UIKit

/// Whether the keyboard is on screen. iOS has no key for putting it away on
/// a phone, and it covers half of the screen: wherever there is something
/// to write in, there is a button that hides it.
@MainActor
final class KeyboardWatcher: ObservableObject {
    @Published private(set) var isUp = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isUp = true }
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isUp = false }
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Puts the keyboard away, whichever field or terminal it was up for.
    /// What was written stays where it is.
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// The button that hides the keyboard, as it looks everywhere.
struct HideKeyboardButton: View {
    var body: some View {
        Button {
            KeyboardWatcher.dismiss()
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
        }
        .accessibilityLabel("Hide Keyboard")
        .accessibilityIdentifier("hide-keyboard")
    }
}

extension View {
    /// A bar above the keyboard with a button that hides it, for the text
    /// fields of this screen.
    func keyboardDismissButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                HideKeyboardButton()
            }
        }
    }
}
