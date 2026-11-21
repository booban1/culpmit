using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace Culpmit
{
    // One moment of the machine: its load as a share of all its threads, its memory, and every process
    internal sealed class Snapshot
    {
        public double Load;
        public double MemoryUsed, MemoryTotal;
        public List<ProcessRecord> Processes = new List<ProcessRecord>();
        public DateTime At;
    }

    // Reads the machine each tick from /proc: the load from /proc/stat or the processes' own times, memory used as MemTotal less MemAvailable, and
    // each process's CPU time (utime and stime) and private memory (RssAnon). A process's share is its CPU time since the
    // last tick over the wall time times the machine's threads, the scale Culpmit's caps use. Each program is named by
    // the desktop entry that starts it ("Brave Web Browser" for brave), else by its file.
    internal sealed class Sampler
    {
        public readonly int Threads = Math.Max(1, Environment.ProcessorCount);
        private const double Ticks = 100; // USER_HZ, 100 on every Linux build
        private readonly Dictionary<int, long> lastTimes = new Dictionary<int, long>();
        private readonly Dictionary<string, string> exes = new Dictionary<string, string>();
        private readonly Dictionary<string, string> desktopNames;
        private readonly Dictionary<string, string> desktopIcons = new Dictionary<string, string>(StringComparer.Ordinal);
        private readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
        private double lastWall = -1;
        private long lastIdle, lastTotal;
        private readonly string myUid;

        public Sampler()
        {
            myUid = Field("/proc/self/status", "Uid:")?.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
            desktopNames = DesktopNames(desktopIcons);
        }

        public Snapshot Take()
        {
            var snap = new Snapshot { At = DateTime.UtcNow };
            var wall = clock.Elapsed.TotalSeconds;
            var span = lastWall < 0 ? 0 : wall - lastWall;
            lastWall = wall;

            try
            {
                var cpu = File.ReadLines("/proc/stat").First().Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries).Skip(1)
                    .Select(v => long.Parse(v, CultureInfo.InvariantCulture)).ToArray();
                var idle = cpu[3] + (cpu.Length > 4 ? cpu[4] : 0);
                var total = cpu.Take(8).Sum();
                var dTotal = total - lastTotal;
                if (lastTotal != 0 && dTotal > 0) snap.Load = Math.Max(0, Math.Min(100, 100.0 * (dTotal - (idle - lastIdle)) / dTotal));
                lastIdle = idle;
                lastTotal = total;
            }
            catch (Exception) { }

            var totalKb = Kb(Field("/proc/meminfo", "MemTotal:"));
            var availableKb = Kb(Field("/proc/meminfo", "MemAvailable:"));
            snap.MemoryTotal = totalKb * 1024.0;
            snap.MemoryUsed = (totalKb - availableKb) * 1024.0;

            var seen = new HashSet<int>();
            double everyShare = 0;
            foreach (var dir in Directory.EnumerateDirectories("/proc"))
            {
                if (!int.TryParse(Path.GetFileName(dir), NumberStyles.None, CultureInfo.InvariantCulture, out var pid)) continue;
                string stat;
                try { stat = File.ReadAllText(dir + "/stat"); }
                catch (Exception) { continue; }
                // the name sits in parentheses and may hold spaces; the fields after the last ")" follow
                var open = stat.IndexOf('(');
                var close = stat.LastIndexOf(')');
                if (open < 0 || close < open) continue;
                var comm = stat.Substring(open + 1, close - open - 1);
                var f = stat.Substring(close + 2).Split(' ');
                if (f.Length < 20) continue;
                var ppid = int.Parse(f[1], CultureInfo.InvariantCulture);
                var time = long.Parse(f[11], CultureInfo.InvariantCulture) + long.Parse(f[12], CultureInfo.InvariantCulture);
                var start = f[19];
                seen.Add(pid);
                double share = 0;
                if (span > 0 && lastTimes.TryGetValue(pid, out var before) && time >= before)
                    share = 100.0 * (time - before) / Ticks / (span * Threads);
                lastTimes[pid] = time;
                everyShare += share;

                string status = null;
                try { status = File.ReadAllText(dir + "/status"); }
                catch (Exception) { }
                var uid = Line(status, "Uid:")?.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
                var exe = Exe(pid, start, comm);
                // kernel threads carry zero memory map and stay out
                if (Line(status, "VmSize:") == null) continue;
                var stem = Apps.Stem(exe);
                snap.Processes.Add(new ProcessRecord
                {
                    Pid = pid, ParentPid = ppid, Exe = exe,
                    Product = desktopNames.TryGetValue(stem, out var named) ? named : "",
                    Cpu = Math.Min(100, share), Memory = Kb(Line(status, "RssAnon:")) * 1024.0, Mine = uid == myUid,
                });
            }
            foreach (var gone in lastTimes.Keys.Where(k => !seen.Contains(k)).ToList()) lastTimes.Remove(gone);
            // the kernel's counters in /proc/stat come from timer ticks, which miss work a CPU quota cuts into slices (a
            // capped app at a full core read as 17% in a VM, top and vmstat alike); every process's own time is exact,
            // so the load is the larger of the two
            snap.Load = Math.Max(snap.Load, Math.Min(100, everyShare));
            return snap;
        }

        // a process's program, read once per process (its pid and start time); another account's stays its name
        private string Exe(int pid, string start, string comm)
        {
            var key = pid + ":" + start;
            if (exes.TryGetValue(key, out var known)) return known;
            var exe = comm;
            try
            {
                var target = new FileInfo("/proc/" + pid + "/exe").LinkTarget;
                if (!string.IsNullOrEmpty(target)) exe = target.Replace(" (deleted)", "");
            }
            catch (Exception) { }
            if (exes.Count > 4000) exes.Clear();
            exes[key] = exe;
            return exe;
        }

        // the icon a program's desktop entry names, by its program file
        public string IconNameOf(string exe) => desktopIcons.TryGetValue(Apps.Stem(exe ?? ""), out var icon) ? icon : null;

        // program file to the name its desktop entry gives it, from the system's entries and the person's own, with
        // each entry's icon beside it
        private static Dictionary<string, string> DesktopNames(Dictionary<string, string> icons)
        {
            var names = new Dictionary<string, string>(StringComparer.Ordinal);
            var home = Environment.GetEnvironmentVariable("HOME") ?? "";
            foreach (var folder in new[] { "/usr/share/applications", "/usr/local/share/applications", home + "/.local/share/applications", "/var/lib/flatpak/exports/share/applications" })
            {
                if (!Directory.Exists(folder)) continue;
                foreach (var file in Directory.EnumerateFiles(folder, "*.desktop"))
                {
                    try
                    {
                        string name = null, exec = null, icon = null;
                        foreach (var line in File.ReadLines(file))
                        {
                            if (line.StartsWith("[") && line != "[Desktop Entry]" && (name != null || exec != null)) break;
                            if (name == null && line.StartsWith("Name=")) name = line.Substring(5).Trim();
                            if (exec == null && line.StartsWith("Exec=")) exec = line.Substring(5).Trim();
                            if (icon == null && line.StartsWith("Icon=")) icon = line.Substring(5).Trim();
                        }
                        if (name == null || exec == null) continue;
                        var program = exec.Split(' ').FirstOrDefault(t => !t.Contains("=") && t != "env")?.Trim('"') ?? "";
                        var stem = Apps.Stem(program);
                        if (stem.Length > 0 && !names.ContainsKey(stem))
                        {
                            names[stem] = name;
                            if (!string.IsNullOrEmpty(icon)) icons[stem] = icon;
                        }
                    }
                    catch (Exception) { }
                }
            }
            return names;
        }

        private static string Field(string path, string key)
        {
            try { return Line(File.ReadAllText(path), key); }
            catch (Exception) { return null; }
        }

        private static string Line(string text, string key)
        {
            if (text == null) return null;
            foreach (var line in text.Split('\n'))
                if (line.StartsWith(key, StringComparison.Ordinal)) return line.Substring(key.Length).Trim();
            return null;
        }

        private static long Kb(string value)
        {
            var digits = (value ?? "").Split(' ').FirstOrDefault() ?? "";
            return long.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out var kb) ? kb : 0;
        }
    }
}
