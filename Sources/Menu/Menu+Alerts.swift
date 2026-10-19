import AppKit

// The CPU alert on its own line, and the red alerts: a readout at 90% for a minute speaks while its alert's switch is
// on, at most once in 15 minutes, and stands in for its orange alert; with the switch off the readout still turns red,
// so someone expecting heat stays unbothered. The fan speaks through the temperature's alerts and shows red while it
// spins past 90% of its top speed.

// one alert's clock: how long its condition has held, and when it last spoke
struct AlertClock {
    var since: Date?
    var last = Date.distantPast

    // true once the condition has held for a minute, 15 minutes after the last alert
    mutating func due(_ holding: Bool) -> Bool {
        guard holding else {
            since = nil
            return false
        }
        let start = since ?? Date()
        since = start
        guard Date().timeIntervalSince(start) >= 60, Date().timeIntervalSince(last) > 900 else { return false }
        last = Date()
        return true
    }

    var held: String {
        let m = since.map { max(1, Int(Date().timeIntervalSince($0) / 60)) } ?? 1
        return m == 1 ? "1 minute" : "\(m) minutes"
    }
}

// the CPU alert's line, CPU load as a share of the whole Mac, set on its slider in steps of 5%
var cpuAlertLine: Double { store.double(forKey: "cpuLine") }
let cpuRange = 25.0...90.0

extension Menu {
    func checkLoad() {
        guard loadClock.due(store.bool(forKey: "cpuAlerts") && machineLoad >= cpuAlertLine) else { return }
        postBusiest("cpu", title: "CPU at \(percent(machineLoad)) for \(loadClock.held)")
    }

    func checkHot(_ temp: Double?) {
        if hotTemp.due(store.bool(forKey: "heatAlerts") && temperatureLevel(temp) == .hot), let temp {
            lastHeatAlert = Date()
            postBusiest("hot", title: "\(Int(temp.rounded())) °C for \(hotTemp.held)")
        }
        if hotLoad.due(store.bool(forKey: "cpuAlerts") && loadLevel(machineLoad) == .hot) {
            loadClock.last = Date()
            postBusiest("cpu", title: "CPU at \(percent(machineLoad)) for \(hotLoad.held)")
        }
        if let m = memoryReading(), hotMemory.due(store.bool(forKey: "memoryAlerts") && memoryLevel(m) == .hot) {
            lastMemoryAlert = Date()
            postMemory(m, title: "Memory at \(gigabytes(m.used)) of \(Int((m.total / gib).rounded())) GB for \(hotMemory.held)")
        }
    }

    // the busiest app by CPU with its cores, offering Cap and Idle
    func postBusiest(_ kind: String, title: String) {
        if let hog = topHogs(snapshot().byPid, count: 1).first {
            let cores = max(1, Int((hog.cpu * threads / 100).rounded()))
            alerts.post(kind, title: title, body: "\(hog.name) is using \(cores == 1 ? "1 core" : "\(cores) cores").",
                        category: canIdle(hog.pid) ? "heat" : "", info: ["pid": Int(hog.pid)])
        } else {
            alerts.post(kind, title: title, body: "The Mac is working hard.")
        }
    }

    // the heaviest app by memory, offering Idle
    func postMemory(_ m: MemoryReading, title: String, swapping: Bool = false) {
        let swap = swapping ? "Swap is at \(gigabytes(m.swap)) and growing." : ""
        if let hog = topHogs(snapshot().byPid, count: 1, byMemory: true).first {
            alerts.post("memory", title: title, body: "\(hog.name) is using \(gigabytes(hog.memory)). \(swap)",
                        category: canIdle(hog.pid) ? "memory" : "", info: ["pid": Int(hog.pid)])
        } else {
            alerts.post("memory", title: title, body: swapping ? swap : "Memory used is past its line.")
        }
    }

    // each readout's colour now, for the menu bar, the menu and the Touch Bar
    func levels(_ temp: Double?, _ fans: [Double]) -> (temp: Level, fan: Level, load: Level) {
        (temperatureLevel(temp), fanLevel(fans, smc?.fanMaxes() ?? [], temperature: temp), loadLevel(machineLoad))
    }
}
