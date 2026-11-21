using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace Culpmit
{
    // One process at one moment: its load as a share of the whole machine (all its threads count, as Task Manager's
    // CPU column counts them), its private memory, and what names it.
    public sealed class ProcessRecord
    {
        public int Pid, ParentPid;
        public string Exe = "";      // the program's full path where readable, else its file name
        public string Product = "";  // the name its maker gave it (Windows: the file's product name), else empty
        public double Cpu;           // percent of the whole machine
        public double Memory;        // bytes
        public bool Mine = true;     // run by this account, so Culpmit may cap or idle it
    }

    // An app: every process of one program counted together, as Task Manager's Apps group them
    public sealed class AppGroup
    {
        public string Key = "", Name = "", Exe = "";
        public List<int> Pids = new List<int>();
        public double Cpu, Memory;
        public bool Mine;
        public int MainPid => Pids.Count > 0 ? Pids[0] : 0;
    }

    public static class Apps
    {
        // names a maker gives the system's own parts; those group by their file instead
        private static readonly string[] systemProducts = { "Microsoft® Windows® Operating System", "Microsoft Windows Operating System" };

        // the group an app's processes share: its product name where its maker set one, else its program file's name
        public static string KeyOf(ProcessRecord p)
        {
            var product = (p.Product ?? "").Trim();
            if (product.Length > 0 && !systemProducts.Contains(product)) return "product:" + product.ToLowerInvariant();
            var file = Stem(p.Exe);
            return "file:" + (file.Length > 0 ? file.ToLowerInvariant() : "pid" + p.Pid.ToString(CultureInfo.InvariantCulture));
        }

        public static string NameOf(ProcessRecord p)
        {
            var product = (p.Product ?? "").Trim();
            if (product.Length > 0 && !systemProducts.Contains(product)) return product;
            var file = Stem(p.Exe);
            return file.Length > 0 ? file : "Process " + p.Pid.ToString(CultureInfo.InvariantCulture);
        }

        // a program's file name without its extension, read from a Windows or a Linux path on either system
        public static string Stem(string path)
        {
            var name = path ?? "";
            var cut = Math.Max(name.LastIndexOf('\\'), name.LastIndexOf('/'));
            if (cut >= 0) name = name.Substring(cut + 1);
            var dot = name.LastIndexOf('.');
            return dot > 0 ? name.Substring(0, dot) : name;
        }

        // every process under its app; an app's first pid is its oldest-parented one, the one its window belongs to
        public static List<AppGroup> Group(IEnumerable<ProcessRecord> processes)
        {
            var groups = new Dictionary<string, AppGroup>();
            var byPid = processes.ToDictionary(p => p.Pid);
            foreach (var p in byPid.Values)
            {
                var key = KeyOf(p);
                if (!groups.TryGetValue(key, out var g))
                {
                    g = new AppGroup { Key = key, Name = NameOf(p), Exe = p.Exe ?? "" };
                    groups[key] = g;
                }
                g.Pids.Add(p.Pid);
                g.Cpu += p.Cpu;
                g.Memory += p.Memory;
                g.Mine |= p.Mine;
            }
            // the root first: the process whose parent sits outside the app
            foreach (var g in groups.Values)
            {
                var members = new HashSet<int>(g.Pids);
                var root = g.Pids.FirstOrDefault(pid => !byPid.TryGetValue(pid, out var p) || !members.Contains(p.ParentPid));
                if (root != 0)
                {
                    g.Pids.Remove(root);
                    g.Pids.Insert(0, root);
                    if (byPid.TryGetValue(root, out var r) && !string.IsNullOrEmpty(r.Exe)) g.Exe = r.Exe;
                }
            }
            return groups.Values.ToList();
        }

        // the apps using the most CPU, or with byMemory the most memory
        public static List<AppGroup> Top(IEnumerable<AppGroup> groups, int count, bool byMemory = false) =>
            groups.OrderByDescending(g => byMemory ? g.Memory : g.Cpu).Take(count).ToList();

        // The panel's app rows, the Mac menu's list: the idled apps, then the busy ones, then the three of the person's
        // own apps holding the most memory, each app once, six rows at most
        public static List<AppGroup> Listed(IList<AppGroup> groups, IEnumerable<AppGroup> busy, ICollection<string> idled, int memoryCount = 3, int most = 6)
        {
            var rows = new List<AppGroup>();
            void Add(AppGroup g) { if (g != null && rows.Count < most && rows.All(r => r.Key != g.Key)) rows.Add(g); }
            foreach (var key in idled) Add(groups.FirstOrDefault(g => g.Key == key));
            foreach (var g in busy) Add(g);
            foreach (var g in Top(groups.Where(g => g.Mine && rows.All(r => r.Key != g.Key)), memoryCount, true)) Add(g);
            return rows;
        }
    }

    // Busy: an app joins at half of one core and leaves under 30% of one, so an app near the line holds still; shares
    // here are of the whole machine, hence the division by its threads
    public sealed class BusyList
    {
        private readonly int threads;
        private HashSet<string> listed = new HashSet<string>();

        public BusyList(int threads) { this.threads = Math.Max(1, threads); }

        public double Join => 50.0 / threads;
        public double Leave => 30.0 / threads;

        public List<AppGroup> Update(IEnumerable<AppGroup> groups, int count)
        {
            var busy = groups.Where(g => g.Cpu >= Join || (listed.Contains(g.Key) && g.Cpu >= Leave))
                .OrderByDescending(g => g.Cpu).ToList();
            listed = new HashSet<string>(busy.Select(g => g.Key));
            return busy.Take(count).ToList();
        }
    }

    // A capped app, kept in settings so any app joins through Add with zero code change: its group, its level as a share
    // of the whole machine (5% to 80% in steps of 5%), its switch, and its memory line in GB (past it, while memory runs
    // short, the app idles)
    public sealed class CappedApp
    {
        public string Id = "", Name = "", Exe = "";
        public double Level = 0.5;
        public bool On = true;
        public double? MemoryLine;
    }

    public static class Caps
    {
        public const double Low = 0.05, High = 0.8, Step = 0.05;
        // an idled app holds a tenth of one core, the Mac's idle
        public const double IdleCores = 0.1;

        public static double Snap(double level) => Levels.Snap(level, Low, High, Step);

        // Cap, the Mac's rule: the ceiling at half of what the app uses at that moment, rounded down to 5% steps, 5% at
        // the least; an app at 95% of the machine gets 45%
        public static double Half(double cpuPercent)
        {
            var half = Math.Floor(cpuPercent / 2 / (Step * 100) + 1e-9) * Step;
            return Math.Max(Low, Math.Min(High, half));
        }

        // the memory line's range in whole GB: a sixteenth of the machine's memory (1 GB at least) to three quarters of it
        public static double[] LineRange(double totalBytes)
        {
            var gb = totalBytes / Format.Gib;
            return new[] { Math.Max(1, Math.Round(gb / 16)), Math.Floor(gb * 0.75) };
        }

        public static double SnapLine(double gb, double totalBytes)
        {
            var r = LineRange(totalBytes);
            return Math.Min(r[1], Math.Max(r[0], Math.Round(gb)));
        }

        public static double LineOf(CappedApp app, double totalBytes) =>
            app.MemoryLine.HasValue ? SnapLine(app.MemoryLine.Value, totalBytes) : SnapLine(totalBytes / Format.Gib * 0.5, totalBytes);

        public static List<CappedApp> Load()
        {
            var list = new List<CappedApp>();
            foreach (var o in (Store.Raw("cappedApps") as List<object>)?.OfType<JObject>() ?? Enumerable.Empty<JObject>())
            {
                var id = o.Str("id");
                if (string.IsNullOrEmpty(id) || id == "file:culpmit") continue;
                list.Add(new CappedApp
                {
                    Id = id, Name = o.Str("name") ?? id, Exe = o.Str("exe") ?? "",
                    Level = Snap(o.Num("level") ?? 0.5), On = o.Bool("on") ?? true, MemoryLine = o.Num("memoryLine"),
                });
            }
            return list;
        }

        public static void Save(IEnumerable<CappedApp> apps)
        {
            var list = new List<object>();
            foreach (var a in apps)
            {
                var o = new JObject { ["id"] = a.Id, ["name"] = a.Name, ["exe"] = a.Exe, ["level"] = a.Level, ["on"] = a.On };
                if (a.MemoryLine.HasValue) o["memoryLine"] = a.MemoryLine.Value;
                list.Add(o);
            }
            Store.Set("cappedApps", list);
        }
    }
}
