import AppKit

// Busy apps: idled apps, the apps past the busy line, then the three holding the most memory, one row each: the app's
// icon (its name shows on hover), its CPU share and memory beside their icons, Idle and Cap. Three in the menu, up to
// six more under "N more"; the section shows while one is listed.

struct HogSlot {
    let row: Row
    let cpu: NSTextField
    let memory: NSTextField
    let idle: NSButton
    let cap: NSButton
    let trailing: [NSView]
}

extension Menu {
    func addBusiestSection() {
        let head = kit.head("Busy apps")
        menu.addItem(head)
        busiestItems.append(head)
        for _ in 0..<4 {
            let slot = makeHogSlot()
            hogSlots.append(slot)
            menu.addItem(slot.row.item)
        }
        let rest = NSMenu()
        for _ in 0..<6 {
            let slot = makeHogSlot()
            moreSlots.append(slot)
            rest.addItem(slot.row.item)
        }
        let more = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        more.submenu = rest
        more.isHidden = true
        moreItem = more
        menu.addItem(more)
        let end = NSMenuItem.separator()
        menu.addItem(end)
        busiestItems.append(end)
    }

    // the figures read from the left after the icon; Idle and Cap sit at the right edge
    func makeHogSlot() -> HogSlot {
        let blank = NSImage(size: NSSize(width: 18, height: 18))
        let row = kit.row("", image: blank)
        let cpu = kit.valueField("–", template: "100%")
        let memory = kit.valueField("–", template: "88.8 GB")
        kit.lead([figureIcon("gauge.with.dots.needle.50percent", "CPU share"), cpu, figureIcon("memorychip", "Memory"), memory],
                 in: row.item, from: 50)
        // a moon idles the app, a tortoise caps it; each keeps its icon, turns red while on, and names its click on hover
        let idle = actionIcon("moon.zzz", "Idle", #selector(idleHog(_:)))
        let cap = actionIcon("tortoise", "Cap", #selector(capHog(_:)))
        kit.attach([idle, cap], to: row.item)
        row.item.isHidden = true
        return HogSlot(row: row, cpu: cpu, memory: memory, idle: idle, cap: cap, trailing: [idle, cap])
    }

    func symbolImage(_ name: String, _ tip: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: tip)?.withSymbolConfiguration(.init(pointSize: kit.size, weight: .regular))
    }

    private func actionIcon(_ name: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: symbolImage(name, tip) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.frame.size = NSSize(width: 24, height: 20)
        return button
    }

    func figureIcon(_ name: String, _ tip: String) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: tip)!
            .withSymbolConfiguration(.init(pointSize: kit.size, weight: .regular))!)
        view.contentTintColor = .labelColor
        view.toolTip = tip
        view.frame.size = NSSize(width: 18, height: 18)
        return view
    }

    // the apps worth a look, each once: idled, past the busy line, then the three holding the most memory; the menu
    // and the Touch Bar share it
    func listedApps(_ snap: Snapshot) -> [Hog] {
        let busyHogs = withIdled(busy.update(snap.byPid, count: 9), snap.byPid)
        let heavy = topHogs(snap.byPid, count: 3, byMemory: true).filter { h in !busyHogs.contains { $0.pid == h.pid } }
        return Array((busyHogs + heavy).prefix(9))
    }

    // while the menu is open each row keeps its app, so a row holds still under the pointer; the figures stay live, and
    // the order is drawn afresh at the next open
    func updateHogs(_ snap: Snapshot) {
        if shaping { shownHogs = listedApps(snap) }
        let hogs = shaping ? shownHogs : shownHogs.map { refreshed($0, snap) }
        for i in busiestItems { show(i, !hogs.isEmpty) }
        // the + row holds two apps at least: up to four apps show as rows, five and more show three and the + row
        let rows = hogs.count >= 5 ? 3 : hogs.count
        let rest = Array(hogs.dropFirst(rows))
        if shaping { moreItem?.attributedTitle = moreTitle(rest) }
        show(moreItem, rest.count >= 2)
        for (i, slot) in hogSlots.enumerated() { fill(slot, i < rows ? hogs[i] : nil) }
        for (i, slot) in moreSlots.enumerated() { fill(slot, i < rest.count ? rest[i] : nil) }
    }

    private func fill(_ slot: HogSlot, _ hog: Hog?) {
        guard let hog else {
            show(slot.row.item, false)
            slot.idle.isHidden = true
            slot.cap.isHidden = true
            return
        }
        show(slot.row.item, true)
        var image: NSImage?
        if let url = hog.app?.bundleURL {
            image = NSWorkspace.shared.icon(forFile: url.path)
            slot.row.icon?.contentTintColor = nil
        } else {
            image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            slot.row.icon?.contentTintColor = .labelColor
        }
        image?.size = NSSize(width: 18, height: 18)
        slot.row.icon?.image = image
        if slot.row.view.toolTip != hog.name {
            slot.row.icon?.toolTip = hog.name
            slot.row.view.toolTip = hog.name
        }
        slot.cpu.stringValue = percent(hog.cpu)
        slot.memory.stringValue = hog.memory > 0 ? gigabytes(hog.memory) : "–"
        slot.idle.tag = Int(hog.pid)
        let idled = isIdled(hog.pid)
        setIcon(slot.idle, "moon.zzz", idled ? "Wake" : "Idle", active: idled)
        slot.idle.isHidden = !canIdle(hog.pid)
        slot.cap.tag = Int(hog.pid)
        if let app = hog.app, let id = app.bundleIdentifier, app.bundleURL != nil, hog.pid != getpid() {
            let cap = apps.first { $0.id == id && $0.on }
            setIcon(slot.cap, "tortoise", cap == nil ? "Cap" : "Uncap", active: cap != nil)
            slot.cap.isHidden = false
        } else {
            slot.cap.isHidden = true
        }
        RowKit.place(slot.trailing, in: slot.row.view)
    }

    // + followed by the icons of the apps it holds; the menu draws its › at the end
    private func moreTitle(_ rest: [Hog]) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: kit.size)
        let title = NSMutableAttributedString(string: "+  ", attributes: [.font: font])
        for hog in rest {
            let attachment = NSTextAttachment()
            attachment.image = hog.app?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "gearshape", accessibilityDescription: hog.name)
            attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }
        return title
    }

    // an app's figures now, over its process tree; memory keeps its last reading where macOS keeps it private
    private func refreshed(_ hog: Hog, _ snap: Snapshot) -> Hog {
        let tree = Limiter.tree(of: hog.pid)
        let memory = tree.reduce(0.0) { $0 + (footprint($1) ?? 0) }
        return Hog(name: hog.name, cpu: tree.reduce(0.0) { $0 + (snap.byPid[$1] ?? 0) }, memory: memory > 0 ? memory : hog.memory,
                   app: hog.app, pid: hog.pid, mine: hog.mine)
    }

    // a new icon and tooltip only when the state changes, so a hover's tooltip and a click in progress hold; an active
    // cap or idle turns red
    private func setIcon(_ button: NSButton, _ symbol: String, _ tip: String, active: Bool) {
        guard button.toolTip != tip else { return }
        button.image = symbolImage(symbol, tip)
        button.toolTip = tip
        button.contentTintColor = active ? .systemRed : .labelColor
    }

    @objc func idleHog(_ sender: NSButton) {
        toggleIdle(pid_t(sender.tag))
        tick()
    }

    // the tortoise caps an app at half of what it uses; once capped, a click lifts the cap
    @objc func capHog(_ sender: NSButton) {
        let pid = pid_t(sender.tag)
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, apps.contains(where: { $0.id == id && $0.on }) {
            apply("app:" + id, false)
        } else {
            capHalf(pid)
        }
        tick()
    }
}
