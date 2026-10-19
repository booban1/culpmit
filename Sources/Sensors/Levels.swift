import AppKit

// Each readout's colour, alike in the menu bar, the menu and on the Touch Bar: orange from its alert's line, red from
// 90%. Temperature's 90% is 90 °C; the fan turns orange with the temperature and red at 90% of its top speed; memory
// also follows macOS's pressure.

enum Level: Int, Comparable {
    case normal, warm, hot

    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    var tint: NSColor? { self == .warm ? .systemOrange : self == .hot ? .systemRed : nil }
}

let hotShare = 0.9
let hotTemperature = 90.0

func temperatureLevel(_ c: Double?) -> Level {
    guard let c else { return .normal }
    return c >= hotTemperature ? .hot : c >= heatLine ? .warm : .normal
}

// load in percent of the whole Mac
func loadLevel(_ load: Double) -> Level { load >= hotShare * 100 ? .hot : load >= cpuAlertLine ? .warm : .normal }

func memoryLevel(_ m: MemoryReading) -> Level {
    let share = m.used / m.total
    if share >= hotShare || m.pressure == .critical { return .hot }
    return share >= memoryAlertLine || m.pressure == .warning ? .warm : .normal
}

// any fan near its top speed turns red
func fanLevel(_ speeds: [Double], _ maxes: [Double], temperature: Double?) -> Level {
    if zip(speeds, maxes).contains(where: { $1 > 0 && $0 >= hotShare * $1 }) { return .hot }
    return temperatureLevel(temperature) >= .warm ? .warm : .normal
}
