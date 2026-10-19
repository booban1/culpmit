import AppKit
import ServiceManagement

// Culpmit at login and after a crash: a classic launch agent in ~/Library/LaunchAgents, owned by Open at login, opens
// Culpmit at login and brings it back after a crash, while an ordinary Quit keeps it closed. A classic agent runs on
// the self-signed certificate, where SMAppService's agent needs an Apple-trusted one. One copy runs
// at a time.

private let label = "com.simonbooban.culpmit"
private let agentPath = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
private let domain = "gui/\(getuid())"
private let job = "\(domain)/\(label)"

// the copy launchd keeps alive for the agent
let isAgentCopy = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label

var openAtLogin: Bool {
    get { FileManager.default.fileExists(atPath: agentPath) }
    set { newValue ? installAgent() : removeAgent() }
}

// for --status: the agent's file, and whether this copy is launchd's
var loginState: String { (openAtLogin ? "agent" : "off") + (isAgentCopy ? ", agent's copy" : "") }

private func launchctl(_ args: [String]) -> Int32 { run("/bin/launchctl", args).status }

private func installAgent() {
    // only a copy in an Applications folder writes the agent, so a build run from elsewhere leaves it be
    guard Bundle.main.bundlePath.contains("/Applications/"), let executable = Bundle.main.executablePath else { return }
    let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [executable],
        "RunAtLoad": true,
        // a crash brings it back; Quit, Force Quit and Activity Monitor keep it closed
        "KeepAlive": ["Crashed": true],
        "ThrottleInterval": 2,
        "ProcessType": "Interactive",
        "LimitLoadToSessionType": "Aqua",
        "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? label],
    ]
    try? FileManager.default.createDirectory(atPath: (agentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    (plist as NSDictionary).write(toFile: agentPath, atomically: true)
    try? SMAppService.mainApp.unregister()
    // a job already loaded carries on; otherwise loading it starts launchd's copy, which takes over from this one
    if launchctl(["print", job]) != 0 { _ = launchctl(["bootstrap", domain, agentPath]) }
}

private func removeAgent() {
    try? FileManager.default.removeItem(atPath: agentPath)
    if !isAgentCopy {
        _ = launchctl(["bootout", job])
        return
    }
    // unloading the agent ends launchd's copy, this one, so a copy opened by hand takes over first
    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    opener.arguments = ["-n", Bundle.main.bundlePath, "--args", "--take-over"]
    try? opener.run()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { _ = launchctl(["bootout", job]) }
}

// an older login item or SMAppService agent gives way to the classic agent
func migrateLogin() {
    let tried = SMAppService.agent(plistName: "com.simonbooban.culpmit.agent.plist")
    if tried.status != .notRegistered { try? tried.unregister() }
    if SMAppService.mainApp.status == .enabled { installAgent() }
    // an older agent file also answered Force Quit; its rewrite takes hold at the next load
    if openAtLogin, let saved = NSDictionary(contentsOfFile: agentPath), (saved["KeepAlive"] as? [String: Any])?["Crashed"] == nil {
        installAgent()
    }
}

// One copy at a time. Launchd's copy stays and asks any other to quit. A copy opened by hand starts launchd's when
// the agent is on and gives way to it, gives way to any copy already running, or, opened with --take-over, waits for
// the running copy to leave and stays.
func settleCopies() {
    let id = Bundle.main.bundleIdentifier ?? ""
    func others() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != getpid() && !$0.isTerminated }
    }
    func wait(_ seconds: Double, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    }
    if isAgentCopy {
        for other in others() { other.terminate() }
        return
    }
    if CommandLine.arguments.contains("--take-over") {
        wait(5) { others().isEmpty }
        return
    }
    if !others().isEmpty { exit(0) }
    guard openAtLogin, launchctl(["kickstart", job]) == 0 else { return }
    wait(3) { !others().isEmpty }
    if !others().isEmpty { exit(0) }
    note("login item: the agent's copy stayed down, so this copy runs on its own")
}
