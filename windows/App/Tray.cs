using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Culpmit
{
    // Culpmit on Windows, the Mac's Menu: every two seconds a snapshot of the machine; the busy apps; each capped app held
    // to its level and each idled one to a tenth of a core; the alerts on their clocks; keep awake; and the tray icon's two
    // dots, the top one temperature (CPU load while Temperature is off), the bottom one memory. A click opens the panel.
    internal sealed class Tray : ApplicationContext
    {
        private readonly NotifyIcon icon = new NotifyIcon();
        private readonly Control ui = new Control();
        private readonly Panel panel;
        private readonly Sampler sampler = new Sampler();
        private readonly Jobs jobs = new Jobs();
        private readonly Awake awake = new Awake();
        private readonly System.Windows.Forms.Timer tick = new System.Windows.Forms.Timer { Interval = 2000 };
        private readonly BusyList busyList;
        private IntPtr iconHandle = IntPtr.Zero;
        private string iconLook = "";
        private EventWaitHandle quit;
        private RegisteredWaitHandle quitWait;
        private EventWaitHandle panelAsk;
        private RegisteredWaitHandle panelWait;

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

        public int Threads => sampler.Threads;

        public Tray()
        {
            var forced = ui.Handle;
            busyList = new BusyList(sampler.Threads);
            panel = new Panel(this);

            // caps a copy before this one left behind come off first
            var leftovers = (Store.Raw("heldJobs") as List<object>)?.OfType<string>().ToList() ?? new List<string>();
            if (leftovers.Count > 0) Jobs.LiftLeftovers(leftovers);
            Store.Set("heldJobs", null);

            icon.Text = "Culpmit";
            icon.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) TogglePanel(); };
            icon.BalloonTipClicked += (s, e) => ShowPanel();
            var menu = new ContextMenuStrip();
            menu.Items.Add("Open Culpmit", null, (s, e) => ShowPanel());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quit", null, (s, e) => ExitThread());
            icon.ContextMenuStrip = menu;

            Sample();
            Sample();
            icon.Visible = true;
            tick.Tick += (s, e) => Sample();
            tick.Start();

            SystemEvents.UserPreferenceChanged += ThemeChanged;
            quit = new EventWaitHandle(false, EventResetMode.AutoReset, Install.QuitName);
            quitWait = ThreadPool.RegisterWaitForSingleObject(quit, (o, t) => ui.BeginInvoke((Action)ExitThread), null, -1, true);
            // "Culpmit.exe --panel" opens the panel beside the tray's corner
            panelAsk = new EventWaitHandle(false, EventResetMode.AutoReset, Install.PanelName);
            panelWait = ThreadPool.RegisterWaitForSingleObject(panelAsk, (o, t) => ui.BeginInvoke((Action)(() =>
            {
                var area = Screen.PrimaryScreen.WorkingArea;
                panel.ShowNear(new Point(area.Right - 1, area.Bottom - 1));
            })), null, -1, false);
            Welcome();
            Log.Note("started " + Program.Version + " on " + sampler.Threads + " threads");
        }

        private void ThemeChanged(object sender, UserPreferenceChangedEventArgs e)
        {
            iconLook = "";
            Draw();
            panel.Redraw();
        }

        // the installed copy's first start: a notice says where Culpmit sits
        private void Welcome()
        {
            if (Store.Bool("welcomed") || !Install.IsInstalledCopy) return;
            Store.Set("welcomed", true);
            Notify("Culpmit is in the tray", "Its two dots sit beside the clock: CPU above, memory below. Click them for the busy apps and the caps.");
        }

        // One tick

        private void Sample()
        {
            Now = sampler.Take();
            Groups = Apps.Group(Now.Processes).Where(g => g.Key != "file:culpmit" && g.Key != "file:system" && g.Key != "file:registry"
                && g.Key != "file:memory compression").ToList();
            Busy = busyList.Update(Groups, 5);
            Rows = Apps.Listed(Groups, Busy, Idled.Keys.ToList());
            Enforce();
            Alert();
            awake.Apply(Store.Bool("keepAwake"));
            Draw();
            if (panel.Visible) panel.Redraw();
        }

        public AppGroup GroupOf(string key) => Groups.FirstOrDefault(g => g.Key == key);

        // each capped app to its level, each idled app to a tenth of a core, the rest free
        private void Enforce()
        {
            var idleShare = Caps.IdleCores / sampler.Threads;
            var wanted = new Dictionary<string, double?>();
            foreach (var c in Capped) wanted[c.Id] = c.On ? c.Level : (double?)null;
            foreach (var key in Idled.Keys) wanted[key] = idleShare;
            foreach (var key in jobs.Held.ToList()) if (!wanted.ContainsKey(key)) wanted[key] = null;
            foreach (var pair in wanted)
            {
                var group = GroupOf(pair.Key);
                if (group == null) continue;
                jobs.Hold(group, pair.Value);
            }
            var held = jobs.Held.ToList();
            Store.Set("heldJobs", held.Count > 0 ? held.Cast<object>().ToList() : null);
        }

        // Alerts: the Mac's clocks; CPU and memory past their lines for a minute, at most once in 15 minutes, red at 90%

        private void Alert()
        {
            var now = DateTime.UtcNow;
            var cpuOn = Store.Bool("cpuAlerts");
            var memoryOn = Store.Bool("memoryAlerts");
            var load = Levels.Load(Now.Load, Levels.CpuLine);
            var memory = Levels.Memory(Now.MemoryUsed, Now.MemoryTotal, Levels.MemoryLine);
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
            Notify(title, hog != null ? hog.Name + " is using " + Format.Cores(hog.Cpu, sampler.Threads) + ". Cap it or idle it in Culpmit's panel." : "The PC is working hard.");
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
            Sample();
        }

        public void SetCap(string id, double level, bool save)
        {
            var c = Capped.FirstOrDefault(a => a.Id == id);
            if (c == null) return;
            c.Level = Caps.Snap(level);
            if (save) Caps.Save(Capped);
            Enforce();
        }

        public void SetCapOn(string id, bool on)
        {
            var c = Capped.FirstOrDefault(a => a.Id == id);
            if (c == null) return;
            c.On = on;
            Caps.Save(Capped);
            Sample();
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
            Sample();
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
            Sample();
        }

        public void SetSwitch(string key, bool on)
        {
            Store.Set(key, on);
            Sample();
        }

        public void SetLine(string key, double value) => Store.Set(key, value);

        public void SetOpenAtLogin(bool on)
        {
            if (!Install.IsInstalledCopy) return;
            Install.OpenAtLogin = on;
            panel.Redraw();
        }

        // The icon

        public Level TopLevel => Temperature.HasValue && Store.Bool("temperature")
            ? Levels.Temperature(Temperature, Levels.HeatLine)
            : Levels.Load(Now.Load, Levels.CpuLine);

        public Level MemoryLevel => Levels.Memory(Now.MemoryUsed, Now.MemoryTotal, Levels.MemoryLine);

        private void Draw()
        {
            var light = Palette.TaskbarLight;
            var look = TopLevel + "/" + MemoryLevel + "/" + light;
            if (look != iconLook)
            {
                iconLook = look;
                using (var bmp = Dots.Draw(SystemInformation.SmallIconSize.Width, TopLevel, MemoryLevel, true, light))
                {
                    var handle = bmp.GetHicon();
                    icon.Icon = Icon.FromHandle(handle);
                    if (iconHandle != IntPtr.Zero) Native.DestroyIcon(iconHandle);
                    iconHandle = handle;
                }
            }
            icon.Text = Tooltip();
        }

        // "72 °C · CPU 84% · 13.1 of 16 GB", Windows keeping 63 characters
        private string Tooltip()
        {
            var parts = new List<string>();
            if (Temperature.HasValue && Store.Bool("temperature")) parts.Add(Format.Degrees(Temperature.Value));
            parts.Add("CPU " + Format.Percent(Now.Load));
            parts.Add(Format.Gigabytes(Now.MemoryUsed).Replace(" GB", "") + " of " + Format.WholeGigabytes(Now.MemoryTotal));
            var text = string.Join(" · ", parts);
            var top = Busy.FirstOrDefault();
            if (top != null) text += "\n" + top.Name + ": " + Format.Cores(top.Cpu, sampler.Threads);
            return text.Length > 63 ? text.Substring(0, 62) + "…" : text;
        }

        public void Notify(string title, string body)
        {
            Log.Note("notice: " + title + (string.IsNullOrEmpty(body) ? "" : ", " + body));
            icon.ShowBalloonTip(8000, title, string.IsNullOrEmpty(body) ? title : body, ToolTipIcon.None);
        }

        // The panel

        private void TogglePanel()
        {
            if (panel.Visible || panel.JustHidden) panel.Hide();
            else ShowPanel();
        }

        private void ShowPanel() => panel.ShowNear(Cursor.Position);

        // Quit: the panel's row and the tray menu's; every cap lifts on the way out
        public void Quit() => ExitThread();

        public void ConfirmRemove()
        {
            panel.Hide();
            var answer = MessageBox.Show(
                "Every cap lifts, Open at login ends, Culpmit leaves Settings › Apps, and Culpmit.exe is deleted once Culpmit quits.",
                "Remove Culpmit?", MessageBoxButtons.OKCancel, MessageBoxIcon.None, MessageBoxDefaultButton.Button2);
            if (answer != DialogResult.OK) return;
            jobs.FreeAll();
            Install.RemoveFromApp();
            ExitThread();
        }

        protected override void ExitThreadCore()
        {
            SystemEvents.UserPreferenceChanged -= ThemeChanged;
            tick.Stop();
            // every cap and idle lifts as Culpmit leaves: their apps run free
            jobs.FreeAll();
            Store.Set("heldJobs", null);
            awake.Release();
            quitWait?.Unregister(null);
            panelWait?.Unregister(null);
            panelAsk?.Dispose();
            quit?.Dispose();
            icon.Visible = false;
            icon.Dispose();
            if (iconHandle != IntPtr.Zero) Native.DestroyIcon(iconHandle);
            panel.Dispose();
            Log.Note("quit");
            base.ExitThreadCore();
        }
    }
}
