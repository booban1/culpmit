import Foundation

// The Talk to Figma socket on port 3055, run with Bun so the Figma plugin can connect

final class FigmaSocket {
    let port = 3055
    var cachedListener: pid_t?
    private var process: Process?

    // bun's own installer, then Homebrew on Intel and on Apple silicon
    var bunx: String? {
        [NSHomeDirectory() + "/.bun/bin/bunx", "/usr/local/bin/bunx", "/opt/homebrew/bin/bunx"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func lookupListener(_ all: [(port: Int, pid: pid_t)] = listeners()) -> pid_t? {
        all.first { $0.port == port }?.pid
    }

    var isOn: Bool { process?.isRunning == true || cachedListener != nil }

    func start() {
        guard let bunx, process?.isRunning != true, lookupListener() == nil else { return }
        let log = NSHomeDirectory() + "/Library/Logs/Culpmit figma-socket.log"
        FileManager.default.createFile(atPath: log, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bunx)
        p.arguments = ["cursor-talk-to-figma-socket"]
        p.environment = ["PATH": NSHomeDirectory() + "/.bun/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin", "HOME": NSHomeDirectory()]
        p.standardOutput = FileHandle(forWritingAtPath: log)
        p.standardError = p.standardOutput
        do {
            try p.run()
            process = p
            note("figma socket started on \(port)")
        } catch {
            note("figma socket failed to start: \(error)")
        }
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        if let pid = lookupListener() { kill(pid, SIGTERM) }
        cachedListener = nil
        note("figma socket stopped")
    }

    func stopIfMine() {
        guard process != nil else { return }
        stop()
    }
}
