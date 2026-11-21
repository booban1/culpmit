using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace Culpmit
{
    // The machine's sensors, read from the kernel's own files with zero drivers and zero rights beyond the person's: the
    // CPU's temperature from hwmon (Intel's coretemp "Package id 0", AMD's k10temp "Tctl" or "Tdie"), the fans' speeds,
    // and the battery. A machine without a CPU sensor (a virtual one, say) reads null, and the tray's top dot then shows
    // the CPU load, as on Windows with Temperature off.
    internal static class Sensors
    {
        private static readonly string[] cpuChips = { "coretemp", "k10temp", "zenpower", "cpu_thermal", "soc_thermal" };

        public static double? Temperature()
        {
            try
            {
                foreach (var dir in Directory.EnumerateDirectories("/sys/class/hwmon"))
                {
                    var name = Read(dir + "/name");
                    if (name == null || !cpuChips.Contains(name)) continue;
                    double? best = null;
                    foreach (var input in Directory.EnumerateFiles(dir, "temp*_input"))
                    {
                        var label = Read(input.Replace("_input", "_label")) ?? "";
                        var value = Number(input);
                        if (value == null) continue;
                        var c = value.Value / 1000;
                        // the package's or the die's own reading leads; else the hottest core
                        if (label.StartsWith("Package") || label == "Tctl" || label == "Tdie") return c;
                        best = Math.Max(best ?? c, c);
                    }
                    if (best.HasValue) return best;
                }
            }
            catch (Exception) { }
            return null;
        }

        public static List<double> Fans()
        {
            var fans = new List<double>();
            try
            {
                foreach (var dir in Directory.EnumerateDirectories("/sys/class/hwmon"))
                    foreach (var input in Directory.EnumerateFiles(dir, "fan*_input"))
                        if (Number(input) is double rpm && rpm > 0) fans.Add(rpm);
            }
            catch (Exception) { }
            return fans;
        }

        // on battery and under 20%: keep awake lets go, as on the Mac and Windows
        public static bool OnBatteryLow
        {
            get
            {
                try
                {
                    foreach (var dir in Directory.EnumerateDirectories("/sys/class/power_supply"))
                    {
                        if (Read(dir + "/type") != "Battery") continue;
                        var discharging = Read(dir + "/status") == "Discharging";
                        if (discharging && Number(dir + "/capacity") is double pct && pct < 20) return true;
                    }
                }
                catch (Exception) { }
                return false;
            }
        }

        private static string Read(string path)
        {
            try { return File.Exists(path) ? File.ReadAllText(path).Trim() : null; }
            catch (Exception) { return null; }
        }

        private static double? Number(string path) =>
            double.TryParse(Read(path), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : (double?)null;
    }

    // The tray icon, the Windows build's: two dots stacked, the top one temperature (CPU load where the machine lacks a
    // CPU sensor), the bottom one memory, each in its level's colour on a dark panel's ink; pixels in ARGB, network order
    internal static class Dots
    {
        public static (byte R, byte G, byte B) Colour(Level level) =>
            level == Level.Hot ? ((byte)0xFF, (byte)0x6B, (byte)0x7A)
            : level == Level.Warm ? ((byte)0xFC, (byte)0x8B, (byte)0x3E)
            : ((byte)0xF2, (byte)0xF2, (byte)0xF2);

        public static List<TrayItem.Pixmap> Icons(Level top, Level bottom)
        {
            var list = new List<TrayItem.Pixmap>();
            foreach (var size in new[] { 22, 32, 48 }) list.Add(Draw(size, top, bottom));
            return list;
        }

        public static TrayItem.Pixmap Draw(int size, Level top, Level bottom)
        {
            var argb = new byte[size * size * 4];
            var r = size * 0.22;
            var cx = size / 2.0;
            var topY = size * 0.26;
            var bottomY = size * 0.74;
            var a = Colour(top);
            var b = Colour(bottom);
            for (var y = 0; y < size; y++)
                for (var x = 0; x < size; x++)
                {
                    var px = x + 0.5;
                    var py = y + 0.5;
                    var dTop = Math.Sqrt((px - cx) * (px - cx) + (py - topY) * (py - topY));
                    var dBottom = Math.Sqrt((px - cx) * (px - cx) + (py - bottomY) * (py - bottomY));
                    var alphaTop = Clamp(r + 0.5 - dTop);
                    var alphaBottom = Clamp(r + 0.5 - dBottom);
                    var alpha = Math.Max(alphaTop, alphaBottom);
                    var c = alphaTop >= alphaBottom ? a : b;
                    var i = (y * size + x) * 4;
                    argb[i] = (byte)Math.Round(alpha * 255);
                    argb[i + 1] = c.R;
                    argb[i + 2] = c.G;
                    argb[i + 3] = c.B;
                }
            return new TrayItem.Pixmap { Width = size, Height = size, Argb = argb };
        }

        private static double Clamp(double v) => v < 0 ? 0 : v > 1 ? 1 : v;
    }
}
