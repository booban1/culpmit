import AppKit

// A Touch Bar slider in the system's style: a thin track filled blue up to a round white knob

func roundSlider(value: Double, min: Double, max: Double, width: CGFloat, target: AnyObject, action: Selector) -> NSSlider {
    let slider = NSSlider()
    slider.cell = RoundSliderCell()
    slider.minValue = min
    slider.maxValue = max
    slider.doubleValue = value
    slider.target = target
    slider.action = action
    slider.isContinuous = true
    slider.widthAnchor.constraint(equalToConstant: width).isActive = true
    slider.heightAnchor.constraint(equalToConstant: 30).isActive = true
    return slider
}

// the track and knob drawn by hand, since the Touch Bar's own slider look belongs to its slider items
final class RoundSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2.5, width: rect.width, height: 5)
        NSColor(white: 1, alpha: 0.28).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        var filled = track
        filled.size.width = max(0, knobRect(flipped: flipped).midX - track.minX)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2.5, yRadius: 2.5).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let d: CGFloat = 16
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: knobRect.midX - d / 2, y: knobRect.midY - d / 2, width: d, height: d)).fill()
    }
}
