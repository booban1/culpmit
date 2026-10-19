import AppKit
import UniformTypeIdentifiers

// Capped apps: each app in two rows, its name with what it uses now and its switch, then its two limits side by side:
// the CPU cap and the memory line it idles past while memory is short; then the picker to add more

extension Menu {
    func running(_ id: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated })
    }

    func applyApp(_ id: String) {
        let limiter = limiters[id] ?? Limiter()
        limiters[id] = limiter
        guard let entry = apps.first(where: { $0.id == id }), let app = running(id), idlers[app.processIdentifier] == nil else {
            limiter.stop()
            return
        }
        guard entry.on else {
            limiter.stop()
            return
        }
        if limiter.isRunning, limiter.root == app.processIdentifier {
            limiter.setCPUs(entry.level * threads)
        } else {
            for p in Limiter.tree(of: app.processIdentifier) { kill(p, SIGCONT) }
            limiter.start(root: app.processIdentifier, cpus: entry.level * threads)
        }
    }

    // Cap slows an app at once: its ceiling goes to half of what it uses now, in 5% steps within the cap range
    func capHalf(_ pid: pid_t) {
        guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid) else { return }
        let use = topHogs(snapshot().byPid, count: 30).first { $0.pid == pid }?.cpu ?? 100
        cap(app, at: min(capRange.upperBound, max(capRange.lowerBound, (use / 200 / 0.05).rounded(.down) * 0.05)))
    }

    func cap(_ app: NSRunningApplication, at level: Double) {
        // a cap on Culpmit would stop the capping
        guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, let url = app.bundleURL else { return }
        if let i = apps.firstIndex(where: { $0.id == id }) {
            apps[i].level = min(apps[i].level, level)
            apps[i].on = true
        } else {
            apps.append(CappedApp(id: id, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                  path: url.path, level: level, on: true))
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        saveApps(apps)
        applyApp(id)
    }

    func addCappedSection(removing: Bool) {
        // the heading carries the cap on a dev server run through cpulimit, read from its command line, at its far right
        let head = kit.row("Capped apps", "Dev server: –", bold: true, template: "Dev server: 100%")
        head.value?.alignment = .right
        devCapLabel = head.value
        menu.addItem(head.item)
        for (i, entry) in apps.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            menu.addItem(appRow(entry, removing: removing))
            if !removing { menu.addItem(limitsRow(entry)) }
        }
        // adding and removing are deliberate: both show while Option is held as the menu opens
        if removing {
            if !apps.isEmpty { menu.addItem(.separator()) }
            let add = NSMenuItem(title: "Add app…", action: #selector(addApp), keyEquivalent: "")
            add.target = self
            add.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add")
            menu.addItem(add)
        }
        menu.addItem(.separator())
    }

    // what each running capped app uses now, CPU share then memory
    func tickCapped(_ snap: Snapshot) {
        for entry in apps {
            guard let use = appUse[entry.id] else { continue }
            guard let app = running(entry.id) else {
                use.stringValue = "–"
                continue
            }
            let tree = Limiter.tree(of: app.processIdentifier)
            let bytes = tree.reduce(0.0) { $0 + (footprint($1) ?? 0) }
            use.stringValue = percent(tree.reduce(0.0) { $0 + (snap.byPid[$1] ?? 0) }) + (bytes > 0 ? " · " + gigabytes(bytes) : "")
        }
    }

    func capText(_ level: Double) -> String { percent(level * 100) }

    func appRow(_ entry: CappedApp, removing: Bool) -> NSMenuItem {
        let icon = NSWorkspace.shared.icon(forFile: entry.path)
        icon.size = NSSize(width: 18, height: 18)
        let row = kit.row(entry.name, "–", image: icon, template: "100% · 88.8 GB")
        appUse[entry.id] = row.value
        if removing {
            let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove")!,
                                  target: self, action: #selector(removeApp(_:)))
            remove.isBordered = false
            remove.contentTintColor = .systemRed
            remove.identifier = NSUserInterfaceItemIdentifier(entry.id)
            remove.sizeToFit()
            kit.attach([remove], to: row.item, outermost: true)
        } else {
            kit.attach([switchControl("app:" + entry.id, entry.on)], to: row.item, outermost: true)
        }
        return row.item
    }

    // the two limits under the app: the CPU cap, then the memory line; a cap that is off shows both dimmed and still
    func limitsRow(_ entry: CappedApp) -> NSMenuItem {
        let item = kit.row("").item
        let cap = kit.valueField(capText(entry.level), template: "100%")
        capLabels[entry.id] = cap
        let capSlider = limitSlider(entry.level, capRange.lowerBound, capRange.upperBound, entry.id, #selector(appSlid(_:)))
        capSlider.toolTip = "CPU cap"
        capSliders[entry.id] = capSlider
        let line = kit.valueField(lineText(entry.line), template: lineText(lineRange.upperBound))
        memLabels[entry.id] = line
        let lineSlider = limitSlider(entry.line, lineRange.lowerBound, lineRange.upperBound, entry.id, #selector(memSlid(_:)))
        lineSlider.toolTip = "Memory line"
        memSliders[entry.id] = lineSlider
        for v in [capSlider, cap, lineSlider, line] as [NSView] { v.alphaValue = entry.on ? 1 : 0.4 }
        capSlider.isEnabled = entry.on
        lineSlider.isEnabled = entry.on
        // from the row's left edge, under the app's icon: gauge, slider, cap, then chip, slider, line
        kit.lead([symbolView("gauge.with.dots.needle.50percent", "CPU cap"), capSlider, cap,
                  symbolView("memorychip", "Memory line"), lineSlider, line], in: item, from: 22)
        return item
    }

    private func limitSlider(_ value: Double, _ min: Double, _ max: Double, _ id: String, _ action: Selector) -> NSSlider {
        let slider = kit.slider(value, min, max, target: self, action: action)
        slider.identifier = NSUserInterfaceItemIdentifier(id)
        return slider
    }

    private func symbolView(_ name: String, _ tip: String) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: tip)!
            .withSymbolConfiguration(.init(pointSize: kit.size, weight: .regular))!)
        view.contentTintColor = .labelColor
        view.toolTip = tip
        view.frame.size = NSSize(width: 18, height: 18)
        return view
    }


    @objc func appSlid(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue, let i = apps.firstIndex(where: { $0.id == id }) else { return }
        let level = (sender.doubleValue * 20).rounded() / 20
        sender.doubleValue = level
        capLabels[id]?.stringValue = capText(level)
        guard apps[i].level != level else { return }
        apps[i].level = level
        saveApps(apps)
        applyApp(id)
    }

    @objc func memSlid(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue, let i = apps.firstIndex(where: { $0.id == id }) else { return }
        let line = snapLine(sender.doubleValue)
        sender.doubleValue = line
        memLabels[id]?.stringValue = lineText(line)
        guard apps[i].line != line else { return }
        apps[i].memoryLine = line
        saveApps(apps)
    }

    // a cap that is off shows its last limits dimmed and still; its switch brings them back
    func dimCap(_ id: String, on: Bool) {
        capSliders[id]?.isEnabled = on
        memSliders[id]?.isEnabled = on
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            for view in [capSliders[id], capLabels[id], memSliders[id], memLabels[id]] as [NSView?] {
                view?.animator().alphaValue = on ? 1 : 0.4
            }
        }
    }

    @objc func removeApp(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        removeCapped(id)
        menu.cancelTracking()
    }

    func removeCapped(_ id: String) {
        apps.removeAll { $0.id == id }
        saveApps(apps)
        applyApp(id)
    }

    @objc func addApp() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Cap"
        panel.message = "Choose apps to cap"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  !apps.contains(where: { $0.id == id }) else { continue }
            apps.append(CappedApp(id: id, name: url.deletingPathExtension().lastPathComponent, path: url.path, level: 0.5, on: true))
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            saveApps(apps)
            applyApp(id)
        }
    }
}
