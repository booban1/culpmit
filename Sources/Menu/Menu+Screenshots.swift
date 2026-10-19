import AppKit

// Clipboard section: history and its switch, then Shrink images in one row, its image size and approx size on a slider
// while it is on

extension Menu {
    func addScreenshotsSection() {
        // the heading carries Keep history and its switch at its far right
        let head = kit.row("Clipboard", bold: true).item
        let keep = NSTextField(labelWithString: "Keep history")
        keep.font = .menuFont(ofSize: kit.size)
        keep.textColor = .labelColor
        keep.sizeToFit()
        kit.attach([switchControl("history", clips.isOn), keep], to: head)
        menu.addItem(head)
        let history = NSMenuItem(title: "Clipboard history", action: nil, keyEquivalent: "")
        history.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        history.submenu = historyMenu()
        history.isHidden = clips.history.isEmpty
        historyMenuItem = history
        historyShown = clips.items
        menu.addItem(history)
        let value = kit.valueField(shrinkText(shrinker.limit), template: shrinkText(2000))
        limitLabel = value
        let slider = kit.slider(shrinker.limit, 800, 2000, target: self, action: #selector(slid(_:)))
        menu.addItem(lineRow("Shrink images", "shrink", shrinker.isOn, slider, value))
        menu.addItem(.separator())
    }

    // the image size on its long side, then its approximate area
    func shrinkText(_ v: Double) -> String { px(v) + " · " + megapixels(v) }

    func tickHistory() {
        guard clips.items != historyShown else { return }
        historyShown = clips.items
        historyMenuItem?.submenu = historyMenu()
        show(historyMenuItem, !clips.history.isEmpty)
    }

    @objc func slid(_ sender: NSSlider) {
        let v = (sender.doubleValue / 100).rounded() * 100
        sender.doubleValue = v
        shrinker.limit = v
        store.set(v, forKey: "shotLimit")
        limitLabel?.stringValue = shrinkText(v)
    }

    func historyMenu() -> NSMenu {
        let sub = NSMenu()
        for (i, clip) in clips.history.enumerated() {
            let m: NSMenuItem
            switch clip {
            case .text(let s):
                let first = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
                let title = first.trimmingCharacters(in: .whitespaces)
                m = NSMenuItem(title: title.count > 48 ? String(title.prefix(48)) + "…" : title,
                               action: #selector(copyClip(_:)), keyEquivalent: "")
            case .image(let data, let size):
                let w = grouped.string(from: NSNumber(value: Int(size.width))) ?? ""
                let h = grouped.string(from: NSNumber(value: Int(size.height))) ?? ""
                m = NSMenuItem(title: "\(w) × \(h)", action: #selector(copyClip(_:)), keyEquivalent: "")
                if let thumb = NSImage(data: data), thumb.size.height > 0 {
                    let ratio = thumb.size.width / thumb.size.height
                    thumb.size = NSSize(width: min(32 * ratio, 96), height: min(32, 96 / ratio))
                    m.image = thumb
                }
            }
            m.target = self
            m.tag = i
            sub.addItem(m)
        }
        sub.addItem(.separator())
        let clear = NSMenuItem(title: "Clear history", action: #selector(clearClips), keyEquivalent: "")
        clear.target = self
        sub.addItem(clear)
        return sub
    }

    @objc func copyClip(_ sender: NSMenuItem) {
        let list = clips.history
        if list.indices.contains(sender.tag) { clips.copy(list[sender.tag]) }
    }

    @objc func clearClips() { clips.clear() }
}
