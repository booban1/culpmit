import Foundation

// The list of capped apps, saved in settings so any app can join without a code change

struct CappedApp: Codable {
    var id: String
    var name: String
    var path: String
    var level: Double
    var on: Bool
    // the memory line in GB: past it, while memory is short, the app idles; unset means the Mac's default line
    var memoryLine: Double?

    var line: Double { memoryLine.map(snapLine) ?? defaultMemoryLine }
}

// a cap holds an app between 5% and 80% of the Mac, low enough to sit under what a busy app uses; its switch sets
// it free
let capRange = 0.05...0.8

// the memory line in whole GB, from a sixteenth of the Mac's memory (1 GB at least) to three quarters of it; a new
// app's line sits at half
let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / gib
let lineRange = max(1, (ramGB / 16).rounded())...(ramGB * 0.75).rounded(.down)
func snapLine(_ gb: Double) -> Double { min(lineRange.upperBound, max(lineRange.lowerBound, gb.rounded())) }
let defaultMemoryLine = snapLine(ramGB * 0.5)
func lineText(_ gb: Double) -> String { "\(Int(gb.rounded())) GB" }

func loadApps() -> [CappedApp] {
    guard let data = store.data(forKey: "cappedApps"), let apps = try? JSONDecoder().decode([CappedApp].self, from: data) else { return [] }
    // a level saved under the old 100% top comes back at the new top; Culpmit itself leaves the list
    return apps.filter { $0.id != Bundle.main.bundleIdentifier }
        .map { var app = $0; app.level = min(max(app.level, capRange.lowerBound), capRange.upperBound); return app }
}

func saveApps(_ apps: [CappedApp]) {
    store.set(try? JSONEncoder().encode(apps), forKey: "cappedApps")
}
