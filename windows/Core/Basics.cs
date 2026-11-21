using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace Culpmit
{
    // Where Culpmit keeps its files, its log, its settings and the number formats, shared by the Windows and Linux
    // builds. Settings live in settings.json in the support folder: %LOCALAPPDATA%\Culpmit on Windows,
    // ~/.local/share/Culpmit on Linux (.NET's local data folder on each). CULPMIT_SUPPORT_DIR points a check elsewhere.

    public static class Paths
    {
        public static string Home
        {
            get
            {
                var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                return string.IsNullOrEmpty(profile) ? Environment.GetEnvironmentVariable("HOME") ?? "" : profile;
            }
        }

        public static string LocalData
        {
            get
            {
                var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                return string.IsNullOrEmpty(local) ? Path.Combine(Home, "AppData", "Local") : local;
            }
        }

        public static string SupportDir
        {
            get
            {
                var test = Environment.GetEnvironmentVariable("CULPMIT_SUPPORT_DIR");
                return string.IsNullOrEmpty(test) ? Path.Combine(LocalData, "Culpmit") : test;
            }
        }

        public static string SettingsPath => Path.Combine(SupportDir, "settings.json");
        public static string LogPath => Path.Combine(SupportDir, "Culpmit.log");

        public static bool Same(string a, string b) =>
            string.Equals(Path.GetFullPath(a).TrimEnd('\\', '/'), Path.GetFullPath(b).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);

        // a file's text as UTF-8, null when it is absent or unreadable
        public static string Read(string path)
        {
            try { return File.Exists(path) ? File.ReadAllText(path, Encoding.UTF8) : null; }
            catch (Exception) { return null; }
        }

        // written beside its place first, then moved over it, so a reader meets the old file or the new one
        public static bool WriteAtomic(string path, string text)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                var temp = path + ".tmp-" + Guid.NewGuid().ToString("N").Substring(0, 8);
                File.WriteAllText(temp, text, new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(temp, path, null, true);
                else File.Move(temp, path);
                return true;
            }
            catch (Exception)
            {
                return false;
            }
        }
    }

    // Lines for Culpmit.log: the start, every cap, idle and switch, and failures
    public static class Log
    {
        private static readonly object gate = new object();
        public static bool ToConsole;

        public static void Note(string text)
        {
            var line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + " " + text + "\n";
            lock (gate)
            {
                if (ToConsole)
                {
                    Console.Write(line);
                    return;
                }
                try
                {
                    Directory.CreateDirectory(Paths.SupportDir);
                    var info = new FileInfo(Paths.LogPath);
                    // the log keeps its last megabyte or so: past 2 MB it starts over from its newer half
                    if (info.Exists && info.Length > 2_000_000)
                    {
                        var kept = File.ReadAllText(Paths.LogPath, Encoding.UTF8);
                        File.WriteAllText(Paths.LogPath, kept.Substring(kept.Length / 2), new UTF8Encoding(false));
                    }
                    File.AppendAllText(Paths.LogPath, line, new UTF8Encoding(false));
                }
                catch (Exception) { }
            }
        }
    }

    // Settings with the Mac's defaults: each switch and line as the Mac app registers them, read fresh from the file
    public static class Store
    {
        private static readonly object gate = new object();
        private static JObject cache;

        public static readonly Dictionary<string, object> Defaults = new Dictionary<string, object>
        {
            ["heatAlerts"] = true, ["heatLine"] = 85.0,
            ["cpuAlerts"] = true, ["cpuLine"] = 80.0,
            ["memoryAlerts"] = true, ["memoryAlertLine"] = 0.9,
            ["temperature"] = false, ["keepAwake"] = false,
        };

        private static JObject Load()
        {
            if (cache == null) cache = Json.ParseObject(Paths.Read(Paths.SettingsPath)) ?? new JObject();
            return cache;
        }

        public static bool Bool(string key)
        {
            lock (gate)
            {
                var v = Load().Bool(key);
                if (v.HasValue) return v.Value;
                return Defaults.TryGetValue(key, out var d) && d is bool b && b;
            }
        }

        public static bool? BoolOrNull(string key)
        {
            lock (gate) return Load().Bool(key);
        }

        public static double Num(string key)
        {
            lock (gate)
            {
                var v = Load().Num(key);
                if (v.HasValue) return v.Value;
                return Defaults.TryGetValue(key, out var d) && d is double n ? n : 0;
            }
        }

        public static object Raw(string key)
        {
            lock (gate) return Load()[key];
        }

        public static void Set(string key, object value)
        {
            lock (gate)
            {
                var all = Load();
                if (value == null) all.Remove(key);
                else all[key] = value;
                Paths.WriteAtomic(Paths.SettingsPath, Json.Write(all, true));
            }
        }

        // a check starts each run from an empty store
        public static void Forget()
        {
            lock (gate) cache = null;
        }
    }

    // Number formats shared by the tray, the panel and the notices
    public static class Format
    {
        public const double Gib = 1_073_741_824.0;

        public static string Percent(double v) => ((int)Math.Round(v)).ToString(CultureInfo.InvariantCulture) + "%";

        // bytes in GB as Task Manager and Activity Monitor count them (1,024³), one decimal
        public static string Gigabytes(double bytes) =>
            Math.Max(0.1, bytes / Gib).ToString("0.0", CultureInfo.InvariantCulture) + " GB";

        public static string WholeGigabytes(double bytes) => ((int)Math.Round(bytes / Gib)).ToString(CultureInfo.InvariantCulture) + " GB";

        public static string Degrees(double c) => ((int)Math.Round(c)).ToString(CultureInfo.InvariantCulture) + " °C";

        // an app's load as whole cores, one at least: "1 core", "6 cores"
        public static string Cores(double sharePercent, int threads)
        {
            var cores = Math.Max(1, (int)Math.Round(sharePercent * threads / 100));
            return cores == 1 ? "1 core" : cores.ToString(CultureInfo.InvariantCulture) + " cores";
        }

        // a version's parts compared as numbers: "1.10.0" is newer than "1.9.3"
        public static bool IsNewer(string candidate, string current)
        {
            var a = Parts(candidate);
            var b = Parts(current);
            for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
            {
                var x = i < a.Length ? a[i] : 0;
                var y = i < b.Length ? b[i] : 0;
                if (x != y) return x > y;
            }
            return false;
        }

        private static int[] Parts(string v)
        {
            var bits = (v ?? "").TrimStart('v', 'V').Split('.');
            var parts = new int[bits.Length];
            for (var i = 0; i < bits.Length; i++) int.TryParse(bits[i], NumberStyles.Integer, CultureInfo.InvariantCulture, out parts[i]);
            return parts;
        }
    }
}
