import AppKit

// A swipeable Touch Bar row: it grows with its items up to a set width, a swipe moves through the rest,
// a tap reports the index, and a still half-second hold reports it to onHold

final class Shelf: NSObject, NSScrubberDataSource, NSScrubberFlowLayoutDelegate {
    enum Entry {
        case text(String, mark: Bool)
        case picture(NSImage, mark: Bool)
        case icon(NSImage, dim: Bool, mark: Bool, label: String)
    }

    let view = NSScrubber()
    var onTap: (Int) -> Void = { _ in }
    var onHold: ((Int) -> Void)?
    // the pulse a held item shows before its screen opens
    var holdPause: TimeInterval = 0.2
    private var held = false
    private var entries: [Entry] = []
    private var key: String?
    private(set) var contentWidth: CGFloat = 0
    var maxWidth: CGFloat { didSet { fit() } }
    var shownWidth: CGFloat { width.constant }
    private let spacing: CGFloat = 6
    private lazy var width = view.widthAnchor.constraint(equalToConstant: 0)
    private let textID = NSUserInterfaceItemIdentifier("text")
    private let pictureID = NSUserInterfaceItemIdentifier("picture")
    private let iconID = NSUserInterfaceItemIdentifier("icon")

    init(maxWidth: CGFloat) {
        self.maxWidth = maxWidth
        super.init()
        let layout = NSScrubberFlowLayout()
        layout.itemSpacing = spacing
        view.scrubberLayout = layout
        view.mode = .free
        view.isContinuous = false
        view.showsAdditionalContentIndicators = true
        view.selectionBackgroundStyle = nil
        view.register(TextItem.self, forItemIdentifier: textID)
        view.register(PictureItem.self, forItemIdentifier: pictureID)
        view.register(IconItem.self, forItemIdentifier: iconID)
        view.dataSource = self
        view.delegate = self
        width.isActive = true
        view.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let press = NSPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.allowedTouchTypes = .direct
        press.minimumPressDuration = 0.5
        press.allowableMovement = 8
        view.addGestureRecognizer(press)
    }

    // a hold finds the item under the finger; the lift that follows is ignored as a tap
    @objc private func pressed(_ press: NSPressGestureRecognizer) {
        if press.state == .ended || press.state == .cancelled || press.state == .failed {
            // the lift after a hold may never arrive as a tap once the screen has moved on, so the next tap stays live
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.held = false }
            return
        }
        guard press.state == .began, let onHold else { return }
        let layout = view.scrubberLayout
        let x = press.location(in: view).x + layout.visibleRect.minX
        guard let i = layout.layoutAttributesForItems(in: NSRect(x: x, y: 0, width: 1, height: 30)).map(\.itemIndex).first,
              entries.indices.contains(i) else { return }
        held = true
        // a quick pulse on the held item, then its screen grows out of it
        pulse(i)
        DispatchQueue.main.asyncAfter(deadline: .now() + holdPause) { onHold(i) }
    }

    // the middle of one item in another view's terms, so its screen can grow out of it
    func center(of i: Int, in other: NSView) -> CGFloat? {
        guard let item = view.itemViewForItem(at: i) else { return nil }
        return item.convert(NSPoint(x: item.bounds.midX, y: 0), to: other).x
    }

    // a quick dip in opacity, so a touch shows it landed
    private func pulse(_ i: Int) {
        guard let item = view.itemViewForItem(at: i) else { return }
        item.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 0.12
        pulse.autoreverses = true
        item.layer?.add(pulse, forKey: "pulse")
    }

    // new entries only when the key changes; a swiped row returns to the item it showed first
    func show(_ key: String, _ make: () -> [Entry]) {
        guard key != self.key else { return }
        self.key = key
        let first = firstVisible()
        entries = make()
        contentWidth = entries.indices.reduce(0) { $0 + size(at: $1).width } + spacing * CGFloat(max(0, entries.count - 1))
        fit()
        view.reloadData()
        if let first, first < entries.count { view.scrollItem(at: first, to: .leading) }
    }

    private func fit() { width.constant = min(contentWidth, maxWidth) }

    private func firstVisible() -> Int? {
        let layout = view.scrubberLayout
        guard layout.visibleRect.minX > 1 else { return nil }
        return layout.layoutAttributesForItems(in: layout.visibleRect).map(\.itemIndex).min()
    }

    private func size(at i: Int) -> NSSize {
        switch entries[i] {
        case .text(let s, _): return NSSize(width: TextItem.width(s), height: 30)
        case .picture: return NSSize(width: 40, height: 30)
        case .icon: return NSSize(width: 30, height: 30)
        }
    }

    func numberOfItems(for scrubber: NSScrubber) -> Int { entries.count }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = itemView(scrubber, index)
        // a hold's screen, reachable by VoiceOver and scripts too
        view.setAccessibilityCustomActions(onHold == nil ? nil : [NSAccessibilityCustomAction(name: "Details") { [weak self] in
            self?.onHold?(index)
            return true
        }])
        return view
    }

    private func itemView(_ scrubber: NSScrubber, _ index: Int) -> NSScrubberItemView {
        switch entries[index] {
        case .text(let s, let mark):
            let v = scrubber.makeItem(withIdentifier: textID, owner: nil) as? TextItem ?? TextItem(frame: .zero)
            v.label.stringValue = s
            v.dot.isHidden = !mark
            v.setAccessibilityLabel(s)
            return v
        case .picture(let image, let mark):
            let v = scrubber.makeItem(withIdentifier: pictureID, owner: nil) as? PictureItem ?? PictureItem(frame: .zero)
            v.picture.image = image
            v.dot.isHidden = !mark
            v.setAccessibilityLabel("Image")
            return v
        case .icon(let image, let dim, let mark, let label):
            let v = scrubber.makeItem(withIdentifier: iconID, owner: nil) as? IconItem ?? IconItem(frame: .zero)
            v.picture.image = image
            // app icons fill the slot; a symbol such as the helpers' gear keeps its own size
            v.picture.imageScaling = image.isTemplate ? .scaleProportionallyDown : .scaleProportionallyUpOrDown
            v.picture.alphaValue = dim ? 0.4 : 1
            v.dot.isHidden = !mark
            v.setAccessibilityLabel(label)
            return v
        }
    }

    func scrubber(_ scrubber: NSScrubber, layout: NSScrubberFlowLayout, sizeForItemAt itemIndex: Int) -> NSSize {
        size(at: itemIndex)
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt selectedIndex: Int) {
        guard entries.indices.contains(selectedIndex) else { return }
        let wasHeld = held
        held = false
        if !wasHeld { pulse(selectedIndex) }
        DispatchQueue.main.async {
            scrubber.selectedIndex = -1
            if !wasHeld { self.onTap(selectedIndex) }
        }
    }
}

// the small orange dot that marks an item, centred beneath it
private func place(_ dot: NSView, under item: NSView) {
    dot.wantsLayer = true
    dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
    dot.layer?.cornerRadius = 1.5
    dot.translatesAutoresizingMaskIntoConstraints = false
    item.addSubview(dot)
    NSLayoutConstraint.activate([
        dot.centerXAnchor.constraint(equalTo: item.centerXAnchor),
        dot.bottomAnchor.constraint(equalTo: item.bottomAnchor),
        dot.widthAnchor.constraint(equalToConstant: 3),
        dot.heightAnchor.constraint(equalToConstant: 3),
    ])
}

// a text chip, 24 pt tall, with room beneath it for the dot
private final class TextItem: NSScrubberItemView {
    static let font = NSFont.systemFont(ofSize: 11)
    static func width(_ s: String) -> CGFloat { min(150, ceil((s as NSString).size(withAttributes: [.font: font]).width) + 28) }

    let label = NSTextField(labelWithString: "")
    let dot = NSView()
    private let chip = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        chip.layer?.cornerRadius = 6
        chip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chip)
        label.font = TextItem.font
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)
        place(dot, under: self)
        NSLayoutConstraint.activate([
            chip.topAnchor.constraint(equalTo: topAnchor, constant: 1.5),
            chip.heightAnchor.constraint(equalToConstant: 24),
            chip.leadingAnchor.constraint(equalTo: leadingAnchor),
            chip.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Shelf items come from code") }
}

// a screenshot thumbnail, level with the chips, with room beneath it for the dot
private final class PictureItem: NSScrubberItemView {
    let picture = NSImageView()
    let dot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 4
        picture.layer?.masksToBounds = true
        picture.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picture)
        place(dot, under: self)
        NSLayoutConstraint.activate([
            picture.centerXAnchor.constraint(equalTo: centerXAnchor),
            picture.topAnchor.constraint(equalTo: topAnchor, constant: 2.5),
            picture.widthAnchor.constraint(equalToConstant: 36),
            picture.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Shelf items come from code") }
}

// an app icon, with the dot beneath it when marked
private final class IconItem: NSScrubberItemView {
    let picture = NSImageView()
    let dot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picture)
        place(dot, under: self)
        NSLayoutConstraint.activate([
            picture.centerXAnchor.constraint(equalTo: centerXAnchor),
            picture.centerYAnchor.constraint(equalTo: centerYAnchor),
            picture.widthAnchor.constraint(equalToConstant: 26),
            picture.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Shelf items come from code") }
}
