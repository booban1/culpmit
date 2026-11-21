using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Culpmit
{
    // The Windows calls .NET Framework leaves out: the whole process table in one call, the machine's load and memory,
    // job objects for caps and idle, keep awake and the battery, and the window touches the panel uses
    internal static class Native
    {
        // the process table, every process with its CPU times, private working set, image name and parent
        [DllImport("ntdll.dll")]
        internal static extern int NtQuerySystemInformation(int infoClass, IntPtr buffer, int length, out int needed);

        internal const int SystemProcessInformation = 5;
        internal const int StatusInfoLengthMismatch = unchecked((int)0xC0000004);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetSystemTimes(out long idle, out long kernel, out long user);

        [StructLayout(LayoutKind.Sequential)]
        internal struct MemoryStatus
        {
            public uint Length;
            public uint MemoryLoad;
            public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtendedVirtual;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr OpenProcess(int access, bool inherit, int pid);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);

        internal const int ProcessTerminate = 0x0001;
        internal const int ProcessSetQuota = 0x0100;
        internal const int ProcessQueryLimited = 0x1000;

        // job objects: a named job per app, its CPU held by a hard cap on the whole machine's time
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr CreateJobObject(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [StructLayout(LayoutKind.Sequential)]
        internal struct CpuRateControl
        {
            public uint ControlFlags;
            public uint CpuRate;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref CpuRateControl info, int length);

        internal const int JobObjectCpuRateControlInformation = 15;
        internal const uint CpuRateEnable = 0x1, CpuRateHardCap = 0x4;

        // keep awake: system sleep held off while idle; the display may still sleep
        [DllImport("kernel32.dll")]
        internal static extern uint SetThreadExecutionState(uint flags);

        internal const uint EsContinuous = 0x80000000, EsSystemRequired = 0x00000001;

        [StructLayout(LayoutKind.Sequential)]
        internal struct PowerStatus
        {
            public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
            public int BatteryLifeTime, BatteryFullLifeTime;
        }

        [DllImport("kernel32.dll")]
        internal static extern bool GetSystemPowerStatus(out PowerStatus status);

        [DllImport("kernel32.dll")]
        internal static extern bool ProcessIdToSessionId(int pid, out int session);

        // the panel and the tray icon
        [DllImport("user32.dll", SetLastError = true)]
        internal static extern bool DestroyIcon(IntPtr icon);

        [DllImport("user32.dll")]
        internal static extern bool SetForegroundWindow(IntPtr window);

        [DllImport("dwmapi.dll")]
        internal static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

        internal const int DwmCornerPreference = 33;
        internal const int DwmCornerRound = 2;

        // the command forms' console
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool AttachConsole(int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr GetStdHandle(int which);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetConsoleMode(IntPtr handle, out int mode);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern bool WriteConsoleW(IntPtr handle, string text, int length, out int written, IntPtr reserved);

        internal const int StdOutput = -11;
    }

    // stdout for the command forms: a person's terminal gets its text through the console in full Unicode, a pipe gets
    // UTF-8
    internal static class Stdio
    {
        private static bool attached;

        public static void Attach()
        {
            if (attached) return;
            attached = true;
            Native.AttachConsole(-1);
        }

        public static void Line(string text)
        {
            Attach();
            var handle = Native.GetStdHandle(Native.StdOutput);
            var line = text + "\r\n";
            if (handle != IntPtr.Zero && handle != new IntPtr(-1) && Native.GetConsoleMode(handle, out _))
            {
                Native.WriteConsoleW(handle, line, line.Length, out _, IntPtr.Zero);
                return;
            }
            try
            {
                using (var stdout = Console.OpenStandardOutput())
                {
                    var bytes = new UTF8Encoding(false).GetBytes(line);
                    stdout.Write(bytes, 0, bytes.Length);
                }
            }
            catch (IOException) { }
        }
    }
}
