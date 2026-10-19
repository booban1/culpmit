import AppKit

// Resizes screenshots on the clipboard to the long side limit, area two thirds of its square, smaller ones untouched

final class Shrinker {
    var limit = 1500.0
    private let pb = NSPasteboard.general
    private let shotTypes: Set<String> = ["public.png", "Apple PNG pasteboard type", "public.tiff", "NeXT TIFF v4.0 pasteboard type"]
    private var seen: Int
    private var pending = -1
    private var since = Date()
    private var timer: Timer?

    init() { seen = pb.changeCount }

    var isOn: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        seen = pb.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let c = pb.changeCount
        if c != seen {
            seen = c
            pending = c
            since = Date()
        } else if pending == c, Date().timeIntervalSince(since) >= 0.3 {
            pending = -1
            shrink()
        }
    }

    private func shrink() {
        guard let types = pb.types?.map(\.rawValue), !types.isEmpty,
              Set(types).isSubset(of: shotTypes),
              let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: data) else { return }
        let pw = Double(rep.pixelsWide), ph = Double(rep.pixelsHigh)
        let scale = min(limit / max(pw, ph), (0.667 * limit * limit / (pw * ph)).squareRoot())
        let w = Int(pw * scale), h = Int(ph * scale)
        guard scale < 1, w > 0, h > 0,
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = out.representation(using: .png, properties: [:]) else { return }
        pb.clearContents()
        pb.setData(png, forType: .png)
        seen = pb.changeCount
    }
}
