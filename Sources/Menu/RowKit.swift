import AppKit

// Builds menu rows from plain views: label or icon on the left, values and controls on the right, one shared width.
// It stands apart from Culpmit's own features, so any menu bar app can reuse it as is.

struct Row {
    let item: NSMenuItem
    let view: NSView
    var icon: NSImageView?
    var label: NSTextField?
    var value: NSTextField?
}

final class RowKit {
    let size = NSFont.menuFont(ofSize: 0).pointSize
    let height: CGFloat = 24
    var minWidth: CGFloat = 240
    private var pending: [(view: NSView, trailing: [NSView], need: CGFloat)] = []

    func reset() { pending.removeAll() }

    func valueField(_ text: String, template: String? = nil) -> NSTextField {
        let v = NSTextField(labelWithString: template ?? text)
        v.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        v.textColor = .labelColor
        v.sizeToFit()
        v.stringValue = text
        return v
    }

    // A row with an icon keeps its value beside the icon; a row with a text label puts the value at the far right.
    func row(_ text: String, _ value: String? = nil, icon: String? = nil, image: NSImage? = nil, bold: Bool = false,
             indent: CGFloat = 0, template: String? = nil) -> Row {
        let h = height
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: h))
        view.autoresizingMask = [.width]
        var x: CGFloat = 22 + indent
        var iconRow = false
        var iconView: NSImageView?
        var labelField: NSTextField?
        if let icon, let symbol = NSImage(systemSymbolName: icon, accessibilityDescription: text)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) {
            let iv = NSImageView(image: symbol)
            iv.contentTintColor = .labelColor
            iv.frame = NSRect(x: x, y: 0, width: 20, height: h)
            view.addSubview(iv)
            view.toolTip = text
            iconView = iv
            x += 20
            iconRow = true
        } else {
            if let image {
                let iv = NSImageView(image: image)
                if image.isTemplate { iv.contentTintColor = .labelColor }
                iv.frame = NSRect(x: x, y: (h - 18) / 2, width: 18, height: 18)
                view.addSubview(iv)
                iconView = iv
                x += 24
            }
            let label = NSTextField(labelWithString: text)
            label.font = bold ? .boldSystemFont(ofSize: size) : .menuFont(ofSize: size)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.sizeToFit()
            label.frame.origin = NSPoint(x: x, y: (h - label.frame.height) / 2)
            view.addSubview(label)
            labelField = label
            x += label.frame.width
        }
        view.frame.size.width = x + 14
        var need = view.frame.width
        var trailing: [NSView] = []
        var valueField: NSTextField?
        if let value {
            let v = self.valueField(value, template: template)
            v.frame.origin.y = (h - v.frame.height) / 2
            view.addSubview(v)
            if iconRow {
                v.frame.origin.x = x + 8
                need = x + 8 + v.frame.width + 14
            } else {
                v.alignment = .right
                v.autoresizingMask = [.minXMargin]
                need = x + 24 + v.frame.width + 14
                trailing = [v]
            }
            valueField = v
        }
        pending.append((view, trailing, need))
        let m = NSMenuItem()
        m.view = view
        return Row(item: m, view: view, icon: iconView, label: labelField, value: valueField)
    }

    // Several icon-and-value pairs on one line
    func pair(_ pairs: [(icon: String, name: String, value: String, template: String)], indent: CGFloat = 0) -> (NSMenuItem, [NSTextField]) {
        let h = height
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: h))
        view.autoresizingMask = [.width]
        var x: CGFloat = 22 + indent
        var fields: [NSTextField] = []
        for (i, p) in pairs.enumerated() {
            if i > 0 { x += 28 }
            if let symbol = NSImage(systemSymbolName: p.icon, accessibilityDescription: p.name)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) {
                let iv = NSImageView(image: symbol)
                iv.contentTintColor = .labelColor
                iv.frame = NSRect(x: x, y: 0, width: 20, height: h)
                iv.toolTip = p.name
                view.addSubview(iv)
                x += 20
            }
            let v = valueField(p.value, template: p.template)
            v.toolTip = p.name
            v.frame.origin = NSPoint(x: x + 8, y: (h - v.frame.height) / 2)
            view.addSubview(v)
            fields.append(v)
            x += 8 + v.frame.width
        }
        view.frame.size.width = x + 14
        pending.append((view, [], x + 14))
        let m = NSMenuItem()
        m.view = view
        return (m, fields)
    }

    func head(_ text: String) -> NSMenuItem { row(text, bold: true).item }

    // Adds controls at the right edge of the last row; outermost puts them right of the row's value
    func attach(_ controls: [NSView], to item: NSMenuItem, outermost: Bool = false) {
        guard let view = item.view else { return }
        var extra: CGFloat = 0
        for c in controls {
            c.autoresizingMask = [.minXMargin]
            c.frame.origin.y = (view.frame.height - c.frame.height) / 2
            view.addSubview(c)
            extra += c.frame.width + 8
        }
        let last = pending.removeLast()
        pending.append((view, outermost ? controls + last.trailing : last.trailing + controls, last.need + 16 + extra))
    }

    // A slider with the menu's uniform marks, the same on every slider; its owner snaps the value to the steps that
    // matter for it
    func slider(_ value: Double, _ min: Double, _ max: Double, target: AnyObject, action: Selector) -> NSSlider {
        let s = NSSlider(value: value, minValue: min, maxValue: max, target: target, action: action)
        s.controlSize = .small
        s.numberOfTickMarks = 21
        s.isContinuous = true
        s.sizeToFit()
        s.frame.size.width = 120
        return s
    }

    // A row drawn by its own view, sized with the rest
    func custom(_ view: NSView, need: CGFloat) -> NSMenuItem {
        view.autoresizingMask = [.width]
        pending.append((view, [], need))
        let m = NSMenuItem()
        m.view = view
        return m
    }

    // Lays controls left to right from x, for rows that read from the left edge
    func lead(_ controls: [NSView], in item: NSMenuItem, from x: CGFloat) {
        guard let view = item.view else { return }
        var at = x
        for c in controls {
            c.frame.origin = NSPoint(x: at, y: (view.frame.height - c.frame.height) / 2)
            view.addSubview(c)
            at += c.frame.width + 8
        }
        let last = pending.removeLast()
        pending.append((view, last.trailing, max(last.need, at + 6)))
    }

    static func place(_ trailing: [NSView], in view: NSView) {
        var x = view.frame.width - 14
        for v in trailing where !v.isHidden {
            x -= v.frame.width
            v.frame.origin.x = x
            x -= 8
        }
    }

    // Gives every row the widest row's width and lines up their right-hand parts
    func layout() {
        let width = max(minWidth, pending.map(\.need).max() ?? 0)
        for r in pending {
            r.view.frame.size.width = width
            RowKit.place(r.trailing, in: r.view)
        }
        pending.removeAll()
    }

    func smallButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .inline
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.sizeToFit()
        return b
    }
}
