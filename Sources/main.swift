import AppKit
import ServiceManagement
import UserNotifications

// Culpmit starts here: settings, the test flags, then the menu bar app

registerDefaults()

if CommandLine.arguments.contains("--touchbar-test") {
    NSApplication.shared.setActivationPolicy(.accessory)
    let test = TouchBarStrip()
    test.readout = { [("50°", nil), ("1,840", nil), ("5%", nil)] }
    test.toggles = { ["awake": true, "shrink": true] }
    test.busiest = { topHogs(snapshot().byPid) }
    test.cappedApps = { loadApps() }
    test.clipItems = { [.text("npm run dev"), .text("example.com")] }
    test.show()
    print("shown", test.isShown)
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    test.open()
    print("opened")
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    test.hide()
    print("hidden", !test.isShown)
    exit(0)
}

if CommandLine.arguments.contains("--test-alert") {
    Alerts().post("test", title: "Culpmit", body: "Notifications reach you. Heat alerts will look like this.")
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    exit(0)
}

if CommandLine.arguments.contains("--status") {
    let smc = SMC()
    let meter = LoadMeter()
    _ = meter.sample()
    Thread.sleep(forTimeInterval: 1)
    print("temperature", smc?.cpuTemperature().map { String(format: "%.1f", $0) } ?? "–")
    print("sensor", smc?.cpuSensor ?? "–", "on", machineModel, Radios.hasLid ? "laptop" : "desktop")
    print("fans", smc?.fans().map { Int($0.rounded()) } ?? [])
    print("load", meter.sample().map { percent($0) } ?? "–")
    if let m = memoryReading() {
        print("memory", String(format: "%.1f of %.0f GB", m.used / gib, m.total / gib), "pressure", m.pressure.name.lowercased(),
              "swap", gigabytes(m.swap))
    }
    print("login", loginState)
    print("holders", sleepHolders())
    print("lid", Radios.lidClosed ? "closed" : "open", "wifi", Radios().wifi ? "on" : "off", "wake", wakeReason())
    print("capped", loadApps().map { "\($0.name) \(Int($0.level * 100))% \($0.on ? "on" : "off")" })
    let snap = snapshot()
    print("busiest", topHogs(snap.byPid).map { "\($0.name) \(Int($0.cpu.rounded()))% \(gigabytes($0.memory))" }, "dev cap", snap.devCap)
    print("heaviest", topHogs(snap.byPid, byMemory: true).map { "\($0.name) \(gigabytes($0.memory))" })
    print("servers", localServers().map { "\($0.port) \($0.name)" })
    let updater = Updater()
    print("version", updater.installed, "commit", updater.commit, updater.local ? "local" : "release")
    print("touch bar", TouchBarStrip().available ? "available" : "unavailable", "figma socket", FigmaSocket().lookupListener() != nil ? "on" : "off")
    let done = DispatchSemaphore(value: 0)
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        print("notifications", ["not asked", "denied", "allowed", "provisional", "ephemeral"][min(settings.authorizationStatus.rawValue, 4)])
        done.signal()
    }
    _ = done.wait(timeout: .now() + 3)
    exit(0)
}

settleCopies()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// App Nap stays away and every timer fires on the dot, however busy the Mac
let steady = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                   reason: "Clipboard, app caps and sensors run on timers")
let menuBar = Menu()
app.delegate = menuBar
app.run()
