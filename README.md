# Culpmit

**Culprit Limiter** for Intel Macs, Windows PCs and Linux machines that run *hot*.

Culpmit sits in the menu bar with the CPU temperature over the fan speed. When something heats the Mac, it names the app and holds it to a share of the processor, so the fans *settle* and the work carries on. One switch adds Uselim for Claude's usage limits, and [the guide](https://simonbooban.com/resources/how-to-use-culpmit) walks through each part. On [Windows](#windows) and [Linux](#linux), Culpmit sits in the tray as two dots.

<p align="center"><img src="screenshots/menu.gif" alt="Culpmit's menu on a MacBook Pro, top to foot: the readout's boxes, Cap and Idle on busy apps and the + row, capped apps with their sliders, the clipboard history, the switches, the alert lines, and Local servers, Claude limits, Touch Bar and Open at login"></p>

## What it does

- **Readout:** the CPU temperature over the faster fan's speed in the menu bar, live every second; in the menu, temperature, fan, CPU load and memory used side by side. Each figure's box turns orange at its alert's line and red at 90% (90 °C for the temperature), and the Touch Bar's figures take the same colours; the fan turns orange with the temperature and red past 90% of its top speed, and memory also follows macOS's memory pressure.
- **Busy apps:** apps using half a core or more, plus the three holding the most memory, each once with its CPU share and memory, a tortoise to cap it and a moon to idle it, red while on. Up to four show as rows; with five or more, three rows and a + row with the rest. Cap sets a ceiling at half of what the app uses at that moment, so one click slows it. Idle holds an app to a tenth of one core, so it keeps running cool until you wake it.
- **Capped apps:** every app you cap, with every process it starts, held to a share of the Mac from 5% to 80%, beside its memory line: past the line, while memory is short, the app idles so macOS can squeeze its memory, and it wakes when you switch to it or memory eases. The app in front stays live. Its switch lets it run free. Hold Option while opening the menu to add or remove apps.
- **Memory alerts:** when memory used stays past a line you set from 25 to 95% of memory, shown in GB (90% to start), or macOS keeps moving memory to swap, for a minute, a notification names the heaviest app with Idle.
- **CPU alerts:** at a line you set from 25 to 90% of the whole Mac, 80 to start, held for a minute, a notification names the busiest app with Cap and Idle.
- **Red alerts:** a figure at 90% for a minute brings one more alert while its switch is on; with the switch off, the figure turns red in silence.
- **Heat alerts:** at a line you set from 50 to 90 °C, 85 to start, held for a minute, a notification names the busiest app with Cap and Idle.
- **Test load:** seven small test apps for one to thirty minutes: six keep every core busy and the seventh fills memory until it runs short, so you can watch Busy apps fill, the Touch Bar light up, the heat and memory alerts arrive and the memory line idle the seventh, and try Cap and Idle on them. Caffeinate, both alerts, Shrink images, Keep history and the Touch Bar stay on for the test and return to where they were after. Switched back on within a minute, the same run carries on.
- **Shrink images:** each screenshot on the clipboard shrinks to an image size you choose, 800 to 2,000 px on its long side, so it pastes light into chats and docs. Smaller crops pass as they are.
- **Clipboard history:** the last ten items, text and images, held in memory, the item on the clipboard now first. Picking an older item marks it with a dot, and a new copy clears the dot. Text copied on an iPhone, iPad or another Mac joins it; their images stay on that device until you paste them.

  <img src="screenshots/clipboard.gif" alt="Clipboard history opening from Culpmit's menu on a MacBook Pro: four screenshots and three texts, an older item marked">

- **Local models first:** while a llama.cpp, Ollama or OpenCode process works, every other busy app is held back, so the model gets the Mac's whole heat budget. The model, shells, terminal apps and Culpmit run free, and VS Code keeps one core for its terminal and chats. Two minutes after the model goes quiet, every app returns to where it stood.
- **Sleep:** Caffeinate on demand, letting go on battery below 20%. Wi-Fi and Bluetooth off while the Mac sleeps. On a laptop, back to sleep when the lid opens and the Mac stays idle. A list of the apps keeping the Mac awake.
- **Dev tools:** every local server listening on the Mac, one click to open; the cap on a `next dev` run through `cpulimit`; a switch for the [Talk to Figma](https://github.com/grab/cursor-talk-to-figma-mcp) socket on port 3055, which needs [bun](https://bun.sh).
- **Touch Bar:** the readout with memory last, the switches, the clipboard, and one row of apps: capped and idled apps lit, busy uncapped apps dim, each group a swipe away. A tap does the item's action: a switch flips, a clip copies, an app is capped or freed. A hold opens its details: the readout with units, a switch by name with On and Off, a clip's first line or a larger image, an app's use beside its CPU cap and memory line; VoiceOver reaches them as each item's Details action. ⌃⌥⌘C opens the strip from anywhere. The Touch Bar row shows on Macs with a Touch Bar.

  <img src="screenshots/touch-bar.gif" alt="Culpmit's Touch Bar strip on a MacBook Pro keyboard: the readout in colour, Claude's usage limits, switches, clips and apps, and an app's hold screen with its CPU cap and memory line">

- **Claude limits:** one switch installs [Uselim](https://github.com/booban1/uselim) in the background: Culpmit downloads its latest release, checks its checksum and its signing certificate, puts it in Applications and sets it up, the line under the switch naming each step. Claude's usage limits then join the Touch Bar after Culpmit's values, orange from 60% and red from 80%. Switched off, the figures leave the strip and Uselim stays installed. More in [How to use Uselim](https://simonbooban.com/resources/how-to-use-uselim).


## Requirements

- An Intel Mac with macOS 13 Ventura or later. Apple silicon support comes in a later version.
- The Touch Bar strip appears on MacBook Pros with a Touch Bar.
- Updates swap the app in its folder, so an /Applications copy on a standard account updates through an administrator.

## Install

### Download

1. Download the latest `Culpmit-x.y.z.dmg` from [Releases](https://github.com/booban1/culpmit/releases/latest).
2. Open it and drag Culpmit onto Applications.
3. Open Culpmit. macOS asks once to confirm an app from outside the App Store: open System Settings › Privacy & Security and click **Open Anyway**.

### curl

```sh
curl -fsSL https://raw.githubusercontent.com/booban1/culpmit/main/install.sh | bash
```

### Homebrew

```sh
brew tap booban1/culpmit https://github.com/booban1/culpmit
brew install --cask culpmit
```

The first open asks for the same one-time confirmation as a download.

### npx

```sh
npx github:booban1/culpmit
```

## First run

Culpmit opens at login and comes back on its own after a crash, with Open at login in its menu to change both; macOS lists it under Login Items, Allow in the Background. Allow notifications when macOS asks, for heat alerts and updates. The first time Culpmit turns Bluetooth off for sleep, macOS asks for Bluetooth access.

## Privacy

- Clipboard history lives in memory and clears when Culpmit quits.
- Network: the update check to GitHub releases and, while Claude limits is on, Uselim's download from its own GitHub releases.
- Settings live in `~/Library/Preferences/com.simonbooban.culpmit.plist` and the log in `~/Library/Logs/Culpmit.log`.

## Removing Culpmit

Switch Open at login off in its menu, quit it, and move it from Applications to the Trash. Already in the Trash? Delete `~/Library/LaunchAgents/com.simonbooban.culpmit.plist` too. With Homebrew: `brew uninstall --cask culpmit`, which does both.

## Windows

<p align="center"><img src="screenshots/windows.png" width="382" alt="Culpmit's panel on Windows 10: CPU and memory as tiles, busy apps with a tortoise and a moon each, two capped apps with their sliders, Keep awake, Open at login, and the CPU and memory alert lines"></p>

Culpmit sits in the tray beside the clock as two dots, CPU above and memory below, each white, orange at its alert's line and red at 90%. A click opens the panel:

- **Busy apps:** apps using half a core or more, plus the three holding the most memory, each with its CPU share and memory, a tortoise to cap it and a moon to idle it, red while on. Cap sets a ceiling at half of what the app uses at that moment.
- **Capped apps:** every app you cap, with every process it starts, held to a share of the PC from 5% to 80% through a Windows job object, beside its memory line. A right click on an app removes it.
- **CPU and memory alerts:** past a line you set, held for a minute, a notification names the busiest or the heaviest app.
- **Keep awake:** idle sleep held off, letting go on battery below 20%.

### Install on Windows

1. Download the latest `Culpmit-x.y.z-windows.zip` from [Releases](https://github.com/booban1/culpmit/releases).
2. Open the zip and double-click `Culpmit.exe`: it sets itself up in `%LOCALAPPDATA%\Programs\Culpmit`, joins Settings › Apps, opens at login and starts in the tray.
3. Windows asks once about an app from a new publisher: click **More info**, then **Run anyway**.

New tray icons wait behind the arrow beside the clock; drag the two dots onto the taskbar to keep them in view. Culpmit needs Windows 10 or 11 and makes zero network calls; its settings and log live in `%LOCALAPPDATA%\Culpmit`. To remove it, use Settings › Apps › Culpmit › Uninstall, or Remove Culpmit… in its panel; every cap lifts on the way out.

## Linux

<p align="center"><img src="screenshots/linux.png" width="380" alt="Culpmit's panel on Linux Mint: CPU and memory as tiles, busy apps with a tortoise and a moon each, yes capped at 50% with its sliders, Keep awake, Open at login, and the alert lines"></p>

Culpmit sits in the panel's tray as two dots, CPU above and memory below. Where the kernel reports the CPU's temperature (coretemp or k10temp), the top dot follows it, and Heat alerts and a temperature tile join the panel; the rest matches Windows. Caps run in your own systemd session: each capped app gets a scope with a CPU quota, and any process outside your session's reach pauses in 100 ms slices to the same share.

### Install on Linux

Download the latest `Culpmit-x.y.z-linux-x64.tar.gz`, or the `arm64` one, from [Releases](https://github.com/booban1/culpmit/releases), then:

```sh
tar -xzf Culpmit-*-linux-x64.tar.gz
./culpmit
```

Culpmit sets itself up in `~/.local/bin`, joins the app menu, opens at login and starts in the tray. It needs a 64-bit machine with systemd and a panel that shows tray icons: Cinnamon on Linux Mint, KDE Plasma, or Ubuntu's GNOME. It makes zero network calls; its settings and log live in `~/.local/share/Culpmit`. To remove it, use Remove Culpmit… in its panel, or `culpmit --remove`.

## Licence

MIT, see [LICENSE](LICENSE). The chip in the app icon comes from [Tabler Icons](https://tabler.io/icons), also MIT; the Windows and Linux panels' icons come from Microsoft's [Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons), MIT.
