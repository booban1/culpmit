using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Culpmit
{
    // Caps and idle on Linux, two ways. First choice: one systemd scope per app under the person's own service manager,
    // holding its processes to a hard CPU quota on the whole machine (CPUQuotaPerSecUSec: a cap at 50% on 8 threads
    // allows 4 seconds of CPU each second). The kernel keeps that cap with zero work from Culpmit, and a child process
    // stays in its parent's scope by itself. Each scope carries a name, culpmit-<app>.scope, so a restarted Culpmit finds
    // it again and lifts its quota. The person's rights reach only the processes already inside their service manager
    // (apps a terminal starts, apps GNOME starts); an app the desktop session started itself (Cinnamon's menu, say) stays
    // where it sits, and those processes take the Mac's way: paused and resumed in 100 ms slices (Limiter). Membership is
    // read back from /proc/<pid>/cgroup each tick, so every process lands on one way or the other.
    internal sealed class Scopes
    {
        private sealed class Scope
        {
            public string Unit;
            public readonly HashSet<int> Tried = new HashSet<int>();
            public double? Share;
            public bool Started;
            public Limiter Paused;
        }

        private readonly Dictionary<string, Scope> scopes = new Dictionary<string, Scope>();
        // CULPMIT_PAUSES=1 sends every process the pauses' way, a check of that way on a desktop whose apps all sit
        // inside the person's service manager
        private static readonly bool PausesOnly = Environment.GetEnvironmentVariable("CULPMIT_PAUSES") == "1";
        private readonly int threads;

        public Scopes(int threads) { this.threads = Math.Max(1, threads); }

        public static string UnitOf(string key)
        {
            unchecked
            {
                var hash = 2166136261u;
                foreach (var b in Encoding.UTF8.GetBytes(key)) hash = (hash ^ b) * 16777619u;
                return "culpmit-" + hash.ToString("x8", CultureInfo.InvariantCulture) + ".scope";
            }
        }

        // the quota in microseconds of CPU per second for a share of the whole machine; a lift is infinity
        private ulong Quota(double? share) =>
            share.HasValue ? (ulong)Math.Max(1000, Math.Round(share.Value * threads * 1_000_000)) : ulong.MaxValue;

        private static bool InUnit(int pid, string unit)
        {
            try
            {
                foreach (var line in File.ReadLines("/proc/" + pid + "/cgroup"))
                    if (line.StartsWith("0::", StringComparison.Ordinal)) return line.EndsWith("/" + unit, StringComparison.Ordinal);
            }
            catch (Exception) { }
            return false;
        }

        public async Task Hold(AppGroup app, double? share)
        {
            if (!scopes.TryGetValue(app.Key, out var scope))
            {
                if (share == null) return;
                scope = new Scope { Unit = UnitOf(app.Key) };
                scopes[app.Key] = scope;
            }
            // the scope stands while it holds a process of the app; it ends with its last one, and the app's next
            // processes start a fresh one
            var inside = PausesOnly ? new List<int>() : app.Pids.Where(p => InUnit(p, scope.Unit)).ToList();
            scope.Started = inside.Count > 0;
            var fresh = app.Pids.Where(p => !inside.Contains(p) && !scope.Tried.Contains(p)).ToList();
            if (share.HasValue && fresh.Count > 0)
            {
                var pids = fresh.Select(p => (uint)p).ToArray();
                foreach (var p in fresh) scope.Tried.Add(p);
                if (PausesOnly) { }
                else if (!scope.Started)
                {
                    await Call("ResetFailedUnit", "s", new[] { scope.Unit }, quiet: true);
                    if (await Start(scope.Unit, pids, Quota(share)))
                    {
                        scope.Started = true;
                        scope.Share = share;
                        Log.Note("cap " + app.Name + " at " + Format.Percent(share.Value * 100) + " (" + pids.Length + " processes)");
                    }
                    else if (await Attach(scope.Unit, pids))
                    {
                        // a scope a copy before this one left: its quota follows below
                        scope.Started = true;
                        scope.Share = null;
                    }
                }
                else await Attach(scope.Unit, pids);
            }
            scope.Tried.IntersectWith(app.Pids);

            if (scope.Started && !Same(scope.Share, share) && await SetQuota(scope.Unit, Quota(share)))
            {
                scope.Share = share;
                Log.Note(share.HasValue ? "cap " + app.Name + " at " + Format.Percent(share.Value * 100) : "cap " + app.Name + " lifted");
            }
            if (!scope.Started) scope.Share = share;

            // the processes the scope refused: paused in slices to the same share
            // (processes sent this tick get their answer on the next one)
            var refused = app.Pids.Where(p => scope.Tried.Contains(p) && !inside.Contains(p) && !fresh.Contains(p)).ToList();
            if (share.HasValue && refused.Count > 0)
            {
                if (scope.Paused == null)
                {
                    scope.Paused = new Limiter(app.Name, threads);
                    Log.Note("cap " + app.Name + " by pauses (" + refused.Count + " processes outside the person's service manager)");
                }
                scope.Paused.Set(refused, share.Value);
            }
            else if (scope.Paused != null)
            {
                scope.Paused.Stop();
                scope.Paused = null;
            }
            if (!share.HasValue && scope.Paused == null && (!scope.Started || scope.Share == null)) scopes.Remove(app.Key);
        }

        private static bool Same(double? a, double? b) => a.HasValue == b.HasValue && (!a.HasValue || Math.Abs(a.Value - b.Value) < 1e-6);

        public IEnumerable<string> Held => scopes.Where(s => s.Value.Share.HasValue).Select(s => s.Key);

        // the person's service manager, through busctl, systemd's own bus tool: each call runs on its own connection,
        // apart from the tray's, and its arguments go in busctl's plain text form
        private static async Task<bool> Call(string member, string signature, string[] args, bool quiet = false)
        {
            var result = await Task.Run(() =>
            {
                try
                {
                    var info = new System.Diagnostics.ProcessStartInfo("busctl")
                    {
                        UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                    };
                    foreach (var a in new[] { "--user", "call", "org.freedesktop.systemd1", "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", member, signature })
                        info.ArgumentList.Add(a);
                    foreach (var a in args) info.ArgumentList.Add(a);
                    using (var process = System.Diagnostics.Process.Start(info))
                    {
                        var error = process.StandardError.ReadToEndAsync();
                        process.StandardOutput.ReadToEnd();
                        if (!process.WaitForExit(10_000))
                        {
                            try { process.Kill(); } catch (Exception) { }
                            return "timed out";
                        }
                        return process.ExitCode == 0 ? null : error.Result.Trim();
                    }
                }
                catch (Exception e)
                {
                    return e.Message;
                }
            });
            if (result != null && !quiet) Log.Note("scope " + member + ": " + result);
            return result == null;
        }

        private static string Number(ulong v) => v.ToString(CultureInfo.InvariantCulture);

        private static Task<bool> Start(string unit, uint[] pids, ulong quota)
        {
            var args = new List<string> { unit, "fail", "3", "Description", "s", "Culpmit cap", "PIDs", "au", pids.Length.ToString(CultureInfo.InvariantCulture) };
            args.AddRange(pids.Select(p => Number(p)));
            args.AddRange(new[] { "CPUQuotaPerSecUSec", "t", Number(quota), "0" });
            return Call("StartTransientUnit", "ssa(sv)a(sa(sv))", args.ToArray());
        }

        private static Task<bool> Attach(string unit, uint[] pids)
        {
            var args = new List<string> { unit, "", pids.Length.ToString(CultureInfo.InvariantCulture) };
            args.AddRange(pids.Select(p => Number(p)));
            return Call("AttachProcessesToUnit", "ssau", args.ToArray(), quiet: true);
        }

        private static Task<bool> SetQuota(string unit, ulong quota) =>
            Call("SetUnitProperties", "sba(sv)", new[] { unit, "true", "1", "CPUQuotaPerSecUSec", "t", Number(quota) }, quiet: quota == ulong.MaxValue);

        // what a copy before this one left: quotas come off by their scopes' names, paused processes resume
        public static async Task LiftLeftovers(IEnumerable<string> keys, IEnumerable<AppGroup> groups)
        {
            var list = keys.ToList();
            foreach (var key in list) await SetQuota(UnitOf(key), ulong.MaxValue);
            foreach (var g in groups.Where(g => list.Contains(g.Key)))
                foreach (var pid in g.Pids) Limiter.Resume(pid);
        }

        // a quit or a removal lifts every quota and every pause; the apps run free until they end
        public async Task FreeAll()
        {
            foreach (var s in scopes.Values)
            {
                s.Paused?.Stop();
                if (s.Started && s.Share.HasValue) await SetQuota(s.Unit, ulong.MaxValue);
            }
            scopes.Clear();
        }

        // the last resort on a crash: every paused process resumes, from any thread, synchronously
        public void ResumeAllNow()
        {
            foreach (var s in scopes.Values) s.Paused?.Stop();
        }
    }

    // The Mac's limiter on Linux, for processes a scope cannot take: every 100 ms slice the app runs for its share of the
    // slice and pauses for the rest (SIGCONT, then SIGSTOP). The working share adapts to the app's measured use, so a
    // cap at 25% of the machine holds near 25% whatever the app's own demand, as cpulimit does it.
    internal sealed class Limiter
    {
        [DllImport("libc", SetLastError = true)]
        private static extern int kill(int pid, int sig);

        private const int SigCont = 18, SigStop = 19;
        private const double Period = 0.1, Ticks = 100;
        private readonly object gate = new object();
        private readonly string name;
        private readonly int threads;
        private List<int> pids = new List<int>();
        private double share;
        private volatile bool running = true;
        private readonly Thread thread;

        public Limiter(string name, int threads)
        {
            this.name = name;
            this.threads = Math.Max(1, threads);
            thread = new Thread(Run) { IsBackground = true, Name = "limiter " + name };
            thread.Start();
        }

        public void Set(IEnumerable<int> members, double level)
        {
            lock (gate)
            {
                pids = members.ToList();
                share = level;
            }
        }

        public static void Resume(int pid) => kill(pid, SigCont);

        public void Stop()
        {
            running = false;
            thread.Join(500);
            List<int> last;
            lock (gate) last = pids.ToList();
            foreach (var p in last) kill(p, SigCont);
        }

        private static long CpuTicks(int pid)
        {
            try
            {
                var stat = File.ReadAllText("/proc/" + pid + "/stat");
                var f = stat.Substring(stat.LastIndexOf(')') + 2).Split(' ');
                return long.Parse(f[11], CultureInfo.InvariantCulture) + long.Parse(f[12], CultureInfo.InvariantCulture);
            }
            catch (Exception)
            {
                return 0;
            }
        }

        private void Run()
        {
            var clock = System.Diagnostics.Stopwatch.StartNew();
            double working = -1, used = -1;
            long lastTicks = -1;
            var lastWall = 0.0;
            while (running)
            {
                List<int> members;
                double level;
                lock (gate)
                {
                    members = pids.ToList();
                    level = share;
                }
                // the app's use over the last slice, as a share of the whole machine, smoothed
                var ticks = members.Sum(CpuTicks);
                var wall = clock.Elapsed.TotalSeconds;
                if (lastTicks >= 0 && wall > lastWall && ticks >= lastTicks)
                {
                    var sample = (ticks - lastTicks) / Ticks / ((wall - lastWall) * threads);
                    used = used < 0 ? sample : used * 0.7 + sample * 0.3;
                }
                lastTicks = ticks;
                lastWall = wall;
                working = working < 0 || used <= 0 ? level : Math.Max(0.02, Math.Min(1, working / Math.Max(used, 1e-4) * level));

                foreach (var p in members) kill(p, SigCont);
                Thread.Sleep(TimeSpan.FromSeconds(Period * working));
                if (!running || working >= 1) continue;
                foreach (var p in members) kill(p, SigStop);
                Thread.Sleep(TimeSpan.FromSeconds(Period * (1 - working)));
            }
            List<int> last;
            lock (gate) last = pids.ToList();
            foreach (var p in last) kill(p, SigCont);
            Log.Note("pauses lifted from " + name);
        }
    }
}
