import AppKit

// The menu bar app: owns every feature and the timers. The menu is built on open, one section per file,
// and kept live every second while it stays open.

final class Menu: NSObject, NSMenuDelegate, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let kit = RowKit()
    let smc = SMC()
    let meter = LoadMeter()
    let shrinker = Shrinker()
    let awake = Awake()
    let radios = Radios()
    let clips = Clips()
    let alerts = Alerts()
    let updater = Updater()
    let figma = FigmaSocket()
    let strip = TouchBarStrip()
    var stripKey: HotKey?
    let busy = BusyList()
    var apps = loadApps()
    var limiters: [String: Limiter] = [:]
    var idlers: [pid_t: Limiter] = [:]
    var servers: [LocalServer] = []
    var machineLoad = 0.0
    var signals: [DispatchSourceSignal] = []
    var hotSince: Date?
    var lastHeatAlert = Date.distantPast
    var updatingDots: Int?
    var updateMenuItem: NSMenuItem?
    var updateTicker: Timer?
    var updateDots = 0
    var testApps: [NSRunningApplication] = []
    var testTimer: Timer?
    var testStarted = Date()
    var testBefore: [String: Bool] = [:]
    var testDurationLabel: NSTextField?
    var heatLineLabel: NSTextField?
    var cpuLineLabel: NSTextField?
    var memoryAlertLabel: NSTextField?
    var memHighSince: Date?
    // each switch row's slider and value, dimmed while its switch is off; live keeps the slider usable then
    var lineParts: [String: (slider: NSSlider, value: NSTextField, live: Bool)] = [:]
    var shortSince: Date?
    var calmSince: Date?
    // the CPU alert's clock and the red alerts' clocks
    var loadClock = AlertClock()
    var hotTemp = AlertClock(), hotLoad = AlertClock(), hotMemory = AlertClock()
    // swap over the last minute, and the time memory counts as short after a jump into swap
    var swapSeen: [(at: Date, swap: Double)] = []
    var swapShortUntil = Date.distantPast
    var lastMemoryAlert = Date.distantPast
    // apps idled for memory, by pid with their bundle ID, and when each capped app last woke from it
    var autoIdled: [pid_t: String] = [:]
    var autoWoken: [String: Date] = [:]

    // live parts of the open menu
    var liveTimer: Timer?
    var ticks = 0
    var shaping = false
    var tempLabel: NSTextField?
    var loadLabel: NSTextField?
    var memoryStatLabel: NSTextField?
    var statTiles: StatTiles?
    var fansLabel: NSTextField?
    var devCapLabel: NSTextField?
    var limitLabel: NSTextField?
    var capLabels: [String: NSTextField] = [:]
    var capSliders: [String: NSSlider] = [:]
    var memLabels: [String: NSTextField] = [:]
    var memSliders: [String: NSSlider] = [:]
    var busiestItems: [NSMenuItem] = []
    var hogSlots: [HogSlot] = []
    // the apps the Busy rows show for this opening of the menu
    var shownHogs: [Hog] = []
    var moreSlots: [HogSlot] = []
    var moreItem: NSMenuItem?
    var appUse: [String: NSTextField] = [:]
    var holdersRow: Row?
    var switches: [String: NSSwitch] = [:]
    var historyMenuItem: NSMenuItem?
    var historyShown: [Clips.Item] = []
    var serversMenuItem: NSMenuItem?
    var serversShown: [LocalServer] = []

    override init() {
        super.init()
        menu.delegate = self
        item.menu = menu
        saveApps(apps)
        shrinker.limit = store.double(forKey: "shotLimit")
        if store.bool(forKey: "shrink") { shrinker.start() }
        if store.bool(forKey: "history") { clips.start() }
        migrateLogin()
        if store.bool(forKey: "setUp"), store.object(forKey: "welcomed") == nil { store.set(true, forKey: "welcomed") }
        if !store.bool(forKey: "setUp") {
            store.set(true, forKey: "setUp")
            // launchd's copy takes over once the agent loads, and it owes the new user the welcome
            store.set(false, forKey: "welcomed")
            openAtLogin = true
        }
        // the copy that stays drops the menu open once, so a new user sees where Culpmit lives
        if !store.bool(forKey: "welcomed") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard !store.bool(forKey: "welcomed") else { return }
                store.set(true, forKey: "welcomed")
                self?.item.button?.performClick(nil)
            }
        }
        alerts.onAction = { [weak self] action, info in self?.handle(action, info) }
        if ["heatAlerts", "cpuAlerts", "memoryAlerts"].contains(where: store.bool(forKey:)) { alerts.ask() }
        if store.bool(forKey: "figmaSocket") { figma.start() }
        setUpStrip()
        watchIdled()
        announceUpdate()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier,
                      self.apps.contains(where: { $0.id == id }) else { return }
                self.applyApp(id)
            }
        }
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            if store.bool(forKey: "radios") { self?.radios.sleeping() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.radios.woke()
            self?.checkLidWake()
        }
        if store.bool(forKey: "radios") { askBluetooth() }
        for s in [SIGTERM, SIGINT] {
            signal(s, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: s, queue: .main)
            source.setEventHandler { [weak self] in
                self?.shutdown()
                exit(0)
            }
            source.resume()
            signals.append(source)
        }
        settleTestRun()
        for a in apps { applyApp(a.id) }
        refreshBar()
        every(1) { [weak self] in self?.refreshBar() }
        updater.check()
    }

    func every(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        let t = Timer(timeInterval: seconds, repeats: true) { _ in work() }
        RunLoop.main.add(t, forMode: .common)
    }

    func shutdown() {
        stopTest()
        for l in limiters.values { l.stop() }
        for l in idlers.values { l.stop() }
        awake.set(false)
        radios.woke()
        figma.stopIfMine()
        strip.hide()
    }

    func applicationWillTerminate(_ notification: Notification) { shutdown() }

    func refreshBar() {
        let temp = smc?.cpuTemperature()
        let fans = smc?.fans() ?? []
        if let load = meter.sample() { machineLoad = load }
        let bottom = updatingDots.map(loadingDots) ?? fans.max().map { "\(Int($0.rounded()))" }
        // the menu bar's readout keeps the bar's own colour; colours live in the menu and on the Touch Bar
        item.button?.image = barImage(temp.map { "\(Int($0.rounded()))°" } ?? "–", bottom)
        if awake.isOn, let b = battery(), b.onBattery, b.percent < 20 { awake.set(false) }
        checkHot(temp)
        checkHeat(temp)
        checkLoad()
        checkMemory()
        strip.refresh()
    }

    // listening ports read straight from the kernel in milliseconds: when the menu opens, and every 5 s while it stays open
    func refreshServers() {
        let all = listeners()
        servers = localServers(all)
        figma.cachedListener = figma.lookupListener(all)
    }

    // MARK: the menu

    func menuWillOpen(_ menu: NSMenu) {
        strip.reclaim()
        updater.check()
        liveTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshServers()
        menu.removeAllItems()
        kit.reset()
        switches.removeAll()
        capLabels.removeAll()
        capSliders.removeAll()
        memLabels.removeAll()
        memSliders.removeAll()
        appUse.removeAll()
        busiestItems.removeAll()
        hogSlots.removeAll()
        moreSlots.removeAll()
        let snap = snapshot()
        addProcessorSection(snap)
        addBusiestSection()
        addCappedSection(removing: NSEvent.modifierFlags.contains(.option))
        addScreenshotsSection()
        addFigmaSection()
        addSleepSection()
        addTestSection()
        addAlertsSection()
        addFooterSection()
        kit.layout()
        shaping = true
        tick(snap)
        shaping = false
    }

    // rows appear and vanish only as the menu opens, so the rows under the pointer stay put
    func show(_ item: NSMenuItem?, _ visible: Bool) {
        if shaping { item?.isHidden = !visible }
    }

    func tick(_ given: Snapshot? = nil) {
        let snap = given ?? snapshot()
        ticks += 1
        if ticks % 5 == 0 { refreshServers() }
        tickProcessor(snap)
        updateHogs(snap)
        tickCapped(snap)
        tickSleep()
        tickSwitches()
        tickHistory()
        tickServers()
    }
}
