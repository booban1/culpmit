import Foundation
import CoreWLAN
import IOKit

// Wi-Fi and Bluetooth off while the Mac sleeps, back on when it wakes

final class Radios {
    private let bluetoothLib = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    private var wifiOff = false
    private var bluetoothOff = false

    var bluetooth: Bool {
        guard let f = dlsym(bluetoothLib, "IOBluetoothPreferenceGetControllerPowerState") else { return false }
        return unsafeBitCast(f, to: (@convention(c) () -> Int32).self)() != 0
    }

    func setBluetooth(_ on: Bool) {
        guard let f = dlsym(bluetoothLib, "IOBluetoothPreferenceSetControllerPowerState") else { return }
        unsafeBitCast(f, to: (@convention(c) (Int32) -> Void).self)(on ? 1 : 0)
    }

    var wifi: Bool { CWWiFiClient.shared().interface()?.powerOn() ?? false }

    func setWifi(_ on: Bool) { try? CWWiFiClient.shared().interface()?.setPower(on) }

    // a clamshell state, or a MacBook model name, marks a laptop
    static var hasLid: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return state != nil || machineModel.hasPrefix("MacBook")
    }

    static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    func sleeping() {
        if wifi {
            setWifi(false)
            wifiOff = true
        }
        if bluetooth {
            setBluetooth(false)
            bluetoothOff = true
        }
        note("sleep, lid \(Radios.lidClosed ? "closed" : "open"): Wi-Fi off \(wifiOff), Bluetooth off \(bluetoothOff)")
    }

    func woke() {
        guard wifiOff || bluetoothOff else { return }
        if wifiOff { setWifi(true) }
        if bluetoothOff { setBluetooth(true) }
        note("wake: Wi-Fi back \(wifiOff), Bluetooth back \(bluetoothOff)")
        wifiOff = false
        bluetoothOff = false
    }
}
