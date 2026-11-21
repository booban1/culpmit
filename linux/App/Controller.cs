using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Avalonia.Threading;

namespace Culpmit
{
    // Culpmit on Linux, the Windows tray's logic as it is: every two seconds a snapshot of the machine; the busy apps;
    // each capped app held to its level and each idled one to a tenth of a core; the alerts on their clocks; keep awake;
    // and the tray icon's two dots, the top one temperature (CPU load where the machine lacks a CPU sensor), the bottom
    // one memory. A click opens the panel. Linux reads its temperature with zero drivers, so it shows wherever the
    // kernel names a CPU sensor, with zero switch.
    internal sealed class Controller
    {
        private readonly TrayItem tray = new TrayItem();
        // Cinnamon's own tray, where its applet runs
        private readonly XAppIcon xapp = new XAppIcon();
        private bool onXApp;
        private Panel panel;
        private readonly Sampler sampler = new Sampler();
        private readonly Scopes scopes;
        private readonly BusyList busyList;
        private readonly DispatcherTimer tick = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        private bool enforcing, awakeHeld, awakeBusy, firstTick = true;
        private List<string> leftovers;

        public Snapshot Now = new Snapshot();
        public List<AppGroup> Groups = new List<AppGroup>();
        public List<AppGroup> Busy = new List<AppGroup>();
        // the panel's app rows: idled, busy, then the heaviest three
        public List<AppGroup> Rows = new List<AppGroup>();
        public List<CappedApp> Capped = Caps.Load();
        // apps idled by hand or for memory, by key; and when each capped app last woke from an idle for memory
        public readonly Dictionary<string, string> Idled = new Dictionary<string, string>();
        private readonly HashSet<string> idledForMemory = new HashSet<string>();
        private readonly Dictionary<string, DateTime> wokenAt = new Dictionary<string, DateTime>();
        public double? Temperature;

        private readonly AlertClock loadClock = new AlertClock(), hotLoad = new AlertClock();
        private readonly AlertClock memoryClock = new AlertClock(), hotMemory = new AlertClock();
        private readonly AlertClock heatClock = new AlertClock(), hotHeat = new AlertClock();

        public int Threads => sampler.Threads;
        public bool HasHeat => Temperature.HasValue;

        public Controller()
        {
            scopes = new Scopes(sampler.Threads);
            busyList = new BusyList(sampler.Threads);
            // caps a copy before this one left behind come off on the first tick, once the apps are known
            leftovers = (Store.Raw("heldJobs") as List<object>)?.OfType<string>().ToList() ?? new List<string>();
            Store.Set("heldJobs", null);
        }

        public void Start(bool openPanel)
        {
            panel = new Panel(this);
            tray.Clicked = (x, y) => Dispatcher.UIThread.Post(() => TogglePanel(x, y));
            xapp.Clicked = tray.Clicked;
            Sample();
            _ = StartTray();
            tick.Tick += (s, e) => Sample();
            tick.Start();
            Welcome();
            Log.Note("started " + Program.Version + " on " + sampler.Threads + " threads" + (HasHeat ? ", temperature " + Format.Degrees(Temperature.Value) : ", zero CPU sensor"));
            if (openPanel) Dispatcher.UIThread.Post(() => TogglePanel(0, 0));
        }

        // the installed copy's first start: a notice says where Culpmit sits
        private void Welcome()
        {
            if (Store.Bool("welcomed") || !Install.IsInstalledCopy) return;
            Store.Set("welcomed", true);
            Notify("Culpmit is in the tray", "Its two dots sit beside the clock: " + (HasHeat ? "temperature" : "CPU") + " above, memory below. Click them for the busy apps and the caps.");
        }

        // One tick

        private void Sample()
        {
            Now = sampler.Take();
            Temperature = Sensors.Temperature();
            Fans = Sensors.Fans();
            Groups = Apps.Group(Now.Processes).Where(g => g.Key != "file:culpmit" && g.Key != "product:culpmit").ToList();
            Busy = busyList.Update(Groups, 5);
            Rows = Apps.Listed(Groups, Busy, Idled.Keys.ToList());
            if (Desktop.Dropped)
            {
                Desktop.Dropped = false;
                _ = StartTray();
            }
            if (firstTick)
            {
                firstTick = false;
                if (leftovers.Count > 0)
                {
                    Log.Note("lifting " + leftovers.Count + " caps a copy before left");
                    _ = Scopes.LiftLeftovers(leftovers, Groups);
                }
                leftovers = null;
                return;
            }
            _ = Enforce();
            Alert();
            _ = KeepAwake();
            Draw();
            panel?.Redraw();
        }

        public AppGroup GroupOf(string key) => Groups.FirstOrDefault(g => g.Key == key);

        // an app's icon file, from the icon its desktop entry names
        public string IconFileOf(string exe) => AppIcons.FileOf(sampler.IconNameOf(exe));

        public List<double> Fans = new List<double>();

        // each capped app to its level, each idled app to a tenth of a core, the rest free; one round at a time
        private async Task Enforce()
        {
            if (enforcing) return;
            enforcing = true;
            try
            {
                var idleShare = Caps.IdleCores / sampler.Threads;
                var wanted = new Dictionary<string, double?>();
                foreach (var c in Capped) wanted[c.Id] = c.On ? c.Level : (double?)null;
                foreach (var key in Idled.Keys) wanted[key] = idleShare;
                foreach (var key in scopes.Held.ToList()) if (!wanted.ContainsKey(key)) wanted[key] = null;
                foreach (var pair in wanted)
                {
                    var group = GroupOf(pair.Key);
                    if (group == null || !group.Mine) continue;
                    await scopes.Hold(group, pair.Value);
                }
                var held = scopes.Held.ToList();
                Store.Set("heldJobs", held.Count > 0 ? held.Cast<object>().ToList() : null);
            }
            catch (Exception e)
            {
                Log.Note("enforce: " + e.Message);
            }
            finally
            {
                enforcing = false;
            }
        }

        // keep awake: held while its switch is on, let go on battery under 20%
        private async Task KeepAwake()
        {
            var want = Store.Bool("keepAwake") && !Sensors.OnBatteryLow;
            if (awakeBusy || want == awakeHeld) return;
            awakeBusy = true;
            try
            {
                if (want)
                {
                    awakeHeld = await Desktop.HoldAwake();
                    if (awakeHeld) Log.Note("keep awake on");
                }
                else
                {
                    await Desktop.LetGo();
                    awakeHeld = false;
                    Log.Note("keep awake off");
                }
            }
            finally
            {
                awakeBusy = false;
            }
        }

        // Alerts: the Mac's clocks; heat, CPU and memory past their lines for a minute, at most once in 15 minutes, red at 90%

        private void Alert()
        {
            var now = DateTime.UtcNow;
            var cpuOn = Store.Bool("cpuAlerts");
            var memoryOn = Store.Bool("memoryAlerts");
            var heatOn = Store.Bool("heatAlerts") && HasHeat;
            var load = Levels.Load(Now.Load, Levels.CpuLine);
            var memory = Levels.Memory(Now.MemoryUsed, Now.MemoryTotal, Levels.MemoryLine);
            var heat = Levels.Temperature(Temperature, Levels.HeatLine);
            if (hotHeat.Due(heatOn && heat == Level.Hot, now))
            {
                heatClock.Last = now;
                PostBusiest("CPU at " + Format.Degrees(Temperature.Value) + " for " + hotHeat.Held(now));
            }
            else if (heatClock.Due(heatOn && heat >= Level.Warm, now))
                PostBusiest("CPU at " + Format.Degrees(Temperature.Value) + " for " + heatClock.Held(now));
            if (hotLoad.Due(cpuOn && load == Level.Hot, now))
            {
                loadClock.Last = now;
                PostBusiest("CPU at " + Format.Percent(Now.Load) + " for " + hotLoad.Held(now));
            }
            else if (loadClock.Due(cpuOn && load >= Level.Warm, now))
                PostBusiest("CPU at " + Format.Percent(Now.Load) + " for " + loadClock.Held(now));
            var memoryTitle = "Memory at " + Format.Gigabytes(Now.MemoryUsed) + " of " + Format.WholeGigabytes(Now.MemoryTotal);
            if (hotMemory.Due(memoryOn && memory == Level.Hot, now))
            {
                memoryClock.Last = now;
                PostMemory(memoryTitle + " for " + hotMemory.Held(now));
            }
            else if (memoryClock.Due(memoryOn && memory >= Level.Warm, now))
                PostMemory(memoryTitle + " for " + memoryClock.Held(now));
            IdleForMemory(memory, now);
        }

        private void PostBusiest(string title)
        {
            var hog = Apps.Top(Groups, 1).FirstOrDefault();
            Notify(title, hog != null ? hog.Name + " is using " + Format.Cores(hog.Cpu, sampler.Threads) + ". Cap it or idle it in Culpmit's panel." : "The machine is working hard.");
        }

        private void PostMemory(string title)
        {
            var hog = Apps.Top(Groups, 1, true).FirstOrDefault();
            Notify(title, hog != null ? hog.Name + " is using " + Format.Gigabytes(hog.Memory) + "." : "Memory used is past its line.");
        }

        // a capped app past its memory line idles while memory runs short; one woken by hand stays awake 15 minutes
        private void IdleForMemory(Level memory, DateTime now)
        {
            foreach (var c in Capped.Where(c => c.On))
            {
                var g = GroupOf(c.Id);
                if (g == null) continue;
                var over = g.Memory > Caps.LineOf(c, Now.MemoryTotal) * Format.Gib;
                var resting = wokenAt.TryGetValue(c.Id, out var at) && (now - at).TotalMinutes < 15;
                if (memory >= Level.Warm && over && !resting && !Idled.ContainsKey(c.Id))
                {
                    Idled[c.Id] = g.Name;
                    idledForMemory.Add(c.Id);
                    Log.Note("idle " + g.Name + " for memory, " + Format.Gigabytes(g.Memory));
                    Notify(g.Name + " idled", "It passed its memory line of " + Format.WholeGigabytes(Caps.LineOf(c, Now.MemoryTotal) * Format.Gib) + " while memory ran short. Wake it in Culpmit's panel.");
                }
                else if (memory == Level.Normal && idledForMemory.Contains(c.Id))
                {
                    Idled.Remove(c.Id);
                    idledForMemory.Remove(c.Id);
                    Log.Note("wake " + g.Name + ", memory back under its line");
                }
            }
        }

        // Actions from the panel

        public void Cap(AppGroup g)
        {
            if (Capped.Any(c => c.Id == g.Key)) return;
            // the Mac's rule: half of what the app uses right now, in 5% steps
            var level = Caps.Half(g.Cpu);
            Capped.Add(new CappedApp { Id = g.Key, Name = g.Name, Exe = g.Exe, Level = level, On = true });
            Caps.Save(Capped);
            Log.Note("capped " + g.Name + " at " + Format.Percent(level * 100));
            Refresh();
        }

        public void SetCap(string id, double level, bool save)
        {
            var c = Capped.FirstOrDefault(a => a.Id == id);
            if (c == null) return;
            c.Level = Caps.Snap(level);
            if (save) Caps.Save(Capped);
            _ = Enforce();
        }

        public void SetCapOn(string id, bool on)
        {
            var c = Capped.FirstOrDefault(a => a.Id == id);
            if (c == null || c.On == on) return;
            c.On = on;
            Caps.Save(Capped);
            Refresh();
        }

        public void SetMemoryLine(string id, double gb, bool save)
        {
            var c = Capped.FirstOrDefault(a => a.Id == id);
            if (c == null) return;
            c.MemoryLine = Caps.SnapLine(gb, Now.MemoryTotal);
            if (save) Caps.Save(Capped);
        }

        public void Uncap(string id)
        {
            Capped.RemoveAll(c => c.Id == id);
            Caps.Save(Capped);
            Refresh();
        }

        public bool IsIdled(string key) => Idled.ContainsKey(key);

        public void ToggleIdle(AppGroup g)
        {
            if (Idled.Remove(g.Key))
            {
                if (idledForMemory.Remove(g.Key)) wokenAt[g.Key] = DateTime.UtcNow;
                Log.Note("wake " + g.Name);
            }
            else
            {
                Idled[g.Key] = g.Name;
                Log.Note("idle " + g.Name);
            }
            Refresh();
        }

        public void SetSwitch(string key, bool on)
        {
            if (Store.Bool(key) == on) return;
            Store.Set(key, on);
            Refresh();
        }

        public void SetLine(string key, double value) => Store.Set(key, value);

        public void SetOpenAtLogin(bool on)
        {
            if (!Install.IsInstalledCopy || Install.OpenAtLogin == on) return;
            Install.OpenAtLogin = on;
            panel.Redraw();
        }

        // an action's effect at once: the holds, the icon and the panel
        private void Refresh()
        {
            _ = Enforce();
            _ = KeepAwake();
            Draw();
            panel?.Redraw();
        }

        // The icon

        public Level TopLevel => HasHeat ? Levels.Temperature(Temperature, Levels.HeatLine) : Levels.Load(Now.Load, Levels.CpuLine);

        public Level MemoryLevel => Levels.Memory(Now.MemoryUsed, Now.MemoryTotal, Levels.MemoryLine);

        // one place in the tray: the XApp icon where Cinnamon's applet runs, the standard item everywhere else
        private async Task StartTray()
        {
            onXApp = await XAppIcon.IsHosted();
            if (onXApp) await xapp.Start();
            else await tray.Start();
            Dispatcher.UIThread.Post(Draw);
        }

        private void Draw()
        {
            var tip = Tooltip();
            if (onXApp) xapp.Update(Dots.Draw(48, TopLevel, MemoryLevel), TopLevel.ToString().ToLowerInvariant() + "-" + MemoryLevel.ToString().ToLowerInvariant(), "", "Culpmit\n" + tip);
            else tray.Update(Dots.Icons(TopLevel, MemoryLevel), "", "Culpmit", tip);
        }

        // "72 °C · CPU 84% · 13.1 of 16 GB", then the busiest app
        private string Tooltip()
        {
            var parts = new List<string>();
            if (HasHeat) parts.Add(Format.Degrees(Temperature.Value));
            parts.Add("CPU " + Format.Percent(Now.Load));
            parts.Add(Format.Gigabytes(Now.MemoryUsed).Replace(" GB", "") + " of " + Format.WholeGigabytes(Now.MemoryTotal));
            var text = string.Join(" · ", parts);
            var top = Busy.FirstOrDefault();
            if (top != null) text += "\n" + top.Name + ": " + Format.Cores(top.Cpu, sampler.Threads);
            return text;
        }

        public void Notify(string title, string body)
        {
            Log.Note("notice: " + title + (string.IsNullOrEmpty(body) ? "" : ", " + body));
            _ = Desktop.Notify(title, body ?? "");
        }

        // The panel

        public void TogglePanel(int x, int y)
        {
            if (panel.IsVisible)
            {
                panel.Hide();
                return;
            }
            panel.ShowNear(x, y);
        }

        // "culpmit --panel" while the app runs: the panel beside the tray's corner
        public void OpenPanel()
        {
            if (!panel.IsVisible) panel.ShowNear(int.MaxValue, int.MaxValue);
            else panel.Activate();
        }

        public async void Remove()
        {
            panel.Hide();
            tick.Stop();
            await scopes.FreeAll();
            Install.RemoveFromApp();
            Quit();
        }

        // Quit: every cap and idle lifts on the way out, their apps run free
        private bool quitting;

        public async void Quit()
        {
            if (quitting) return;
            quitting = true;
            tick.Stop();
            panel?.Hide();
            try
            {
                var free = scopes.FreeAll();
                await Task.WhenAny(free, Task.Delay(3000));
            }
            catch (Exception) { }
            Store.Set("heldJobs", null);
            await Desktop.LetGo();
            Log.Note("quit");
            Program.Leave();
        }

        // a crash still resumes every paused process
        public void ResumeAllNow() => scopes.ResumeAllNow();
    }
}
