import AppKit

// Update Culpmit: loading dots in place of the rpm while it works, and notifications at the start and on success

extension Menu {
    @objc func runUpdate() {
        updater.update { [weak self] state in self?.updateState(state) }
    }

    func updateState(_ state: Updater.State) {
        switch state {
        case .working:
            animateUpdate(true)
        case .installing(let version):
            animateUpdate(true)
            alerts.post("update", title: "Updating Culpmit to \(version)", body: "Culpmit restarts by itself when it's done.")
        case .upToDate:
            animateUpdate(false)
            alerts.post("update", title: "Culpmit is up to date", body: "Already on the latest version.")
        case .stopped(let text):
            animateUpdate(false)
            alerts.post("update", title: "Culpmit update", body: text)
        }
        refreshBar()
    }

    func animateUpdate(_ on: Bool) {
        guard on else {
            updateTicker?.invalidate()
            updateTicker = nil
            updatingDots = nil
            updateMenuItem?.title = "Update Culpmit"
            updateMenuItem?.isEnabled = true
            return
        }
        guard updateTicker == nil else { return }
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateDots = self.updateDots % 3 + 1
            self.updatingDots = self.updateDots
            self.updateMenuItem?.title = "Updating" + loadingDots(self.updateDots)
            self.refreshBar()
        }
        RunLoop.main.add(t, forMode: .common)
        updateTicker = t
        t.fire()
    }

    // one notice per new version, whichever way it arrived: Update, Homebrew, the install script or a download
    func announceUpdate() {
        store.removeObject(forKey: "updatingTo")
        let now = updater.installed
        defer { store.set(now, forKey: "lastVersion") }
        guard let last = store.string(forKey: "lastVersion"), last != now else { return }
        alerts.post("update", title: "Culpmit \(now) is running", body: "Previously \(last).")
    }
}
