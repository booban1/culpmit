using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Themes.Fluent;

namespace Culpmit
{
    // Culpmit for Linux: the app heating or slowing the machine named, and held to a share of the processor. The command
    // forms match the Windows exe's: "--setup", "--remove" and "--quit" set up, remove and stop the app; "--status"
    // prints the machine's readings and its busy apps; "--login on" or "off" sets Open at login; "--panel" opens the
    // running copy's panel; "--here" runs the file where it sits. Started from anywhere else than ~/.local/bin/culpmit,
    // the file sets itself up there and starts that copy.

    internal static class Program
    {
        private static PosixSignalRegistration term, usr1;
        private const int SigUsr1 = 10;
        public static bool OpenPanelAtStart;

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
            if (a.Contains("--status"))
            {
                PrintStatus();
                return 0;
            }
            var loginAt = a.IndexOf("--login");
            if (loginAt >= 0)
            {
                if (loginAt + 1 < a.Count) Install.OpenAtLogin = a[loginAt + 1] == "on";
                Console.WriteLine("open at login: " + (Install.OpenAtLogin ? "on" : "off"));
                return 0;
            }
            if (a.Contains("--panel"))
            {
                if (Install.AskForPanel()) return 0;
                OpenPanelAtStart = true;
            }

            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            {
                Log.Note("fatal: " + e.ExceptionObject);
                App.Current_?.ResumeAllNow();
            };

            // a downloaded copy sets Culpmit up in ~/.local/bin and starts that copy
            if (!Install.IsInstalledCopy && !a.Contains("--here")) return Install.Setup();

            // one copy at a time: a restart starts the next while this one is still leaving
            var waitUntil = DateTime.UtcNow.AddSeconds(a.Contains("--wait") ? 10 : 0);
            while (Install.IsRunning)
            {
                if (DateTime.UtcNow >= waitUntil) return 0;
                Thread.Sleep(200);
            }
            Paths.WriteAtomic(Install.PidPath, Environment.ProcessId.ToString());

            return AppBuilder.Configure<App>().UsePlatformDetect().LogToTrace()
                .StartWithClassicDesktopLifetime(args, ShutdownMode.OnExplicitShutdown);
        }

        // SIGTERM from "culpmit --quit" or a logout closes the app as Quit does; SIGUSR1 from "culpmit --panel" opens
        // the panel
        public static void Listen(Controller controller)
        {
            term = PosixSignalRegistration.Create(PosixSignal.SIGTERM, ctx =>
            {
                ctx.Cancel = true;
                Avalonia.Threading.Dispatcher.UIThread.Post(controller.Quit);
            });
            usr1 = PosixSignalRegistration.Create((PosixSignal)SigUsr1, ctx =>
            {
                ctx.Cancel = true;
                Avalonia.Threading.Dispatcher.UIThread.Post(controller.OpenPanel);
            });
        }

        public static void Leave()
        {
            try
            {
                if (Paths.Read(Install.PidPath)?.Trim() == Environment.ProcessId.ToString()) File.Delete(Install.PidPath);
            }
            catch (Exception) { }
            if (Application.Current?.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop) desktop.Shutdown();
            else Environment.Exit(0);
        }

        // --status: two readings a second apart, then the machine's temperature, load, memory and busy apps
        private static void PrintStatus()
        {
            var sampler = new Sampler();
            sampler.Take();
            Thread.Sleep(1000);
            var snap = sampler.Take();
            var heat = Sensors.Temperature();
            Console.WriteLine("Temperature " + (heat.HasValue ? Format.Degrees(heat.Value) : "unavailable (zero CPU sensor)"));
            Console.WriteLine("CPU " + Format.Percent(snap.Load) + " of " + sampler.Threads + " threads");
            Console.WriteLine("Memory " + Format.Gigabytes(snap.MemoryUsed) + " of " + Format.WholeGigabytes(snap.MemoryTotal));
            foreach (var app in Apps.Top(Apps.Group(snap.Processes).Where(g => g.Key != "file:culpmit" && g.Key != "product:culpmit"), 5))
                Console.WriteLine(app.Name + ": " + Format.Percent(app.Cpu) + " (" + Format.Cores(app.Cpu, sampler.Threads) + "), " + Format.Gigabytes(app.Memory) + ", " + app.Pids.Count + " processes" + (app.Mine ? "" : ", another account's"));
        }
    }

    internal sealed class App : Application
    {
        private Controller controller;
        public static Controller Current_;

        public override void Initialize()
        {
            Name = "Culpmit";
            // the compact density sits closer to the Mac menu's rows
            Styles.Add(new FluentTheme { DensityStyle = DensityStyle.Compact });
        }

        public override void OnFrameworkInitializationCompleted()
        {
            controller = new Controller();
            Current_ = controller;
            controller.Start(Program.OpenPanelAtStart);
            Program.Listen(controller);
            base.OnFrameworkInitializationCompleted();
        }
    }
}
