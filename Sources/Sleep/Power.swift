import AppKit
import CoreGraphics

// Wake reason and idle time, for sending an untouched lid open back to sleep

func wakeReason() -> String {
    var size = 0
    guard sysctlbyname("kern.wakereason", nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.wakereason", &buffer, &size, nil, 0) == 0 else { return "" }
    return String(cString: buffer)
}

func idleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
}
