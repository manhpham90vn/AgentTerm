import ObjectiveC
import XCTest

/// Steps made while a menu of the app is open, without the minute XCUITest
/// would wait before and after each of them (#65).
///
/// XCUITest waits for the app to be idle around every step, for up to 60
/// seconds. A row of the sessions' list can be dragged and has a menu: for
/// as long as that menu is open, iOS keeps the app busy (the row is lifted,
/// ready to be dragged), and every step waits its whole minute, the press
/// that opens the menu and the touch that picks from it. Measured on
/// 2026-11-14 with Xcode's simulator "iPhone Air": 61 seconds each, and 2.5
/// with the row not draggable; where the drag is put, on the row or inside
/// it, with `onDrag` or `draggable`, makes no difference.
///
/// There is no public way to tell XCUITest not to wait. This replaces the
/// wait of the test runner's own process class while `skipped` runs, and
/// puts it back after. It is the test's doing only: nothing of the app
/// changes. Should a later Xcode name the wait otherwise, nothing is
/// replaced and the steps wait as before, which `isAvailable` tells.
enum IdleWaits {
    private static var skipping = false
    private static var installed = false
    /// The waits that were found to replace, by their names.
    private(set) static var found: [String] = []

    /// Whether the waits can be skipped with this Xcode.
    static var isAvailable: Bool {
        install()
        return !found.isEmpty
    }

    /// Runs steps without waiting for the app to be idle around them. What
    /// the steps are for has to be waited for by itself, with
    /// `waitForExistence` and the like.
    static func skipped<T>(_ steps: () throws -> T) rethrows -> T {
        install()
        skipping = true
        defer { skipping = false }
        return try steps()
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        guard let process = NSClassFromString("XCUIApplicationProcess") else { return }
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(process, &count) else { return }
        defer { free(methods) }
        for index in 0..<Int(count) {
            let method = methods[index]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            guard name.hasPrefix("waitForQuiescenceIncludingAnimationsIdle:") else { continue }
            // Only a wait that answers nothing, taking one or two yes-or-no's.
            var returns = [CChar](repeating: 0, count: 8)
            method_getReturnType(method, &returns, returns.count)
            guard String(cString: returns) == "v" else { continue }
            let original = method_getImplementation(method)
            switch method_getNumberOfArguments(method) {
            case 3:
                typealias Wait = @convention(c) (AnyObject, Selector, Bool) -> Void
                let wait = unsafeBitCast(original, to: Wait.self)
                let block: @convention(block) (AnyObject, Bool) -> Void = { process, animations in
                    if !skipping { wait(process, selector, animations) }
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            case 4:
                typealias Wait = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
                let wait = unsafeBitCast(original, to: Wait.self)
                let block: @convention(block) (AnyObject, Bool, Bool) -> Void = { process, animations, before in
                    if !skipping { wait(process, selector, animations, before) }
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            default:
                continue
            }
            found.append(name)
        }
    }
}
