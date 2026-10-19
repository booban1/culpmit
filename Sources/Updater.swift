import AppKit

// Checks GitHub for a newer Culpmit release, downloads it and swaps it in; the new copy announces itself after the restart

final class Updater {
    enum State {
        case working
        case installing(String)
        case upToDate(String)
        case stopped(String)
    }

    let latestURL = URL(string: "https://api.github.com/repos/booban1/culpmit/releases/latest")!
    private(set) var busy = false
    private(set) var available = false
    private var checkedAt = Date.distantPast

    var installed: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var commit: String { Bundle.main.object(forInfoDictionaryKey: "CulpmitCommit") as? String ?? "–" }
    var local: Bool { Bundle.main.object(forInfoDictionaryKey: "CulpmitLocal") as? Bool ?? false }

    // asks GitHub for the latest release at launch and when the menu opens, at most once an hour; the Update row shows while it is newer
    func check() {
        guard !busy, !local, Date().timeIntervalSince(checkedAt) >= 3600 else { return }
        checkedAt = Date()
        latest { found in
            self.available = found.map { newer($0.version, than: self.installed) } ?? false
        }
    }

    private func latest(_ done: @escaping ((version: String, zip: URL)?) -> Void) {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            var found: (version: String, zip: URL)?
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String, let assets = json["assets"] as? [[String: Any]],
               let link = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true })?["browser_download_url"] as? String,
               let zip = URL(string: link) {
                found = (tag.trimmingCharacters(in: CharacterSet(charactersIn: "v")), zip)
            }
            DispatchQueue.main.async { done(found) }
        }.resume()
    }

    func update(_ report: @escaping (State) -> Void) {
        guard !busy else { return }
        busy = true
        report(.working)
        let finish = { (state: State) in
            self.busy = false
            if case .upToDate = state { self.available = false }
            store.removeObject(forKey: "updatingTo")
            report(state)
        }
        latest { found in
            guard let found else { return finish(.stopped("GitHub is out of reach right now. Try Update again later.")) }
            guard newer(found.version, than: self.installed) else { return finish(.upToDate(found.version)) }
            store.set(found.version, forKey: "updatingTo")
            note("update: installing \(found.version) over \(self.installed)")
            report(.installing(found.version))
            URLSession.shared.downloadTask(with: found.zip) { file, _, _ in
                let ready = file.flatMap { self.unpack($0) }
                DispatchQueue.main.async {
                    guard let ready, self.swap(to: ready) else {
                        return finish(.stopped("The new version arrived incomplete. Try Update again."))
                    }
                    NSApp.terminate(nil)
                }
            }.resume()
        }
    }

    // the downloaded zip, unpacked beside the other updates, checked to be Culpmit
    private func unpack(_ zip: URL) -> URL? {
        let dir = NSHomeDirectory() + "/Library/Application Support/Culpmit/update-\(Int(Date().timeIntervalSince1970))"
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir]).status == 0 else { return nil }
        let app = URL(fileURLWithPath: dir + "/Culpmit.app")
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier ? app : nil
    }

    // a small script waits for this copy to quit, moves it to the Trash, puts the new one in its place and opens it
    private func swap(to new: URL) -> Bool {
        let app = Bundle.main.bundlePath
        guard app.hasSuffix("/Culpmit.app") else { return false }
        let script = """
        while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/mv "\(app)" "$HOME/.Trash/Culpmit \(installed).app"
        /usr/bin/ditto "\(new.path)" "\(app)"
        /usr/bin/touch "\(app)"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "\(app)"
        /usr/bin/open "\(app)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        return true
    }
}

// true when version a sorts after b, part by part, so 1.10.0 comes after 1.9.2
func newer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}
