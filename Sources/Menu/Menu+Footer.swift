import AppKit

// The last sections: local servers, Touch Bar, open at login, then Update and Quit

extension Menu {
    func addFooterSection() {
        menu.addItem(serversItem())
        if strip.available {
            let touchBar = toggle("Touch Bar", "touchBar", strip.isShown)
            touchBar.view?.toolTip = "⌃⌥⌘C"
            menu.addItem(touchBar)
        }
        menu.addItem(everythingItem())
        menu.addItem(toggle("Open at login", "login", openAtLogin))

        let update = NSMenuItem(title: updater.busy ? "Updating" + loadingDots(updateDots) : "Update Culpmit",
                                action: #selector(runUpdate), keyEquivalent: "")
        updateMenuItem = update
        update.target = self
        update.isEnabled = !updater.busy
        update.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Update")
        update.toolTip = "Version \(updater.installed)"
        update.isHidden = !(updater.available || updater.busy)
        menu.addItem(update)
        let quit = NSMenuItem(title: "Quit Culpmit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
        menu.addItem(quit)
    }
}
