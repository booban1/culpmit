import AppKit

// Developer tools: the Talk to Figma socket switch and the local servers list

extension Menu {
    func addFigmaSection() {
        // the socket's switch opens the group of switches that follows, Sleep's, under no heading
        guard figma.bunx != nil else { return }
        let socket = toggle("Talk to Figma socket", "figmaSocket", figma.isOn)
        socket.view?.toolTip = "Port \(figma.port)"
        menu.addItem(socket)
    }

    func serversItem() -> NSMenuItem {
        let srv = NSMenuItem(title: "Local servers", action: nil, keyEquivalent: "")
        srv.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        srv.submenu = serversMenu()
        srv.isHidden = servers.isEmpty
        serversMenuItem = srv
        serversShown = servers
        return srv
    }

    func tickServers() {
        guard servers != serversShown else { return }
        serversShown = servers
        serversMenuItem?.submenu = serversMenu()
        show(serversMenuItem, !servers.isEmpty)
    }

    func serversMenu() -> NSMenu {
        let sub = NSMenu()
        for s in servers {
            let m = NSMenuItem(title: "localhost:\(s.port)  ·  \(s.name)", action: #selector(openServer(_:)), keyEquivalent: "")
            m.target = self
            m.tag = s.port
            sub.addItem(m)
        }
        return sub
    }

    @objc func openServer(_ sender: NSMenuItem) {
        if let url = URL(string: "http://localhost:\(sender.tag)") { NSWorkspace.shared.open(url) }
    }
}
