import AppKit
import CryptoKit

// Uselim, the app that reads Claude's usage limits, installed in the background by the Claude limits switch.
// The latest release of booban1/uselim carries Uselim-<version>.zip beside Uselim-<version>.zip.sha256. The zip must
// match its digest and its app must meet Uselim's designated requirement, a pinned certificate, before it reaches
// Applications. Uselim's own commands do the rest: --setup adds its hooks and plugin to Claude Code, turns on its open
// at login and starts it, one JSON line per step; --state answers where it stands. A copy already in Applications
// skips the download: switching on runs --setup again, and Uselim updates itself from its own releases.

// /Applications first; an account /Applications refuses, a standard user's, gets ~/Applications, made when missing
private let systemApp = "/Applications/Uselim.app"
private let userApp = NSHomeDirectory() + "/Applications/Uselim.app"
private let uselimID = "com.simonbooban.uselim"
private let uselimRelease = URL(string: "https://api.github.com/repos/booban1/uselim/releases/latest")!
private let uselimRequirement =
    #"identifier "com.simonbooban.uselim" and certificate leaf = H"140952e822dd4f3065dc6fed4ec81e013bb11ff0""#

final class UselimInstaller {
    enum Phase: Equatable {
        case idle
        case working(String)
        case stopped(String)
        case needsClaude
    }

    private(set) var phase = Phase.idle
    // the version --state last answered, or the one in the app's bundle
    private(set) var version: String?
    var changed: () -> Void = {}
    // a release zip on disk with its .sha256 beside it, in place of GitHub's latest release, for --uselim-install
    var localZip: URL?

    // the copy in use: the one in /Applications, else the one in ~/Applications
    var appPath: String? {
        [systemApp, userApp].first { FileManager.default.isExecutableFile(atPath: $0 + "/Contents/MacOS/Uselim") }
    }
    private var binary: String? { appPath.map { $0 + "/Contents/MacOS/Uselim" } }
    var isPresent: Bool { appPath != nil }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: uselimID).isEmpty }
    var isBusy: Bool { if case .working = phase { return true } else { return false } }

    // --state off the main thread, at launch and as the menu opens; a copy that predates --state answers through
    // its bundle's version
    func readState() {
        guard let app = appPath, let binary else {
            version = nil
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let answer = run(binary, ["--state"])
            let json = answer.out.split(separator: "\n").last.flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            let bundle = Bundle(path: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            DispatchQueue.main.async {
                self.version = (json?["version"] as? String) ?? bundle
                self.changed()
            }
        }
    }

    // the switch turned on: a copy in Applications needs only its setup; otherwise the latest release comes first
    func turnOn() {
        guard !isBusy else { return }
        if isPresent { return setUp() }
        set(.working("Downloading Uselim…"))
        latest { assets in
            guard let assets else { return self.set(.stopped("Stopped at the download")) }
            self.fetch(assets.zip) { zip in
                self.fetch(assets.digest) { digest in
                    guard let zip, let digest else { return self.set(.stopped("Stopped at the download")) }
                    self.set(.working("Checking Uselim's signature…"))
                    DispatchQueue.global(qos: .userInitiated).async {
                        let checked = self.check(zip: zip, digest: digest)
                        DispatchQueue.main.async {
                            guard let app = checked else { return self.set(.stopped("Stopped at the signature check")) }
                            guard let placed = self.place(app) else {
                                return self.set(.stopped("Stopped at both Applications folders"))
                            }
                            note("uselim: installed in \(placed)")
                            self.setUp()
                        }
                    }
                }
            }
        }
    }

    private func set(_ next: Phase) {
        phase = next
        if case .stopped(let why) = next { note("uselim: \(why)") }
        changed()
    }

    // the release's zip and its digest file, from GitHub's latest release of booban1/uselim
    private func latest(_ done: @escaping ((zip: URL, digest: URL)?) -> Void) {
        if let localZip {
            let digest = URL(fileURLWithPath: localZip.path + ".sha256")
            let both = FileManager.default.fileExists(atPath: localZip.path) && FileManager.default.fileExists(atPath: digest.path)
            return DispatchQueue.main.async { done(both ? (localZip, digest) : nil) }
        }
        var request = URLRequest(url: uselimRelease, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            var found: (URL, URL)?
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let assets = json["assets"] as? [[String: Any]] {
                let link = { (suffix: String) -> URL? in
                    (assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }?["browser_download_url"] as? String)
                        .flatMap(URL.init(string:))
                }
                if let zip = link(".zip"), let digest = link(".zip.sha256") { found = (zip, digest) }
            }
            DispatchQueue.main.async { done(found) }
        }.resume()
    }

    // a download moved to a folder of its own, since URLSession clears its temporary file once the handler returns
    private func fetch(_ url: URL, _ done: @escaping (URL?) -> Void) {
        if url.isFileURL {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("culpmit-uselim-\(UUID().uuidString)")
            let target = dir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copied = (try? FileManager.default.copyItem(at: url, to: target)) != nil
            return DispatchQueue.main.async { done(copied ? target : nil) }
        }
        URLSession.shared.downloadTask(with: url) { file, response, _ in
            var kept: URL?
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let file, code == 200 {
                let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("culpmit-uselim-\(UUID().uuidString)")
                let target = dir.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if (try? FileManager.default.moveItem(at: file, to: target)) != nil { kept = target }
            }
            DispatchQueue.main.async { done(kept) }
        }.resume()
    }

    // the zip's SHA-256 against its digest file, then the unpacked app against Uselim's pinned requirement
    private func check(zip: URL, digest: URL) -> URL? {
        guard let data = try? Data(contentsOf: zip),
              let expected = (try? String(contentsOf: digest, encoding: .utf8))?
                .split(whereSeparator: \.isWhitespace).first?.lowercased() else { return nil }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { return nil }
        let dir = zip.deletingLastPathComponent().appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]).status == 0 else { return nil }
        let app = dir.appendingPathComponent("Uselim.app")
        let verified = run("/usr/bin/codesign", ["--verify", "--strict", "-R=" + uselimRequirement, app.path])
        return verified.status == 0 ? app : nil
    }

    // the app copied to /Applications when this account may write there, else to ~/Applications; the path it landed in
    private func place(_ app: URL) -> String? {
        let manager = FileManager.default
        var targets: [String] = []
        if manager.isWritableFile(atPath: "/Applications") { targets.append(systemApp) }
        targets.append(userApp)
        for target in targets {
            try? manager.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if run("/usr/bin/ditto", [app.path, target]).status == 0,
               manager.isExecutableFile(atPath: target + "/Contents/MacOS/Uselim") { return target }
        }
        return nil
    }

    // Uselim --setup in the background, its JSON lines turned into the row's words: 0 done, 2 Claude Code missing
    // (the hooks still set), anything else a stop
    private func setUp() {
        guard let binary else { return set(.stopped("Stopped at setup")) }
        set(.working("Setting up Uselim…"))
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = ["--setup"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                return DispatchQueue.main.async { self.set(.stopped("Stopped at setup")) }
            }
            // the steps arrive one line at a time; a setup that runs past two minutes ends as a stop
            let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: deadline)
            var buffer = Data()
            while true {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer[buffer.startIndex..<end]
                    buffer.removeSubrange(buffer.startIndex...end)
                    guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let step = json["step"] as? String else { continue }
                    let words: String
                    switch step {
                    case "hooks", "statusline": words = "Adding Uselim's hooks…"
                    case "plugin": words = "Adding Uselim's plugin…"
                    default: words = "Starting Uselim…"
                    }
                    DispatchQueue.main.async { self.set(.working(words)) }
                }
            }
            p.waitUntilExit()
            deadline.cancel()
            let status = p.terminationStatus
            DispatchQueue.main.async {
                switch status {
                case 0:
                    note("uselim: set up")
                    self.set(.idle)
                case 2: self.set(.needsClaude)
                default: self.set(.stopped("Stopped at setup"))
                }
                self.readState()
            }
        }
    }
}
