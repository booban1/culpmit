using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Culpmit
{
    // One moment of the machine: its load as a share of all its threads, its memory, and every process
    internal sealed class Snapshot
    {
        public double Load;             // percent of the whole machine
        public double MemoryUsed, MemoryTotal;
        public List<ProcessRecord> Processes = new List<ProcessRecord>();
        public DateTime At;
    }

    // Reads the machine each tick. The process table comes whole from NtQuerySystemInformation, the call Task Manager
    // reads, so a protected process still shows its CPU and memory; each process's share is its CPU time since the last
    // tick over the wall time times the machine's threads, the scale Culpmit's caps use. A program's full path and
    // product name are read once per process and kept.
    internal sealed class Sampler
    {
        public readonly int Threads = Math.Max(1, Environment.ProcessorCount);
        private readonly Dictionary<int, long> lastTimes = new Dictionary<int, long>();
        private readonly Dictionary<string, Tuple<string, string>> names = new Dictionary<string, Tuple<string, string>>();
        private readonly Dictionary<string, string> products = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private double lastWall = -1;
        private long lastIdle, lastBusy;
        private readonly int mySession;
        private IntPtr buffer = IntPtr.Zero;
        private int bufferSize = 1 << 20;

        // the struct's fields that move with pointer size; the earlier ones sit alike on 32 and 64 bits
        private static readonly bool wide = IntPtr.Size == 8;
        private static readonly int imageBuffer = wide ? 64 : 60;
        private static readonly int imageLength = 56;
        private static readonly int pidAt = wide ? 80 : 68;
        private static readonly int parentAt = wide ? 88 : 72;
        private static readonly int sessionAt = wide ? 100 : 80;

        public Sampler()
        {
            Native.ProcessIdToSessionId(Process.GetCurrentProcess().Id, out mySession);
        }

        public Snapshot Take()
        {
            var snap = new Snapshot { At = DateTime.UtcNow };
            var wall = clock.Elapsed.TotalSeconds;
            var span = lastWall < 0 ? 0 : wall - lastWall;
            lastWall = wall;

            if (Native.GetSystemTimes(out var idle, out var kernel, out var user))
            {
                var busy = kernel + user - idle;
                var dBusy = busy - lastBusy;
                var dAll = dBusy + (idle - lastIdle);
                if (lastBusy != 0 && dAll > 0) snap.Load = Math.Max(0, Math.Min(100, 100.0 * dBusy / dAll));
                lastIdle = idle;
                lastBusy = busy;
            }

            var status = new Native.MemoryStatus { Length = (uint)Marshal.SizeOf(typeof(Native.MemoryStatus)) };
            if (Native.GlobalMemoryStatusEx(ref status))
            {
                snap.MemoryTotal = status.TotalPhys;
                snap.MemoryUsed = status.TotalPhys - status.AvailPhys;
            }

            var seen = new HashSet<int>();
            foreach (var entry in Table())
            {
                seen.Add(entry.Pid);
                double share = 0;
                if (span > 0 && lastTimes.TryGetValue(entry.Pid, out var before) && entry.Time >= before)
                    share = 100.0 * (entry.Time - before) / 1e7 / (span * Threads);
                lastTimes[entry.Pid] = entry.Time;
                var named = Name(entry);
                snap.Processes.Add(new ProcessRecord
                {
                    Pid = entry.Pid, ParentPid = entry.Parent, Exe = named.Item1, Product = named.Item2,
                    Cpu = Math.Min(100, share), Memory = entry.Private, Mine = entry.Session == mySession && entry.Pid > 4,
                });
            }
            foreach (var gone in new List<int>(lastTimes.Keys))
                if (!seen.Contains(gone)) lastTimes.Remove(gone);
            return snap;
        }

        private struct Entry
        {
            public int Pid, Parent, Session;
            public long Time, Private, Created;
            public string Image;
        }

        private List<Entry> Table()
        {
            var list = new List<Entry>();
            for (var tries = 0; tries < 6; tries++)
            {
                if (buffer == IntPtr.Zero) buffer = Marshal.AllocHGlobal(bufferSize);
                var status = Native.NtQuerySystemInformation(Native.SystemProcessInformation, buffer, bufferSize, out var needed);
                if (status == Native.StatusInfoLengthMismatch)
                {
                    Marshal.FreeHGlobal(buffer);
                    buffer = IntPtr.Zero;
                    bufferSize = Math.Max(bufferSize * 2, needed + (1 << 16));
                    continue;
                }
                if (status != 0) return list;
                var at = 0;
                while (true)
                {
                    var p = buffer + at;
                    var next = Marshal.ReadInt32(p, 0);
                    var e = new Entry
                    {
                        Private = Marshal.ReadInt64(p, 8),
                        Created = Marshal.ReadInt64(p, 32),
                        Time = Marshal.ReadInt64(p, 40) + Marshal.ReadInt64(p, 48),
                        Pid = (int)Marshal.ReadIntPtr(p, pidAt).ToInt64(),
                        Parent = (int)Marshal.ReadIntPtr(p, parentAt).ToInt64(),
                        Session = Marshal.ReadInt32(p, sessionAt),
                    };
                    var length = Marshal.ReadInt16(p, imageLength) & 0xFFFF;
                    var text = Marshal.ReadIntPtr(p, imageBuffer);
                    e.Image = length > 0 && text != IntPtr.Zero ? Marshal.PtrToStringUni(text, length / 2) : (e.Pid == 0 ? "System Idle Process" : "System");
                    // the idle process's time is the machine's spare time, never a load
                    if (e.Pid != 0) list.Add(e);
                    if (next == 0) break;
                    at += next;
                }
                return list;
            }
            return list;
        }

        // a process's full path and product name, read once for each process (its pid and start time)
        private Tuple<string, string> Name(Entry e)
        {
            var key = e.Pid + ":" + e.Created;
            if (names.TryGetValue(key, out var known)) return known;
            var path = e.Image;
            var handle = Native.OpenProcess(Native.ProcessQueryLimited, false, e.Pid);
            if (handle != IntPtr.Zero)
            {
                var text = new StringBuilder(1024);
                var size = text.Capacity;
                if (Native.QueryFullProcessImageName(handle, 0, text, ref size)) path = text.ToString();
                Native.CloseHandle(handle);
            }
            var named = Tuple.Create(path, Product(path));
            if (names.Count > 4000) names.Clear();
            names[key] = named;
            return named;
        }

        private string Product(string path)
        {
            if (string.IsNullOrEmpty(path) || path.IndexOf('\\') < 0) return "";
            if (products.TryGetValue(path, out var known)) return known;
            var product = "";
            try
            {
                var info = FileVersionInfo.GetVersionInfo(path);
                product = (info.ProductName ?? "").Trim();
                if (product.Length == 0) product = (info.FileDescription ?? "").Trim();
            }
            catch (Exception) { }
            products[path] = product;
            return product;
        }
    }
}
