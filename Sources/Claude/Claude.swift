import AppKit

// Claude's usage limits and the chats waiting for an answer, read from the files Uselim keeps in its Application Support
// folder: the last read (state.json), the status line's push (limits.json, newer while a chat works) and one file per
// waiting chat. Culpmit reads them while its strip is open and makes zero calls of its own. Colours follow Uselim's
// lines: orange from 60%, red from 80%.

struct ClaudeLimit {
    let kind: String
    let name: String
    let percent: Int
    let resets: Date?
}

struct ClaudeWait {
    let project: String
    let kind: String
    let at: Date
}

struct Claude {
    let limits: [ClaudeLimit]
    let at: Date
    let waiting: [ClaudeWait]
    var session: ClaudeLimit? { limits.first { $0.kind == "session" } }
    var weekly: ClaudeLimit? { limits.first { $0.kind == "weekly_all" } }
    // figures older than ten minutes show in grey, Uselim's own line for its bar
    var stale: Bool { Date().timeIntervalSince(at) > 600 }
}

private let uselimDir = NSHomeDirectory() + "/Library/Application Support/Uselim"

private func json(at path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func limit(_ row: [String: Any], kind: String, name: String) -> ClaudeLimit? {
    guard let percent = (row["percent"] as? NSNumber)?.intValue else { return nil }
    return ClaudeLimit(kind: kind, name: name, percent: percent,
                       resets: (row["resets"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
}

func claudeReading() -> Claude? {
    guard let state = json(at: uselimDir + "/state.json"), var at = (state["at"] as? NSNumber)?.doubleValue,
          let rows = state["limits"] as? [[String: Any]] else { return nil }
    var limits = rows.compactMap { row -> ClaudeLimit? in
        guard let kind = row["kind"] as? String, let name = row["name"] as? String else { return nil }
        return limit(row, kind: kind, name: name)
    }
    // the push, when newer than the read: the session and the week
    if let push = json(at: uselimDir + "/limits.json"), let pushedAt = (push["at"] as? NSNumber)?.doubleValue, pushedAt > at {
        at = pushedAt
        for (kind, name) in [("session", "Session (5 hr)"), ("weekly_all", "Weekly (7 days)")] {
            guard let entry = push[kind] as? [String: Any], let fresh = limit(entry, kind: kind, name: name) else { continue }
            if let i = limits.firstIndex(where: { $0.kind == kind }) { limits[i] = fresh } else { limits.append(fresh) }
        }
    }
    let rank = ["session": 0, "weekly_all": 1]
    limits.sort { (rank[$0.kind] ?? 2) < (rank[$1.kind] ?? 2) }
    let waitingDir = uselimDir + "/waiting"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: waitingDir)) ?? []
    let waiting = names.filter { $0.hasSuffix(".json") }.compactMap { name -> ClaudeWait? in
        guard let w = json(at: waitingDir + "/" + name), let kind = w["kind"] as? String else { return nil }
        return ClaudeWait(project: w["project"] as? String ?? "", kind: kind,
                          at: Date(timeIntervalSince1970: (w["at"] as? NSNumber)?.doubleValue ?? 0))
    }.sorted { $0.at > $1.at }
    return Claude(limits: limits, at: Date(timeIntervalSince1970: at), waiting: waiting)
}

// orange from 60%, red from 80%; nil keeps the label colour
func claudeTint(_ percent: Int) -> NSColor? { percent >= 80 ? .systemRed : percent >= 60 ? .systemOrange : nil }

private let claudeTime: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f
}()

private let claudeDay: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEE")
    return f
}()

// "21:20 · 48m" today, "Fri 05:00 · 8h 30m" on another day
func claudeWhen(_ resets: Date, now: Date = Date()) -> String {
    let s = Int(max(0, resets.timeIntervalSince(now)))
    let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
    let left = d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    let day = Calendar.current.isDate(resets, inSameDayAs: now) ? "" : claudeDay.string(from: resets) + " "
    return "\(day)\(claudeTime.string(from: resets)) · \(left)"
}

// a model's line carries its name in place of a time: "Fable"
func claudeWord(_ limit: ClaudeLimit) -> String { limit.name.replacingOccurrences(of: " (weekly)", with: "") }

// a small orange dot, 5 pt, beside the figures while a chat waits
final class Dot: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 5, height: 5))
        widthAnchor.constraint(equalToConstant: 5).isActive = true
        heightAnchor.constraint(equalToConstant: 5).isActive = true
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
