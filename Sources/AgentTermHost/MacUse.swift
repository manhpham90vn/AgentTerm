#if os(macOS)
import Foundation
import IOKit

/// Whether someone is at the Mac, as macOS knows it.
public enum MacUse {
    /// How long since a key or the pointer was used, in seconds: what
    /// macOS keeps as `HIDIdleTime`. Nil when it cannot be read.
    public static func idleSeconds() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        else { return nil }
        return value.doubleValue / 1_000_000_000
    }
}
#endif
