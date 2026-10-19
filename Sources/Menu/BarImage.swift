import AppKit

// The menu bar readout: an icon beside two left-aligned lines, the second one smaller

func barImage(_ top: String, _ bottom: String?, symbol: String = "cpu") -> NSImage {
    let topAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.black,
    ]
    let bottomAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
        .foregroundColor: NSColor.black,
    ]
    let t = NSAttributedString(string: top, attributes: topAttrs)
    let b = bottom.map { NSAttributedString(string: $0, attributes: bottomAttrs) }
    let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    let iconW = icon.map { ceil($0.size.width) } ?? 0
    let steady = NSAttributedString(string: "8888", attributes: bottomAttrs).size().width
    let textW = ceil(max(t.size().width, b?.size().width ?? 0, b == nil ? 0 : steady))
    let h: CGFloat = 22
    let image = NSImage(size: NSSize(width: iconW + 4 + textW, height: h), flipped: false) { _ in
        if let icon {
            icon.draw(in: NSRect(x: 0, y: (h - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
        }
        let x = iconW + 4
        if let b {
            t.draw(at: NSPoint(x: x, y: h - t.size().height + 1))
            b.draw(at: NSPoint(x: x, y: 0))
        } else {
            t.draw(at: NSPoint(x: x, y: (h - t.size().height) / 2))
        }
        return true
    }
    image.isTemplate = true
    return image
}
