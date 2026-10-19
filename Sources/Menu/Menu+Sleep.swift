import AppKit

// Sleep's switches, in one group with the Figma socket under no heading: Caffeinate, radios off while asleep, back to
// sleep after an idle lid open (laptops), and what keeps the Mac awake

extension Menu {
    func addSleepSection() {
        menu.addItem(toggle("Caffeinate", "awake", awake.isOn))
        menu.addItem(toggle("Wi-Fi and Bluetooth off while asleep", "radios", store.bool(forKey: "radios")))
        if Radios.hasLid {
            menu.addItem(toggle("Back to sleep after an idle lid open", "backToSleep", store.bool(forKey: "backToSleep")))
        }
        let holders = kit.row("Kept awake by", "", icon: "cup.and.saucer")
        holders.item.isHidden = true
        holdersRow = holders
        menu.addItem(holders.item)
        menu.addItem(.separator())
    }

    func tickSleep() {
        guard let holdersRow else { return }
        let holders = sleepHolders()
        show(holdersRow.item, !holders.isEmpty)
        holdersRow.value?.stringValue = holders.isEmpty ? "–" : holders.joined(separator: ", ")
        holdersRow.value?.sizeToFit()
    }

    func checkLidWake() {
        guard store.bool(forKey: "backToSleep"), wakeReason().contains("LidOpen") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard idleSeconds() >= 14 else { return }
            note("lid opened, untouched for 15 s: back to sleep")
            run("/usr/bin/pmset", ["sleepnow"])
        }
    }
}
