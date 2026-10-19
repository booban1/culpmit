import AppKit

// Culpmit on the Touch Bar: a Control Strip icon that opens a strip of values, switches, clipboard items,
// capped apps and the busiest apps. The Control Strip calls are private to macOS, so each is checked before use.

private let stripID = NSTouchBarItem.Identifier("com.simonbooban.culpmit.strip")
private let mainID = NSTouchBarItem.Identifier("com.simonbooban.culpmit.main")
// three app icons with their gaps: the apps group's width while the clipboard needs the room
private let threeApps: CGFloat = 3 * 30 + 2 * 6

final class TouchBarStrip: NSObject, NSTouchBarDelegate {
    private let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)
    private let addTray = Selector(("addSystemTrayItem:"))
    private let removeTray = Selector(("removeSystemTrayItem:"))
    private let present = Selector(("presentSystemModalTouchBar:systemTrayItemIdentifier:"))
    private let dismiss = Selector(("dismissSystemModalTouchBar:"))

    private var stripItem: NSCustomTouchBarItem?
    // one bar, presented again on each open; screens swap what its one item holds
    private lazy var bar: NSTouchBar = {
        let tb = NSTouchBar()
        tb.delegate = self
        tb.defaultItemIdentifiers = [mainID]
        return tb
    }()
    private var opened = false
    private var screen = "main"
    // the middle of the item touched, so its screen grows out of it and the strip settles back around it
    private var origin: CGFloat = 0
    private lazy var frame: NSStackView = {
        let s = row([])
        s.setClippingResistancePriority(.defaultLow, for: .horizontal)
        return s
    }()
    // inner screens stretch across the bar; the empty end takes the spare room, and a tap there goes back
    private lazy var fullWidth = frame.widthAnchor.constraint(equalToConstant: 0)
    private lazy var blank: NSView = {
        let v = NSView()
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        v.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        v.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let tap = NSClickGestureRecognizer(target: self, action: #selector(blankTapped))
        tap.allowedTouchTypes = .direct
        v.addGestureRecognizer(tap)
        return v
    }()
    // the main strip keeps its views; only the groups that come and go rebuild it
    private lazy var mainStack = row([])
    private var shape = ""
    private lazy var readoutLabel: NSTextField = {
        let l = NSTextField(labelWithString: "88° · 8,888 · 100% · 88 GB")
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        l.widthAnchor.constraint(equalToConstant: ceil(l.fittingSize.width)).isActive = true
        l.addGestureRecognizer(holdRecognizer(#selector(holdReadout(_:))))
        let tap = NSClickGestureRecognizer(target: self, action: #selector(tapReadout))
        tap.allowedTouchTypes = .direct
        l.addGestureRecognizer(tap)
        // a hold's screen, reachable by VoiceOver and scripts too
        let details = [NSAccessibilityCustomAction(name: "Details") { [weak self] in
            self?.openReadout()
            return true
        }]
        l.setAccessibilityCustomActions(details)
        l.cell?.setAccessibilityCustomActions(details)
        return l
    }()
    private lazy var switchRow: NSStackView = row(switchSet.map { s -> NSView in
        let b = iconButton(symbol(s.symbol)!, #selector(tapSwitch(_:)))
        b.identifier = NSUserInterfaceItemIdentifier(s.key)
        toggleButtons[s.key] = b
        b.addGestureRecognizer(holdRecognizer(#selector(holdSwitch(_:))))
        let details = [NSAccessibilityCustomAction(name: "Details") { [weak self, weak b] in
            guard let b else { return false }
            self?.openSwitch(s.key, from: b)
            return true
        }]
        b.setAccessibilityCustomActions(details)
        b.cell?.setAccessibilityCustomActions(details)
        b.setAccessibilityLabel(s.title)
        return b
    }, spacing: 6)
    private var heldSwitch = false
    private var detailSwitch = ""
    private var readoutDetail: (temp: NSTextField, fans: NSTextField, load: NSTextField, memory: NSTextField)?
    private var limitValue: NSTextField?
    private var areaValue: NSTextField?
    private var toggleButtons: [String: NSButton] = [:]
    // the clipboard and the apps share the room after the readout and switches; apps keep three icons at least
    private let clipShelf = Shelf(maxWidth: 300)
    private let appShelf = Shelf(maxWidth: threeApps)
    private var usableWidth: CGFloat = 900
    private var hogs: [Hog] = []
    // the order the apps hold on the strip: those already shown keep their places, a newcomer joins at the end
    private var order: [pid_t] = []
    private var clips: [Clips.Item] = []
    private var capped: [CappedApp] = []
    // one app on the strip: lit while its cap holds, dim otherwise (a busy app without a cap)
    private struct AppSlot { let capped: CappedApp?; let hog: Hog? }
    private var slots: [AppSlot] = []
    private var detailHog: Hog?
    private var detailApp: CappedApp?
    private var detailClip: Clips.Item?
    private var preview: NSPanel?
    private var visibility: NSKeyValueObservation?
    private var seenVisible = false
    private var capValue: NSTextField?
    private var capPower: NSButton?
    private var capSlider: NSSlider?
    private var lineLabel: NSTextField?
    private var figureTimer: Timer?
    private var refreshCount = 0

    // temperature, the fan and CPU load, each with its level's colour
    var readout: () -> [(text: String, tint: NSColor?)] = { [] }
    var toggles: () -> [String: Bool] = { [:] }
    var setToggle: (String, Bool) -> Void = { _, _ in }
    var busiest: () -> [Hog] = { [] }
    // a capped app's use while it runs, listed or not
    var useOf: (String) -> Hog? = { _ in nil }
    var isCapped: (Hog) -> Bool = { _ in false }
    var capHog: (pid_t) -> Void = { _ in }
    var idleState: (pid_t) -> Bool? = { _ in nil }
    var toggleIdle: (pid_t) -> Void = { _ in }
    var clipItems: () -> [Clips.Item] = { [] }
    var copyClip: (Clips.Item) -> Void = { _ in }
    var cappedApps: () -> [CappedApp] = { [] }
    var setCapLevel: (String, Double) -> Void = { _, _ in }
    var setCapOn: (String, Bool) -> Void = { _, _ in }
    var removeCapped: (String) -> Void = { _ in }
    var setMemoryLine: (String, Double) -> Void = { _, _ in }
    var shotLimit: () -> Double = { 1500 }
    var setShotLimit: (Double) -> Void = { _ in }
    // the readout's screen: temperature, every fan, CPU load, each with its colour
    var details: () -> [(text: String, tint: NSColor?)] = { [("–", nil), ("–", nil), ("–", nil)] }
    var memory: () -> (used: Double, tint: NSColor?)? = { nil }

    private let switchSet: [(key: String, symbol: String, on: String, title: String)] = [
        ("awake", "cup.and.saucer", "cup.and.saucer.fill", "Caffeinate"),
        ("shrink", "square.resize.down", "square.resize.down", "Shrink"),
        ("history", "list.clipboard", "list.clipboard.fill", "Clipboard history"),
    ]

    override init() {
        super.init()
        clipShelf.onTap = { [weak self] i in self?.tapClip(i) }
        clipShelf.onHold = { [weak self] i in self?.holdClip(i) }
        appShelf.onTap = { [weak self] i in self?.tapApp(i) }
        appShelf.onHold = { [weak self] i in self?.openApp(i) }
        // an app's screen opens as the hold lands, like the switches and the readout
        appShelf.holdPause = 0
    }

    var available: Bool {
        dfr != nil && dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") != nil
            && (NSTouchBarItem.self as AnyObject).responds(to: addTray)
            && (NSTouchBar.self as AnyObject).responds(to: present)
    }

    var isShown: Bool { stripItem != nil }

    private func setPresence(_ on: Bool) {
        guard let dfr, let f = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") else { return }
        typealias Presence = @convention(c) (CFString, Bool) -> Void
        unsafeBitCast(f, to: Presence.self)(stripID.rawValue as CFString, on)
    }

    private func closeBox() {
        guard let dfr, let f = dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
        typealias Flag = @convention(c) (Bool) -> Void
        unsafeBitCast(f, to: Flag.self)(true)
    }

    private func symbol(_ name: String, size: CGFloat = 12) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }

    private func iconButton(_ image: NSImage, _ action: Selector, tag: Int = 0) -> NSButton {
        let b = NSButton(image: image, target: self, action: action)
        b.title = ""
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.tag = tag
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }

    private func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        return s
    }

    private func appIcon(path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }

    private func hogIcon(_ hog: Hog) -> NSImage {
        if let url = hog.app?.bundleURL { return appIcon(path: url.path) }
        return symbol("gearshape", size: 16) ?? NSImage()
    }

    // MARK: the Control Strip icon

    func show() {
        guard available, stripItem == nil else { return }
        let button = NSButton(image: symbol("cpu", size: 13)!, target: self, action: #selector(open))
        button.isBordered = false
        button.contentTintColor = .white
        let item = NSCustomTouchBarItem(identifier: stripID)
        item.view = button
        stripItem = item
        closeBox()
        _ = (NSTouchBarItem.self as AnyObject).perform(addTray, with: item)
        setPresence(true)
    }

    // takes the Control Strip's extra slot back, from Now Playing for one
    func reclaim() {
        guard stripItem != nil else { return }
        setPresence(true)
    }

    func hide() {
        guard let item = stripItem else { return }
        if opened, (NSTouchBar.self as AnyObject).responds(to: dismiss) {
            _ = (NSTouchBar.self as AnyObject).perform(dismiss, with: bar)
        }
        opened = false
        setPresence(false)
        if (NSTouchBarItem.self as AnyObject).responds(to: removeTray) {
            _ = (NSTouchBarItem.self as AnyObject).perform(removeTray, with: item)
        }
        stripItem = nil
    }

    func refresh() {
        guard opened else { return }
        if screen == "readout", let r = readoutDetail {
            for (label, part) in zip([r.temp, r.fans, r.load], details()) {
                label.stringValue = part.text
                label.textColor = part.tint ?? .labelColor
            }
            paintMemory(r.memory)
            return
        }
        guard screen == "main" else { return }
        refreshCount += 1
        if refreshCount % 3 == 0 { hogs = busiest() }
        rebuildIfChanged()
        readoutLabel.attributedStringValue = readoutText()
        paintToggles()
    }

    // MARK: screens

    @objc func open() {
        // the bar's own X closes everything: the preview goes, and the next open starts on the main strip
        if visibility == nil {
            visibility = bar.observe(\.isVisible) { [weak self] bar, _ in
                let shown = bar.isVisible
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard !shown else { self.seenVisible = true; return }
                    guard self.seenVisible else { return }
                    note("touch bar: closed")
                    self.opened = false
                    self.reclaim()
                    if self.screen != "main" || self.preview != nil { self.showMain() }
                }
            }
        }
        hogs = busiest()
        showMain()
        opened = true
        _ = (NSTouchBar.self as AnyObject).perform(present, with: bar, with: stripID.rawValue as NSString)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.measure() }
    }

    // the bar's room right of where the strip starts, read each time it shows: the Control Strip comes and goes beside it
    private func measure() {
        guard let window = frame.window else { return note("touch bar: the strip has yet to reach a window") }
        let x = frame.convert(NSPoint.zero, to: nil).x
        let room = window.frame.width - x - 8
        guard room > 400, abs(room - usableWidth) > 1 else { return }
        note("touch bar: bar \(Int(window.frame.width)) pt, strip starts at \(Int(x)), room \(Int(room))")
        usableWidth = room
        fitGroups()
    }

    private func showMain(animated: Bool = false) {
        screen = "main"
        closePreview()
        rebuildIfChanged()
        readoutLabel.attributedStringValue = readoutText()
        paintToggles()
        fill([mainStack], grow: animated ? 1.05 : nil)
    }

    // an inner screen grows out of the item touched
    private func enter(_ name: String, from x: CGFloat?, _ views: [NSView]) {
        origin = x ?? 0
        screen = name
        fill(views, grow: 0.9)
    }

    // the middle of a view on the strip, in the strip's own terms
    private func middle(of view: NSView) -> CGFloat { view.convert(NSPoint(x: view.bounds.midX, y: 0), to: frame).x }

    // one screen at a time; inner screens stretch across the bar and their empty end goes back.
    // With grow, the old screen fades where it stands while the new one fades in, scaling to full size around the origin
    private func fill(_ views: [NSView], grow scale: CGFloat? = nil) {
        if scale != nil { transition(frame, .fade) }
        let content = views.count == 1 ? views[0] : row(views)
        for v in frame.arrangedSubviews { v.removeFromSuperview() }
        frame.addArrangedSubview(content)
        if screen != "main" { frame.addArrangedSubview(blank) }
        fullWidth.constant = usableWidth
        fullWidth.isActive = screen != "main"
        guard let scale else { return }
        frame.layoutSubtreeIfNeeded()
        content.wantsLayer = true
        guard let layer = content.layer else { return }
        let x = origin - content.frame.minX, y = layer.bounds.midY
        var from = CATransform3DMakeTranslation(x, y, 0)
        from = CATransform3DScale(from, scale, scale, 1)
        from = CATransform3DTranslate(from, -x, -y, 0)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = from
        grow.toValue = CATransform3DIdentity
        grow.duration = 0.22
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(grow, forKey: "grow")
    }

    // a tap on the empty end of an inner screen goes back, the way the system's own sliders close
    @objc private func blankTapped() {
        guard screen != "main" else { return }
        showMain(animated: true)
    }

    private func transition(_ view: NSView, _ type: CATransitionType) {
        view.wantsLayer = true
        let t = CATransition()
        t.type = type
        t.duration = 0.22
        t.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.layer?.add(t, forKey: "screen")
    }

    private func fade(_ view: NSView?, to alpha: CGFloat) {
        guard let view, abs(view.alphaValue - alpha) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            view.animator().alphaValue = alpha
        }
    }

    private func backButton() -> NSButton { iconButton(symbol("chevron.left")!, #selector(back)) }

    @objc private func back() { showMain(animated: true) }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == mainID else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = frame
        return item
    }

    // MARK: main strip: values | switches | clipboard | apps

    private func rebuildIfChanged() {
        clips = clipItems()
        capped = cappedApps()
        let steady = hogs.enumerated().sorted { a, b in
            (order.firstIndex(of: a.element.pid) ?? order.count + a.offset) < (order.firstIndex(of: b.element.pid) ?? order.count + b.offset)
        }.map(\.element)
        order = steady.map(\.pid)
        slots = capped.map { app in AppSlot(capped: app, hog: steady.first { $0.app?.bundleIdentifier == app.id }) }
            + steady.filter { hog in !capped.contains { $0.id == hog.app?.bundleIdentifier } }.map { AppSlot(capped: nil, hog: $0) }
        clipShelf.show(clips.map(clipKey).joined(separator: "|")) { clips.map(clipEntry) }
        appShelf.show(slots.map(slotKey).joined(separator: "|")) { slots.map(slotEntry) }
        fitGroups()
        let next = "\(clips.isEmpty)\(slots.isEmpty)"
        guard next != shape else { return }
        if !shape.isEmpty { transition(mainStack, .fade) }
        shape = next
        let groups: [NSView] = [readoutLabel, switchRow]
            + [(clipShelf, clips.isEmpty), (appShelf, slots.isEmpty)].filter { !$0.1 }.map { $0.0.view }
        for v in mainStack.arrangedSubviews { v.removeFromSuperview() }
        for g in groups { mainStack.addArrangedSubview(g) }
    }

    // the room after the readout and switches, less 10 pt between each pair of groups: apps take what the clipboard
    // leaves, three icons at least, and the clipboard takes the rest
    private func fitGroups() {
        let groups = 2 + (clips.isEmpty ? 0 : 1) + (slots.isEmpty ? 0 : 1)
        let shared = usableWidth - readoutLabel.fittingSize.width - switchRow.fittingSize.width - CGFloat(groups - 1) * 10
        let apps = max(threeApps, shared - (clips.isEmpty ? 0 : clipShelf.contentWidth))
        if abs(apps - appShelf.maxWidth) > 0.5 { appShelf.maxWidth = apps }
        let room = max(80, shared - (slots.isEmpty ? 0 : appShelf.shownWidth))
        if abs(room - clipShelf.maxWidth) > 0.5 { clipShelf.maxWidth = room }
    }

    private func idled(_ slot: AppSlot) -> Bool { slot.hog.map { idleState($0.pid) == true } ?? false }

    private func slotKey(_ slot: AppSlot) -> String {
        "\(slot.capped?.id ?? "")\(slot.capped?.on ?? false)\(slot.capped?.level ?? 0)\(slot.hog?.pid ?? 0)\(idled(slot))"
    }

    // lit while Culpmit holds the app (capped or idled), dim when it runs free; the faintest dot marks an idled app
    private func slotEntry(_ slot: AppSlot) -> Shelf.Entry {
        let idle = idled(slot)
        guard let app = slot.capped else {
            return .icon(slot.hog.map(hogIcon) ?? NSImage(), dim: !idle, mark: idle, label: slot.hog?.name ?? "App")
        }
        return .icon(appIcon(path: app.path), dim: !(idle || app.on), mark: idle, label: app.name)
    }

    private func clipKey(_ clip: Clips.Item) -> String {
        switch clip {
        case .text(let s): return "t" + String(s.prefix(40))
        case .image(let data, _): return "i\(data.count)"
        }
    }

    private func clipEntry(_ clip: Clips.Item) -> Shelf.Entry {
        switch clip {
        case .text(let s):
            let first = (s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s).trimmingCharacters(in: .whitespaces)
            return .text(first.count > 24 ? String(first.prefix(24)) + "…" : first)
        case .image(let data, _):
            return .picture(NSImage(data: data) ?? NSImage())
        }
    }

    private func paintToggles() {
        let states = toggles()
        for s in switchSet {
            guard let button = toggleButtons[s.key] else { continue }
            let on = states[s.key] ?? false
            button.image = symbol(on ? s.on : s.symbol)
            fade(button, to: on ? 1 : 0.4)
        }
    }

    @objc private func tapSwitch(_ sender: NSButton) {
        // the lift after holding Shrink stays a hold
        if heldSwitch { heldSwitch = false; return }
        guard let key = sender.identifier?.rawValue else { return }
        setToggle(key, !(toggles()[key] ?? false))
        rebuildIfChanged()
        paintToggles()
    }

    // a tap copies the clip and leaves the strip open for the next pick
    private func tapClip(_ i: Int) {
        guard clips.indices.contains(i) else { return }
        copyClip(clips[i])
    }

    // a tap flips the app's light: an idled app wakes, a cap turns off or on, a busy app is capped at 50%
    private func tapApp(_ i: Int) {
        guard slots.indices.contains(i) else { return }
        let slot = slots[i]
        if let hog = slot.hog, idleState(hog.pid) == true {
            toggleIdle(hog.pid)
        } else if let app = slot.capped {
            setCapOn(app.id, !app.on)
        } else if let hog = slot.hog, hog.pid != getpid(), hog.app?.bundleIdentifier != nil, hog.app?.bundleURL != nil {
            capHog(hog.pid)
        } else {
            // a helper with the gear icon holds its name and share alone, so a tap opens them
            return openApp(i)
        }
        rebuildIfChanged()
    }

    // a capped app opens its slider, with Idle while it is listed busy or idled; any other app opens Cap and Idle
    private func openApp(_ i: Int) {
        guard slots.indices.contains(i) else { return }
        detailHog = slots[i].hog ?? slots[i].capped.flatMap { useOf($0.id) }
        let x = appShelf.center(of: i, in: frame)
        if let app = slots[i].capped {
            detailApp = app
            enter("cap", from: x, [backButton(), capView()])
        } else {
            enter("hog", from: x, [backButton(), hogView()])
        }
    }

    // MARK: one held clip: text fills the strip with its first line; an image floats on screen with its size on the strip

    private func holdClip(_ i: Int) {
        guard clips.indices.contains(i) else { return }
        let clip = clips[i]
        detailClip = clip
        let x = clipShelf.center(of: i, in: frame)
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyDetail))
        switch clip {
        case .text(let s):
            let first = (s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s).trimmingCharacters(in: .whitespaces)
            let label = NSTextField(labelWithString: first)
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.widthAnchor.constraint(equalToConstant: max(120, usableWidth - 140)).isActive = true
            enter("clip", from: x, [backButton(), label, copy])
        case .image(let data, let size):
            showPreview(data)
            let thumb = NSImageView(image: NSImage(data: data) ?? NSImage())
            thumb.imageScaling = .scaleProportionallyUpOrDown
            thumb.widthAnchor.constraint(equalToConstant: 48).isActive = true
            thumb.heightAnchor.constraint(equalToConstant: 26).isActive = true
            let w = grouped.string(from: NSNumber(value: Int(size.width))) ?? ""
            let h = grouped.string(from: NSNumber(value: Int(size.height))) ?? ""
            let label = NSTextField(labelWithString: "\(w) × \(h) · " + String(format: "%.1f MP", size.width * size.height / 1_000_000))
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            enter("clip", from: x, [backButton(), thumb, label, copy])
        }
    }

    @objc private func copyDetail() {
        if let clip = detailClip { copyClip(clip) }
        showMain(animated: true)
    }

    private let previewMax = NSSize(width: 440, height: 280)

    private func showPreview(_ data: Data) {
        closePreview()
        // bottom left of the primary screen (the one holding the menu bar), 20 pt from both edges, over the Dock
        guard let image = NSImage(data: data), image.size.width > 0, let room = NSScreen.screens.first?.frame else { return }
        let scale = min(1, previewMax.width / image.size.width, previewMax.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = NSRect(x: room.minX + 20, y: room.minY + 20, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: target.offsetBy(dx: 0, dy: -24),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(back)))
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // it rises a little as it fades in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        preview = panel
    }

    private func closePreview() {
        guard let panel = preview else { return }
        preview = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -16), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    // MARK: holding an item tells more: the readout with icons and units, a switch with its name and On or Off,
    // Shrink with its name, image size slider, size and area (dimmed and still while Shrink is off)

    private func holdRecognizer(_ action: Selector) -> NSPressGestureRecognizer {
        let press = NSPressGestureRecognizer(target: self, action: action)
        press.allowedTouchTypes = .direct
        press.minimumPressDuration = 0.5
        return press
    }

    @objc private func holdReadout(_ press: NSPressGestureRecognizer) {
        guard press.state == .began else { return }
        openReadout()
    }

    // the readout holds values alone, so a tap opens the same screen as a hold; the lift after a hold finds it open
    @objc private func tapReadout() {
        guard screen == "main" else { return }
        openReadout()
    }

    private func openReadout() {
        enter("readout", from: middle(of: readoutLabel), [backButton(), readoutView()])
    }

    private func readoutView() -> NSView {
        let d = details()
        func value(_ part: (text: String, tint: NSColor?)) -> NSTextField {
            let l = NSTextField(labelWithString: part.text)
            l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            l.textColor = part.tint ?? .labelColor
            return l
        }
        let temp = value(d[0]), fans = value(d[1]), load = value(d[2]), memory = value(("–", nil))
        paintMemory(memory)
        readoutDetail = (temp, fans, load, memory)
        func pair(_ icon: String, _ label: NSTextField) -> NSView { row([NSImageView(image: symbol(icon, size: 13)!), label], spacing: 6) }
        return row([pair("thermometer.medium", temp), pair("fan", fans), pair("gauge.with.dots.needle.50percent", load),
                    pair("memorychip", memory)], spacing: 32)
    }

    // the strip's values with memory last, in whole GB, each in its level's colour
    private func readoutText() -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let dot = NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let text = NSMutableAttributedString()
        for (i, part) in readout().enumerated() {
            if i > 0 { text.append(dot) }
            text.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: part.tint ?? NSColor.labelColor]))
        }
        if let m = memory() {
            text.append(dot)
            text.append(NSAttributedString(string: "\(Int((m.used / gib).rounded()))",
                                           attributes: [.font: font, .foregroundColor: m.tint ?? NSColor.labelColor]))
            // the Mac's whole memory, small and soft beside what is in use
            text.append(NSAttributedString(string: "/\(Int(ramGB.rounded()))G",
                                           attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                        .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return text
    }

    // memory used to one decimal on the readout's own screen, tinted the same way
    private func paintMemory(_ label: NSTextField) {
        guard let m = memory() else { return }
        label.stringValue = gigabytes(m.used)
        label.textColor = m.tint ?? .labelColor
    }

    @objc private func holdSwitch(_ press: NSPressGestureRecognizer) {
        if press.state == .ended || press.state == .cancelled || press.state == .failed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.heldSwitch = false }
            return
        }
        guard press.state == .began, let view = press.view, let key = view.identifier?.rawValue else { return }
        heldSwitch = true
        openSwitch(key, from: view)
    }

    private func openSwitch(_ key: String, from view: NSView) {
        detailSwitch = key
        enter(key == "shrink" ? "shrink" : "switch", from: middle(of: view), [backButton(), key == "shrink" ? shrinkView() : switchView(key)])
    }

    private func switchView(_ key: String) -> NSView {
        guard let s = switchSet.first(where: { $0.key == key }) else { return NSView() }
        let on = toggles()[key] ?? false
        let name = NSTextField(labelWithString: s.title)
        name.font = .systemFont(ofSize: 13)
        let state = NSButton(title: on ? "On" : "Off", target: self, action: #selector(flipDetail))
        if on { state.bezelColor = .systemBlue }
        return row([NSImageView(image: symbol(on ? s.on : s.symbol, size: 13)!), name, state], spacing: 14)
    }

    @objc private func flipDetail() {
        setToggle(detailSwitch, !(toggles()[detailSwitch] ?? false))
        transition(frame, .fade)
        fill([backButton(), switchView(detailSwitch)])
    }

    private func shrinkView() -> NSView {
        let limit = shotLimit()
        let on = toggles()["shrink"] ?? true
        let slider = roundSlider(value: limit, min: 800, max: 2000, width: 220, target: self, action: #selector(shrinkSlid(_:)))
        let size = NSTextField(labelWithString: px(limit))
        let area = NSTextField(labelWithString: megapixels(limit))
        for label in [size, area] { label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
        limitValue = size
        areaValue = area
        slider.isEnabled = on
        for v in [slider, size, area] as [NSView] { v.alphaValue = on ? 1 : 0.4 }
        let name = NSTextField(labelWithString: "Shrink")
        name.font = .systemFont(ofSize: 13)
        // On or Off, as on the other switches' screens; it wakes or dims the slider
        let state = NSButton(title: on ? "On" : "Off", target: self, action: #selector(flipShrink))
        if on { state.bezelColor = .systemBlue }
        return row([NSImageView(image: symbol("square.resize.down", size: 13)!), name, slider, size, area, state], spacing: 14)
    }

    @objc private func flipShrink() {
        setToggle("shrink", !(toggles()["shrink"] ?? true))
        transition(frame, .fade)
        fill([backButton(), shrinkView()])
    }

    @objc private func shrinkSlid(_ sender: NSSlider) {
        let v = (sender.doubleValue / 100).rounded() * 100
        limitValue?.stringValue = px(v)
        areaValue?.stringValue = megapixels(v)
        setShotLimit(v)
    }

    // MARK: one busy or idled app: name, share, Cap, and Idle or Wake

    private func hogView() -> NSView {
        guard let hog = detailHog else { return NSView() }
        let label = NSTextField(labelWithString: usage(hog.name, hog))
        label.font = .systemFont(ofSize: 13)
        var views: [NSView] = [NSImageView(image: hogIcon(hog)), label]
        // Culpmit lists itself like any app, with its figures alone: a cap on itself would stop the capping
        if hog.pid != getpid(), hog.app?.bundleIdentifier != nil, hog.app?.bundleURL != nil {
            views.append(stateIcon("tortoise", on: isCapped(hog), #selector(capDetail)))
        }
        if let idled = idleState(hog.pid) { views.append(stateIcon("moon.zzz", on: idled, #selector(idleDetail))) }
        return row(views, spacing: 12)
    }

    // the menu's icons on the bar: a tortoise caps, a moon idles, each red while on
    private func stateIcon(_ name: String, on: Bool, _ action: Selector) -> NSButton {
        let button = iconButton(symbol(name, size: 14)!, action)
        button.contentTintColor = on ? .systemRed : .labelColor
        return button
    }

    @objc private func capDetail() {
        if let hog = detailHog { capHog(hog.pid) }
        hogs = busiest()
        showMain(animated: true)
    }

    @objc private func idleDetail() {
        if let hog = detailHog { toggleIdle(hog.pid) }
        hogs = busiest()
        showMain(animated: true)
    }

    // an app's name with what it uses now: its CPU share, then its memory in GB where macOS shares it
    private func usage(_ name: String?, _ hog: Hog) -> String {
        let use = percent(hog.cpu) + (hog.memory > 0 ? " · " + gigabytes(hog.memory) : "")
        guard let name else { return use }
        return (name.count > 16 ? String(name.prefix(15)) + "…" : name) + " · " + use
    }

    // MARK: one capped app: what it uses now, its CPU cap and memory line side by side, and its power switch

    // each part reads its icon, what the app uses now, a dot, then its slider between its least and most; while a knob
    // moves, the figure shows the limit it sets, and returns to the use a moment after
    private func capView() -> NSView {
        guard let app = detailApp else { return NSView() }
        let (cpuFigure, value) = figure("gauge.with.dots.needle.50percent", usedCPU(), limit: percent(capRange.upperBound * 100))
        capValue = value
        let (memoryFigure, lineValue) = figure("memorychip", usedMemory(), limit: lineText(lineRange.upperBound))
        lineLabel = lineValue
        let power = iconButton(symbol("power")!, #selector(capPowerTapped))
        let ends = [end("\(Int(capRange.lowerBound * 100))"), end("\(Int(capRange.upperBound * 100))"),
                    end("\(Int(lineRange.lowerBound))"), end("\(Int(lineRange.upperBound))")]
        let dots = [dot(), dot()]
        let appIconView = NSImageView(image: appIcon(path: app.path))
        var after: [NSView] = [power]
        // the moon idles the app while it runs, red while it is idled, by hand or for memory
        if let hog = detailHog, let idled = idleState(hog.pid) { after.append(stateIcon("moon.zzz", on: idled, #selector(idleDetail))) }
        // Remove comes only after uncap, so taking an app off the list is two deliberate taps
        if !app.on { after.append(iconButton(symbol("minus.circle")!, #selector(removeDetail))) }
        // the two sliders share the room the rest leaves: the bar's width less ‹, the gaps and every other part
        let spacing: CGFloat = 6, groupGap: CGFloat = 18
        let others = [appIconView, cpuFigure, memoryFigure] + ends + dots + after
        let room = usableWidth - 50 - others.map { $0.fittingSize.width }.reduce(0, +) - spacing * CGFloat(others.count - 2)
            - groupGap * 3
        let width = min(240, max(70, (room / 2).rounded(.down)))
        let slider = roundSlider(value: app.level, min: capRange.lowerBound, max: capRange.upperBound, width: width,
                                 target: self, action: #selector(capSlid(_:)))
        capSlider = slider
        let line = roundSlider(value: app.line, min: lineRange.lowerBound, max: lineRange.upperBound, width: width,
                               target: self, action: #selector(lineSlid(_:)))
        for v in [power, cpuFigure, slider, memoryFigure, line] + ends + dots { v.alphaValue = app.on ? 1 : 0.4 }
        slider.isEnabled = app.on
        line.isEnabled = app.on
        capPower = power
        let stack = row([appIconView, cpuFigure, dots[0], ends[0], slider, ends[1], memoryFigure, dots[1], ends[2], line, ends[3]] + after,
                        spacing: spacing)
        // clear gaps between the app, its CPU group, its memory group and its buttons, so each icon reads with its own group
        for view in [appIconView, ends[1], ends[3]] { stack.setCustomSpacing(groupGap, after: view) }
        return stack
    }

    // an icon hugging its figure, pressed to the right of a box as wide as the wider of the two things it shows here,
    // the use now and the highest limit while a knob moves: the figure meets its dot, and the little spare width falls
    // before the icon, in the gap between groups
    private func figure(_ name: String, _ text: String, limit: String) -> (NSView, NSTextField) {
        let icon = NSImageView(image: symbol(name, size: 13)!)
        let label = NSTextField(labelWithString: limit)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let widest = label.fittingSize.width
        label.stringValue = text
        let width = ceil(icon.fittingSize.width + 4 + max(widest, label.fittingSize.width))
        let box = NSStackView()
        box.orientation = .horizontal
        box.spacing = 4
        box.addView(icon, in: .trailing)
        box.addView(label, in: .trailing)
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return (box, label)
    }

    private func usedCPU() -> String { detailHog.map { percent($0.cpu) } ?? "–" }
    private func usedMemory() -> String { detailHog.map { $0.memory > 0 ? gigabytes($0.memory) : "–" } ?? "–" }

    // a slider's least or most, small and soft beside it
    private func end(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func dot() -> NSTextField {
        let label = NSTextField(labelWithString: "·")
        label.font = .systemFont(ofSize: 13)
        return label
    }

    // the figures return to what the app uses a moment after a knob stops
    private func settleFigures() {
        figureTimer?.invalidate()
        figureTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, self.screen == "cap" else { return }
            self.capValue?.stringValue = self.usedCPU()
            self.lineLabel?.stringValue = self.usedMemory()
        }
    }

    @objc private func lineSlid(_ sender: NSSlider) {
        guard let app = detailApp else { return }
        let line = snapLine(sender.doubleValue)
        lineLabel?.stringValue = lineText(line)
        settleFigures()
        guard line != app.line else { return }
        detailApp?.memoryLine = line
        setMemoryLine(app.id, line)
    }

    @objc private func capSlid(_ sender: NSSlider) {
        guard let app = detailApp else { return }
        let level = (sender.doubleValue * 20).rounded() / 20
        capValue?.stringValue = percent(level * 100)
        settleFigures()
        guard level != app.level else { return }
        detailApp?.level = level
        setCapLevel(app.id, level)
    }

    @objc private func removeDetail() {
        guard let app = detailApp else { return }
        removeCapped(app.id)
        hogs = busiest()
        showMain(animated: true)
    }

    @objc private func capPowerTapped() {
        guard let app = detailApp else { return }
        detailApp?.on = !app.on
        setCapOn(app.id, !app.on)
        transition(frame, .fade)
        fill([backButton(), capView()])
    }
}
