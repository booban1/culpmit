import Foundation

// One line per event in ~/Library/Logs/Culpmit.log

func note(_ text: String) {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = stamp.string(from: Date()) + " " + text + "\n"
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Culpmit.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
