import CoreGraphics
import IOKit.pwr_mgt
import Foundation

/// How long since the person last touched the keyboard, mouse or trackpad, and whether something
/// (a video playing, a presentation) is asking the display to stay awake — the same signal the system screensaver respects.
enum IdleMonitor {
    static var secondsIdle: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    static var displaySleepIsHeld: Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let dict = status?.takeRetainedValue() as? [String: Int] else { return false }
        return (dict[kIOPMAssertPreventUserIdleDisplaySleep as String] ?? 0) > 0
    }
}
