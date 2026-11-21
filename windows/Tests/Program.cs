using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace Culpmit.Tests
{
    // The core's checks: each line names one rule of the Mac app that the Windows and Linux builds keep
    internal static class Program
    {
        private static int passed, failed;

        private static void Check(string name, bool ok)
        {
            if (ok) passed++;
            else
            {
                failed++;
                Console.WriteLine("FAILED: " + name);
            }
        }

        private static int Main()
        {
            var dir = Path.Combine(Path.GetTempPath(), "culpmit-checks-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            Environment.SetEnvironmentVariable("CULPMIT_SUPPORT_DIR", dir);
            Store.Forget();

            // levels: orange from the line, red from 90%
            Check("Cap at half of 95% is 45%", Math.Abs(Caps.Half(95) - 0.45) < 1e-9);
            Check("Cap at half of 100% is 50%", Math.Abs(Caps.Half(100) - 0.5) < 1e-9);
            Check("Cap at half of a quiet app is 5%", Math.Abs(Caps.Half(3) - 0.05) < 1e-9);
            var listedGroups = new List<AppGroup>
            {
                new AppGroup { Key = "a", Cpu = 40, Memory = 1, Mine = true }, new AppGroup { Key = "b", Cpu = 1, Memory = 9, Mine = true },
                new AppGroup { Key = "c", Cpu = 0, Memory = 5, Mine = false }, new AppGroup { Key = "d", Cpu = 0, Memory = 3, Mine = true },
                new AppGroup { Key = "e", Cpu = 0, Memory = 2, Mine = true }, new AppGroup { Key = "f", Cpu = 0, Memory = 0.5, Mine = true },
            };
            var listed = Apps.Listed(listedGroups, new[] { listedGroups[0] }, new List<string> { "f" });
            Check("the list runs idled, busy, then the heaviest three", string.Join(",", listed.Select(g => g.Key)) == "f,a,b,d,e");
            Check("load under its line is normal", Levels.Load(79, 80) == Level.Normal);
            Check("load at its line is warm", Levels.Load(80, 80) == Level.Warm);
            Check("load at 90% is hot", Levels.Load(90, 80) == Level.Hot);
            Check("memory past its line is warm", Levels.Memory(14.5, 16, 0.9) == Level.Warm || Levels.Memory(14.5, 16, 0.9) == Level.Hot);
            Check("memory at 90% is hot", Levels.Memory(14.4, 16, 0.85) == Level.Hot);
            Check("memory under its line is normal", Levels.Memory(8, 16, 0.9) == Level.Normal);
            Check("temperature at its line is warm", Levels.Temperature(85, 85) == Level.Warm);
            Check("90 °C is hot", Levels.Temperature(90, 85) == Level.Hot);
            Check("an unknown temperature is normal", Levels.Temperature(null, 85) == Level.Normal);

            // defaults as the Mac registers them
            Check("CPU line defaults to 80", Levels.CpuLine == 80);
            Check("memory line defaults to 0.9", Levels.MemoryLine == 0.9);
            Check("heat line defaults to 85", Levels.HeatLine == 85);
            Check("CPU alerts default on", Store.Bool("cpuAlerts"));
            Check("Temperature defaults off", !Store.Bool("temperature"));

            // the alert clock: a minute's hold, then at most once in 15 minutes
            var clock = new AlertClock();
            var t0 = new DateTime(2026, 11, 20, 10, 0, 0, DateTimeKind.Utc);
            Check("a fresh condition waits", !clock.Due(true, t0));
            Check("59 s still waits", !clock.Due(true, t0.AddSeconds(59)));
            Check("a minute speaks", clock.Due(true, t0.AddSeconds(60)));
            Check("then stays quiet", !clock.Due(true, t0.AddSeconds(120)));
            Check("a break resets the hold", !clock.Due(false, t0.AddSeconds(130)));
            Check("15 minutes on, a new minute's hold speaks again", !clock.Due(true, t0.AddSeconds(1000)) && clock.Due(true, t0.AddSeconds(1061)));
            Check("held reads in minutes", clock.Held(t0.AddSeconds(1061 + 125)) == "3 minutes");

            // grouping: helpers under their app, the system's own parts by file
            var processes = new List<ProcessRecord>
            {
                new ProcessRecord { Pid = 10, ParentPid = 1, Exe = @"C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe", Product = "Brave Browser", Cpu = 10, Memory = 500 },
                new ProcessRecord { Pid = 11, ParentPid = 10, Exe = @"C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe", Product = "Brave Browser", Cpu = 20, Memory = 300 },
                new ProcessRecord { Pid = 12, ParentPid = 10, Exe = @"C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe", Product = "Brave Browser", Cpu = 5, Memory = 200 },
                new ProcessRecord { Pid = 20, ParentPid = 4, Exe = @"C:\Windows\System32\svchost.exe", Product = "Microsoft® Windows® Operating System", Cpu = 1, Memory = 50 },
                new ProcessRecord { Pid = 21, ParentPid = 4, Exe = @"C:\Windows\explorer.exe", Product = "Microsoft® Windows® Operating System", Cpu = 2, Memory = 80 },
                new ProcessRecord { Pid = 30, ParentPid = 1, Exe = "/usr/bin/node", Product = "", Cpu = 40, Memory = 900 },
            };
            var groups = Apps.Group(processes);
            var brave = groups.FirstOrDefault(g => g.Name == "Brave Browser");
            Check("Brave's three processes form one app", brave != null && brave.Pids.Count == 3);
            Check("an app's load is its processes' sum", brave != null && Math.Abs(brave.Cpu - 35) < 1e-9 && brave.Memory == 1000);
            Check("an app's root comes first", brave != null && brave.MainPid == 10);
            Check("the system's parts group by file", groups.Any(g => g.Name == "svchost") && groups.Any(g => g.Name == "explorer"));
            Check("a program without a product groups by file", groups.Any(g => g.Key == "file:node" && g.Name == "node"));
            Check("top by CPU", Apps.Top(groups, 1)[0].Key == "file:node");
            Check("top by memory", Apps.Top(groups, 1, true)[0].Key == "product:brave browser");

            // the busy list on 16 threads: join at 3.125%, leave under 1.875%
            var busy = new BusyList(16);
            var a = new AppGroup { Key = "a", Cpu = 3.2 };
            var b = new AppGroup { Key = "b", Cpu = 2.5 };
            Check("joins at half a core", busy.Update(new[] { a, b }, 5).Select(g => g.Key).SequenceEqual(new[] { "a" }));
            a.Cpu = 2.0;
            Check("holds above 30% of a core", busy.Update(new[] { a, b }, 5).Any(g => g.Key == "a"));
            a.Cpu = 1.5;
            Check("leaves under 30% of a core", !busy.Update(new[] { a, b }, 5).Any(g => g.Key == "a"));

            // caps: 5% to 80% in fives, saved and read back, Culpmit itself kept out
            Check("a cap snaps to fives", Math.Abs(Caps.Snap(0.52) - 0.5) < 1e-9);
            Check("a cap stops at 80%", Caps.Snap(1.0) == 0.8);
            Check("a cap starts at 5%", Caps.Snap(0.01) == 0.05);
            Caps.Save(new[]
            {
                new CappedApp { Id = "product:brave browser", Name = "Brave Browser", Exe = "brave.exe", Level = 0.5, On = true },
                new CappedApp { Id = "file:culpmit", Name = "Culpmit", Level = 0.3 },
                new CappedApp { Id = "file:node", Name = "node", Level = 0.95, On = false, MemoryLine = 6 },
            });
            Store.Forget();
            var caps = Caps.Load();
            Check("capped apps read back", caps.Count == 2 && caps[0].Name == "Brave Browser" && caps[0].On);
            Check("a level over the top reads back at 80%", caps[1].Level == 0.8 && !caps[1].On);
            Check("a memory line reads back", caps[1].MemoryLine == 6);
            var sixteen = 16 * Format.Gib;
            Check("memory line range on 16 GB is 1 to 12", Caps.LineRange(sixteen)[0] == 1 && Caps.LineRange(sixteen)[1] == 12);
            Check("a new app's memory line sits at half", Caps.LineOf(new CappedApp(), sixteen) == 8);

            // formats
            Check("percent", Format.Percent(83.6) == "84%");
            Check("gigabytes", Format.Gigabytes(13.14 * Format.Gib) == "13.1 GB");
            Check("cores", Format.Cores(37.5, 16) == "6 cores" && Format.Cores(1, 16) == "1 core");
            Check("degrees", Format.Degrees(72.4) == "72 °C");
            Check("newer versions", Format.IsNewer("1.10.0", "1.9.3") && !Format.IsNewer("1.0.3", "1.0.3") && Format.IsNewer("v0.2", "0.1.9"));

            try { Directory.Delete(dir, true); } catch (Exception) { }
            Console.WriteLine(passed + " passed, " + failed + " failed");
            return failed == 0 ? 0 : 1;
        }
    }
}
