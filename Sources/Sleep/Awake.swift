import AppKit
import IOKit.ps
import IOKit.pwr_mgt

// Caffeinate, what else keeps the Mac awake, and the battery reading that switches Caffeinate off under 20%

final class Awake {
    private var id: IOPMAssertionID = 0

    var isOn: Bool { id != 0 }

    func set(_ on: Bool) {
        if on, id == 0 {
            var new: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), "Culpmit keep awake" as CFString, &new) == kIOReturnSuccess {
                id = new
            }
        } else if !on, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}

// Apps holding the Mac awake; macOS's own background services (sharingd, useractivityd and the like) stay out
func sleepHolders() -> [String] {
    let appPids = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
    var names: [String] = []
    for line in run("/usr/bin/pmset", ["-g", "assertions"]).out.split(separator: "\n") {
        guard line.contains("pid "), line.contains("PreventUserIdleSystemSleep") || line.contains("PreventSystemSleep"),
              let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")"),
              let p = line.range(of: #"pid \d+"#, options: .regularExpression), let pid = pid_t(line[p].dropFirst(4)) else { continue }
        var name = String(line[line.index(after: open)..<close])
        var isApp = appPids.contains(pid)
        if name == "runningboardd", let r = line.range(of: #"application\.[A-Za-z0-9.\-]+"#, options: .regularExpression) {
            name = line[r].split(separator: ".").filter { Int($0) == nil }.last.map(String.init) ?? name
            isApp = true
        } else if name == "caffeinate", let parent = parentOf(pid) {
            name = processName(parent)
            isApp = true
        }
        if name == "claude" { name = "Claude Code" }
        if isApp, !names.contains(name) { names.append(name) }
    }
    return names
}

func battery() -> (onBattery: Bool, percent: Int)? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in list {
        guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let now = d[kIOPSCurrentCapacityKey] as? Int, let full = d[kIOPSMaxCapacityKey] as? Int, full > 0 else { continue }
        return ((d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue, now * 100 / full)
    }
    return nil
}
