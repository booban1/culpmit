import AppKit

// Test load, its own section after Sleep: six test apps inside Culpmit keep every thread busy for the Duration on
// its slider, and a seventh fills memory until it runs short, capped with its memory line at the least, so Busy apps,
// the Touch Bar, the heat alert, the memory alert and the memory line show Culpmit at work. For that time the switches
// it exercises hold on; at the end the apps quit and leave Capped apps, and each switch returns to where it stood.
// Switched back on within a minute of an early stop, by hand, by Everything off, or by Culpmit quitting or crashing,
// the same run picks up where it was.

let testPrefix = "com.simonbooban.culpmit.test"
// what a test exercises, held on for its run: Caffeinate, both alerts, the Touch Bar, Shrink images, Keep history
let testHolds = ["awake", "heatAlerts", "cpuAlerts", "memoryAlerts", "touchBar", "shrink", "history"]
// the Duration slider's stops in minutes: ones for a quick look, then fives up to half an hour; the test apps quit
// on their own a minute past the longest
let testStops: [Double] = [1, 2, 3, 4, 5, 10, 15, 20, 25, 30]
// each test app's share of the Mac in sixteenths, so the six fill every thread on any Mac
private let testWeights = [4, 3, 3, 2, 2, 2]

extension Menu {
    var testing: Bool { testTimer != nil }
    var testMinutes: Double { store.double(forKey: "testMinutes") }

    func startTest() {
        guard !testing else { return }
        // within a minute of an early stop the run keeps its start, so its end, its alerts' counts and the switches to
        // return at the end all carry on
        let run = store.dictionary(forKey: "testRun")
        let started = run?["started"] as? Date, stopped = run?["stopped"] as? Date
        let resumed = stopped.map { Date().timeIntervalSince($0) < 60 } == true
            && started.map { $0.addingTimeInterval(testMinutes * 60).timeIntervalSinceNow > 5 } == true
        if resumed, let started {
            testStarted = started
            testBefore = run?["before"] as? [String: Bool] ?? [:]
        } else {
            testStarted = Date()
            testBefore = Dictionary(uniqueKeysWithValues: testHolds.map { ($0, isOn($0)) })
            // a fresh run's own alerts come through, whatever came before
            hotSince = nil
            lastHeatAlert = .distantPast
            memHighSince = nil
            lastMemoryAlert = .distantPast
            loadClock = AlertClock()
            hotTemp = AlertClock()
            hotLoad = AlertClock()
            hotMemory = AlertClock()
        }
        store.set(["started": testStarted, "before": testBefore], forKey: "testRun")
        launchTestApps()
        for key in testHolds where key != "touchBar" || strip.available { apply(key, true) }
        scheduleTestEnd()
        let length = minutes(testMinutes, long: true)
        let left = minutes(testStarted.addingTimeInterval(testMinutes * 60).timeIntervalSinceNow / 60, long: true)
        let watch = strip.available ? "Busy apps and the Touch Bar" : "Busy apps"
        // the menu steps aside so the notification shows
        menu.cancelTracking()
        alerts.ask { [weak self] in
            guard let self else { return }
            if resumed {
                self.alerts.post("test", title: "Test load continues",
                                 body: "Back on within a minute, so the same run goes on: \(left) left.")
            } else {
                self.alerts.post("test", title: "Test load for \(length)",
                                 body: "Test Load 1 to 6 keep every core busy and Test Load 7 fills memory until it runs short. Watch \(watch) and try Cap or Idle on them. Culpmit's switches stay on until the test ends.")
            }
        }
    }

    private func launchTestApps() {
        for (i, weight) in testWeights.enumerated() {
            let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Test Load \(i + 1).app")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            config.arguments = ["\(max(1, Int((Double(weight) * threads / 16).rounded())))", "\(Int(testStops[testStops.count - 1] * 60 + 60))"]
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
                guard let app else { return }
                DispatchQueue.main.async { self.testApps.append(app) }
            }
        }
        // Test Load 7 holds memory and joins Capped apps with its memory line at the least, so it idles once memory runs short
        let memory = NSWorkspace.OpenConfiguration()
        memory.activates = false
        memory.addsToRecentItems = false
        // room to reach shortage from a quiet Mac too; the fill stops at the first sign of it
        memory.arguments = ["0", "\(Int(testStops[testStops.count - 1] * 60 + 60))", "\(Int(0.75 * ramGB * gib))",
                            "\(Int((memoryAlertLine * ramGB + 0.5) * gib))"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Test Load 7.app"),
                                           configuration: memory) { app, _ in
            guard let app else { return }
            DispatchQueue.main.async {
                self.testApps.append(app)
                self.cap(app, at: capRange.upperBound)
                if let i = self.apps.firstIndex(where: { $0.id == app.bundleIdentifier }) {
                    self.apps[i].memoryLine = lineRange.lowerBound
                    saveApps(self.apps)
                }
            }
        }
    }

    // the end follows the slider, so a longer or shorter length counts from the start
    func scheduleTestEnd() {
        testTimer?.invalidate()
        let left = testStarted.addingTimeInterval(testMinutes * 60).timeIntervalSinceNow
        testTimer = Timer.scheduledTimer(withTimeInterval: max(1, left), repeats: false) { [weak self] _ in self?.stopTest(finished: true) }
    }

    // a finished run clears its record; an early stop keeps it, marked with the time, for a minute's pick-up
    func stopTest(finished: Bool = false) {
        guard testing else { return }
        testTimer?.invalidate()
        testTimer = nil
        quitTestApps()
        if finished {
            store.removeObject(forKey: "testRun")
        } else if var run = store.dictionary(forKey: "testRun") {
            run["stopped"] = Date()
            store.set(run, forKey: "testRun")
        }
        for (key, was) in testBefore where !was && isOn(key) { apply(key, false) }
        showLine("testLoad", false)
    }

    // a run cut short by a crash counts as stopped at the relaunch: its test apps quit and its switches return
    func settleTestRun() {
        guard var run = store.dictionary(forKey: "testRun"), run["stopped"] == nil else { return }
        quitTestApps()
        for (key, was) in run["before"] as? [String: Bool] ?? [:] where !was && isOn(key) { apply(key, false) }
        run["stopped"] = Date()
        store.set(run, forKey: "testRun")
    }

    // every test app quits, an earlier Culpmit's included, and leaves Capped apps
    private func quitTestApps() {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier?.hasPrefix(testPrefix) == true {
            kill(app.processIdentifier, SIGTERM)
            kill(app.processIdentifier, SIGCONT)
        }
        testApps = []
        for id in apps.map(\.id) where id.hasPrefix(testPrefix) { removeCapped(id) }
    }

    // a switch's state as the menu shows it
    func isOn(_ key: String) -> Bool {
        switch key {
        case "awake": return awake.isOn
        case "touchBar": return strip.isShown
        case "shrink": return shrinker.isOn
        case "history": return clips.isOn
        default: return store.bool(forKey: key)
        }
    }

    // one row after Sleep's switches, like the alerts: the name, its duration on a slider (usable before a run, and a
    // change mid-run moves the end), and the switch at the end
    func addTestSection() {
        let value = kit.valueField(minutes(testMinutes), template: minutes(testStops[testStops.count - 1]))
        testDurationLabel = value
        let stop = Double(testStops.firstIndex { $0 >= testMinutes } ?? testStops.count - 1)
        let slider = kit.slider(stop, 0, Double(testStops.count - 1), target: self, action: #selector(testSlid(_:)))
        // the alerts follow in the same group
        menu.addItem(lineRow("Test load", "testLoad", testing, slider, value, live: true))
    }

    @objc func testSlid(_ sender: NSSlider) {
        let stop = min(testStops.count - 1, max(0, Int(sender.doubleValue.rounded())))
        sender.doubleValue = Double(stop)
        let length = testStops[stop]
        testDurationLabel?.stringValue = minutes(length)
        guard length != testMinutes else { return }
        store.set(length, forKey: "testMinutes")
        if testing { scheduleTestEnd() }
    }

    private func minutes(_ m: Double, long: Bool = false) -> String {
        let n = max(1, Int(m.rounded(.up)))
        return long ? "\(n) minute\(n == 1 ? "" : "s")" : "\(n) min"
    }
}
