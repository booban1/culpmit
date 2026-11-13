import AppKit

// The Claude limits switch: Uselim installed in the background, and Claude's figures on the Touch Bar while it is on.
// A line under the switch says what it does until Uselim has run an hour, counted a minute at a time while Culpmit
// sees it running; after that the row is the switch alone, with a line back only while something installs or stops.

extension Menu {
    // the choice once made; before that, on while Uselim runs, so a Mac that already runs Uselim keeps its figures
    var claudeOn: Bool {
        guard uselim.isPresent || uselim.isBusy else { return false }
        if let chosen = store.object(forKey: "claudeLimits") as? Bool { return chosen }
        return uselim.isRunning
    }

    var claudeSettled: Bool { store.bool(forKey: "claudeSettled") }

    // the words under the switch and their colour; nil once the row has settled and nothing is under way
    func claudeLineText() -> (words: String, color: NSColor)? {
        switch uselim.phase {
        case .working(let words): return (words, .secondaryLabelColor)
        case .stopped(let words): return (words, .systemOrange)
        case .needsClaude: return ("Needs Claude Code", .systemOrange)
        case .idle:
            if claudeSettled { return nil }
            guard claudeOn else { return ("Installs Uselim and adds its hooks to Claude Code", .secondaryLabelColor) }
            let name = ["Uselim", uselim.version].compactMap { $0 }.joined(separator: " ")
            return uselim.isRunning ? ("\(name) running", .secondaryLabelColor) : ("\(name) closed", .secondaryLabelColor)
        }
    }

    func setUpClaude() {
        uselim.changed = { [weak self] in self?.claudeChanged() }
        uselim.readState()
        every(60) { [weak self] in self?.countUselimMinute() }
    }

    private func claudeChanged() {
        // a stop leaves the Mac as it was, so the switch returns to off
        if case .stopped = uselim.phase { store.set(false, forKey: "claudeLimits") }
        strip.refresh()
        tickClaude()
    }

    func countUselimMinute() {
        guard !claudeSettled, claudeOn, uselim.isRunning else { return }
        let minutes = store.integer(forKey: "uselimMinutes") + 1
        store.set(minutes, forKey: "uselimMinutes")
        if minutes >= 60 {
            store.set(true, forKey: "claudeSettled")
            note("uselim: an hour of Uselim running, the Claude limits row is its switch alone from here")
        }
    }

    func setClaude(_ on: Bool) {
        store.set(on, forKey: "claudeLimits")
        if on { uselim.turnOn() }
        strip.refresh()
        tickClaude()
    }

    func claudeItem() -> NSMenuItem {
        let (view, need) = claudeView(width: nil)
        let item = kit.custom(view, need: need)
        claudeRow = item
        return item
    }

    // the row as a view of its own: the label and the switch on the top line, the words under them when there are any;
    // a width rebuilds it in place inside an open menu
    private func claudeView(width: CGFloat?) -> (NSView, CGFloat) {
        let line = claudeLineText()
        let top = kit.height
        let h = line == nil ? top : top + 14
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width ?? 100, height: h))
        view.autoresizingMask = [.width]
        let label = NSTextField(labelWithString: "Claude limits")
        label.font = .menuFont(ofSize: kit.size)
        label.textColor = .labelColor
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 22, y: h - top + (top - label.frame.height) / 2)
        view.addSubview(label)
        let toggle = switchControl("claudeLimits", claudeOn)
        toggle.isEnabled = !uselim.isBusy
        var need = 22 + label.frame.width + 24 + toggle.frame.width + 14
        claudeLine = nil
        if let line {
            let field = NSTextField(labelWithString: line.words)
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = line.color
            field.lineBreakMode = .byTruncatingTail
            field.sizeToFit()
            field.frame.origin = NSPoint(x: 22, y: 3)
            field.autoresizingMask = [.width]
            view.addSubview(field)
            need = max(need, 22 + field.frame.width + 14)
            claudeLine = field
        }
        let w = width ?? need
        view.frame.size.width = w
        claudeLine?.frame.size.width = w - 36
        toggle.autoresizingMask = [.minXMargin]
        toggle.frame.origin = NSPoint(x: w - 14 - toggle.frame.width, y: h - top + (top - toggle.frame.height) / 2)
        view.addSubview(toggle)
        return (view, need)
    }

    // kept live every second while the menu is open, and on each change of the install
    func tickClaude() {
        guard let item = claudeRow, let view = item.view else { return }
        let line = claudeLineText()
        if (line == nil) != (claudeLine == nil) {
            item.view = claudeView(width: view.frame.width).0
            return
        }
        if let line, let field = claudeLine {
            field.stringValue = line.words
            field.textColor = line.color
        }
        switches["claudeLimits"]?.state = claudeOn ? .on : .off
        switches["claudeLimits"]?.isEnabled = !uselim.isBusy
    }
}
