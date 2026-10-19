import AppKit

// The Performance line: each figure with its icon in a soft rounded box, the boxes sharing the menu's width

final class StatTiles: NSView {
    private var boxes: [NSBox] = []
    private var parts: [(box: NSBox, icon: NSImageView, field: NSTextField)] = []
    private let margin: CGFloat = 14
    private let gap: CGFloat = 6

    // the width the boxes need side by side, for the menu's own width
    private(set) var need: CGFloat = 0

    init(_ items: [(icon: String, name: String, field: NSTextField)], size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 34))
        var widths: [CGFloat] = []
        for item in items {
            let box = NSBox()
            box.boxType = .custom
            box.fillColor = .quaternaryLabelColor
            box.borderWidth = 0
            box.cornerRadius = 7
            box.contentViewMargins = .zero
            box.toolTip = item.name
            let icon = NSImageView(image: NSImage(systemSymbolName: item.icon, accessibilityDescription: item.name)!
                .withSymbolConfiguration(.init(pointSize: size, weight: .regular))!)
            icon.contentTintColor = .labelColor
            let stack = NSStackView(views: [icon, item.field])
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            box.contentView?.addSubview(stack)
            if let content = box.contentView {
                NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                                             stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
            }
            addSubview(box)
            boxes.append(box)
            parts.append((box, icon, item.field))
            widths.append(18 + 6 + item.field.frame.width + 20)
        }
        need = 2 * margin + widths.reduce(0, +) + gap * CGFloat(max(0, items.count - 1))
        place()
    }

    required init?(coder: NSCoder) { fatalError("StatTiles come from code") }

    // a level's colour fills the figure's box, with dark text and icon on it for contrast; plain, the soft box returns
    func paint(_ field: NSTextField?, _ tint: NSColor?) {
        guard let part = parts.first(where: { $0.field === field }) else { return }
        let fill = tint ?? .quaternaryLabelColor
        guard part.box.fillColor != fill else { return }
        part.box.fillColor = fill
        let ink: NSColor = tint == nil ? .labelColor : .black
        part.field.textColor = ink
        part.icon.contentTintColor = ink
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }

    private func place() {
        guard !boxes.isEmpty else { return }
        let w = (bounds.width - 2 * margin - gap * CGFloat(boxes.count - 1)) / CGFloat(boxes.count)
        for (i, box) in boxes.enumerated() {
            box.frame = NSRect(x: margin + CGFloat(i) * (w + gap), y: 4, width: w, height: bounds.height - 8)
        }
    }
}
