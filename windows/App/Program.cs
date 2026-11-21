using System;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

namespace Culpmit
{
    // Culpmit for Windows: the app heating or slowing the PC named, and held to a share of the processor. "--setup",
    // "--remove" and "--quit" set up, remove and stop the app; "--status" prints the machine's readings and its busy apps;
    // "--login on" or "off" sets Open at login; "--panel" opens the running copy's panel; "--here" runs the exe where it sits. Started from anywhere else than its
    // own folder, the exe sets itself up there and starts that copy.

    internal static class Program
    {
        private static Mutex single;
        private static bool holding;

        public static string Version
        {
            get
            {
                var v = Assembly.GetExecutingAssembly().GetName().Version;
                return v.Major + "." + v.Minor + "." + v.Build;
            }
        }

        [STAThread]
        private static int Main(string[] args)
        {
            var a = args.ToList();
            if (a.Contains("--setup")) return Install.Setup();
            if (a.Contains("--remove")) return Install.Remove();
            if (a.Contains("--quit")) return Install.QuitRunning() ? 0 : 1;
            if (a.Contains("--panel")) return Install.OpenPanel();
            if (a.Contains("--status"))
            {
                PrintStatus();
                return 0;
            }
            var loginAt = a.IndexOf("--login");
            if (loginAt >= 0)
            {
                Stdio.Attach();
                if (loginAt + 1 < a.Count) Install.OpenAtLogin = a[loginAt + 1] == "on";
                Stdio.Line("open at login: " + (Install.OpenAtLogin ? "on" : "off"));
                return 0;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += (s, e) => Log.Note("error: " + e.Exception);
            AppDomain.CurrentDomain.UnhandledException += (s, e) => Log.Note("fatal: " + e.ExceptionObject);

            // a double-click on a downloaded copy sets Culpmit up in its own folder and starts that copy
            if (!Install.IsInstalledCopy && !a.Contains("--here")) return Install.FirstRun();

            single = new Mutex(false, Install.MutexName);
            try
            {
                holding = single.WaitOne(a.Contains("--wait") ? 10_000 : 0);
            }
            catch (AbandonedMutexException)
            {
                holding = true;
            }
            if (!holding) return 0;
            Application.Run(new Tray());
            try { single.ReleaseMutex(); } catch (Exception) { }
            return 0;
        }

        // --status: two readings a second apart, then the machine's load, memory and busy apps
        private static void PrintStatus()
        {
            Stdio.Attach();
            var sampler = new Sampler();
            sampler.Take();
            Thread.Sleep(1000);
            var snap = sampler.Take();
            Stdio.Line("CPU " + Format.Percent(snap.Load) + " of " + sampler.Threads + " threads");
            Stdio.Line("Memory " + Format.Gigabytes(snap.MemoryUsed) + " of " + Format.WholeGigabytes(snap.MemoryTotal));
            foreach (var app in Apps.Top(Apps.Group(snap.Processes), 5))
                Stdio.Line(app.Name + ": " + Format.Percent(app.Cpu) + " (" + Format.Cores(app.Cpu, sampler.Threads) + "), " + Format.Gigabytes(app.Memory) + ", " + app.Pids.Count + " processes");
        }
    }
}
