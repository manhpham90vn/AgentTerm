#if os(macOS)
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac from going to sleep by itself while it is held, the way
/// `caffeinate -i` does, and the display too when asked (`caffeinate -d`).
/// Closing the lid or choosing Sleep still puts the Mac to sleep: nothing
/// an app does prevents those.
final class SleepGuard {
    private var assertion: IOPMAssertionID = 0
    private(set) var isHeld = false
    /// Whether the hold in effect keeps the display on as well.
    private(set) var holdsDisplay = false

    /// Holds or lets go. Returns false when macOS refused the hold.
    @discardableResult
    func set(held: Bool, display: Bool = false, reason: String = "AgentTerm sessions are running") -> Bool {
        guard held != isHeld || (held && display != holdsDisplay) else { return true }
        if isHeld {
            IOPMAssertionRelease(assertion)
            assertion = 0
            isHeld = false
            holdsDisplay = false
        }
        guard held else { return true }
        // Keeping the display on keeps the Mac awake with it.
        let type = display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion)
        isHeld = result == kIOReturnSuccess
        holdsDisplay = isHeld && display
        return isHeld
    }

    deinit { if isHeld { IOPMAssertionRelease(assertion) } }
}

/// What the Mac is running on.
public enum PowerSource {
    /// True when the Mac is plugged in. A Mac without a battery always is.
    public static var isOnPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return true }
        return (type as String) != kIOPMBatteryPowerKey
    }
}
#endif
