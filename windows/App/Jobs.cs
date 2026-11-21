using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace Culpmit
{
    // Caps and idle on Windows: one job object per app, holding every process of the app to a hard cap on the whole
    // machine's CPU time, the scale Culpmit's caps already use (a cap at 50% lets the app use half of all threads). Windows
    // keeps the cap itself, with zero pauses from Culpmit's side, and a process the app starts later joins its parent's job
    // by itself. Each job carries a name, Local\Culpmit.<app>, so a restarted Culpmit opens the same job and moves or
    // lifts its cap: a process stays in its job until it ends, and a job without a cap is a plain group again.
    internal sealed class Jobs
    {
        private sealed class Job
        {
            public IntPtr Handle;
            public readonly HashSet<int> Members = new HashSet<int>();
            public readonly HashSet<int> Refused = new HashSet<int>();
            public double? Share;
        }

        private readonly Dictionary<string, Job> jobs = new Dictionary<string, Job>();

        // an app's job name from its key, short and stable
        private static string NameOf(string key)
        {
            unchecked
            {
                var hash = 2166136261u;
                foreach (var b in Encoding.UTF8.GetBytes(key)) hash = (hash ^ b) * 16777619u;
                return @"Local\Culpmit." + hash.ToString("x8", CultureInfo.InvariantCulture);
            }
        }

        // holds the app's processes to the share given (a fraction of the whole machine), or with null lets them run free
        public void Hold(AppGroup app, double? share)
        {
            if (!jobs.TryGetValue(app.Key, out var job))
            {
                if (share == null) return;
                var handle = Native.CreateJobObject(IntPtr.Zero, NameOf(app.Key));
                if (handle == IntPtr.Zero)
                {
                    Log.Note("cap " + app.Name + ": the job failed, error " + Marshal.GetLastWin32Error());
                    return;
                }
                job = new Job { Handle = handle };
                jobs[app.Key] = job;
            }
            foreach (var pid in app.Pids)
            {
                if (job.Members.Contains(pid) || job.Refused.Contains(pid)) continue;
                if (Join(job.Handle, pid)) job.Members.Add(pid);
                else job.Refused.Add(pid);
            }
            job.Members.IntersectWith(app.Pids);
            job.Refused.IntersectWith(app.Pids);
            if (Same(job.Share, share)) return;
            if (Rate(job.Handle, share))
            {
                job.Share = share;
                Log.Note(share.HasValue
                    ? "cap " + app.Name + " at " + Format.Percent(share.Value * 100) + " (" + job.Members.Count + " processes)"
                    : "cap " + app.Name + " lifted");
            }
        }

        private static bool Same(double? a, double? b) => a.HasValue == b.HasValue && (!a.HasValue || Math.Abs(a.Value - b.Value) < 1e-6);

        private static bool Join(IntPtr job, int pid)
        {
            var process = Native.OpenProcess(Native.ProcessSetQuota | Native.ProcessTerminate, false, pid);
            if (process == IntPtr.Zero) return false;
            try { return Native.AssignProcessToJobObject(job, process); }
            finally { Native.CloseHandle(process); }
        }

        // the job's hard cap in hundredths of a percent of the whole machine, 1 at least; null lifts it
        private static bool Rate(IntPtr job, double? share)
        {
            var info = new Native.CpuRateControl();
            if (share.HasValue)
            {
                info.ControlFlags = Native.CpuRateEnable | Native.CpuRateHardCap;
                info.CpuRate = (uint)Math.Max(1, Math.Min(10000, Math.Round(share.Value * 10000)));
            }
            var ok = Native.SetInformationJobObject(job, Native.JobObjectCpuRateControlInformation, ref info, Marshal.SizeOf(typeof(Native.CpuRateControl)));
            if (!ok) Log.Note("cap: the rate failed, error " + Marshal.GetLastWin32Error());
            return ok;
        }

        // the apps Culpmit holds, by key
        public IEnumerable<string> Held => jobs.Where(j => j.Value.Share.HasValue).Select(j => j.Key);

        public int Members(string key) => jobs.TryGetValue(key, out var job) ? job.Members.Count : 0;

        // caps a copy before this one left in place (it closed without its quit, or crashed): each named job opened again
        // and its cap lifted, before this copy sets its own
        public static void LiftLeftovers(IEnumerable<string> keys)
        {
            foreach (var key in keys)
            {
                var handle = Native.CreateJobObject(IntPtr.Zero, NameOf(key));
                if (handle == IntPtr.Zero) continue;
                Rate(handle, null);
                Native.CloseHandle(handle);
            }
        }

        // a quit or a removal lifts every cap and lets go of the jobs; their processes run free
        public void FreeAll()
        {
            foreach (var job in jobs.Values)
            {
                if (job.Share.HasValue) Rate(job.Handle, null);
                Native.CloseHandle(job.Handle);
            }
            jobs.Clear();
        }
    }
}
