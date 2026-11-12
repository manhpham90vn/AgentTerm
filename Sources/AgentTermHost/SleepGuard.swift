#if os(macOS)
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from going to sleep by itself while it is held, the way
/// `caffeinate -i` does. The display may still sleep, and closing the lid
/// or choosing Sleep still puts the Mac to sleep: nothing an app does
/// prevents those.
final class SleepGuard {
    private var assertion: IOPMAssertionID = 0
    private(set) var isHeld = false

    /// Holds or lets go. Returns false when macOS refused the hold.
    @discardableResult
    func set(held: Bool, reason: String = "AgentTerm sessions are running") -> Bool {
        guard held != isHeld else { return true }
        if held {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion)
            isHeld = result == kIOReturnSuccess
            return isHeld
        }
        IOPMAssertionRelease(assertion)
        assertion = 0
        isHeld = false
        return true
    }

    deinit { if isHeld { IOPMAssertionRelease(assertion) } }
}
#endif
