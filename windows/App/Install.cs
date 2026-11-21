using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using Microsoft.Win32;

namespace Culpmit
{
    // Setup and removal. The app lives in %LOCALAPPDATA%\Programs\Culpmit\Culpmit.exe, a folder of the person's own, so
    // every step runs with the person's own rights. "--setup" copies this exe there, lists Culpmit in Settings › Apps,
    // turns Open at login on and starts the app; "--remove" takes each back, quits the app (its caps lift as it leaves)
    // and deletes the exe. A double-click on a downloaded Culpmit.exe asks first, then runs the setup. Each step prints one
    // JSON line, {"step", "ok", "note"}, and the last one {"done", "ok"}; the exit code is 0 when every step went through.

    internal static class Install
    {
        public const string MutexName = @"Local\Culpmit.App";
        public const string QuitName = @"Local\Culpmit.Quit";
        public const string PanelName = @"Local\Culpmit.Panel";
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Culpmit";

        public static string InstallDir => Path.Combine(Paths.LocalData, "Programs", "Culpmit");
        public static string InstalledExe => Path.Combine(InstallDir, "Culpmit.exe");

        private static readonly Lazy<string> thisExe = new Lazy<string>(() => Process.GetCurrentProcess().MainModule.FileName);
        public static string ThisExe => thisExe.Value;
        public static bool IsInstalledCopy => Paths.Same(ThisExe, InstalledExe);

        private static bool allOK = true;
        private static bool printing;

        private static void Step(string name, bool ok, string note = "")
        {
            if (!ok) allOK = false;
            var line = new JObject { ["step"] = name, ["ok"] = ok };
            if (note.Length > 0) line["note"] = note;
            Log.Note("setup " + name + ": " + (ok ? "ok" : "failed") + (note.Length > 0 ? ", " + note : ""));
            if (printing) Stdio.Line(Json.Write(line));
        }

        private static int Finish()
        {
            if (printing) Stdio.Line(Json.Write(new JObject { ["done"] = true, ["ok"] = allOK }));
            return allOK ? 0 : 1;
        }

        // Open at login: the Run entry under the person's own key
        public static bool OpenAtLogin
        {
            get
            {
                using (var key = Registry.CurrentUser.OpenSubKey(RunKey))
                    return key?.GetValue("Culpmit") is string v && v.Trim('"').Length > 0 && File.Exists(v.Trim('"'));
            }
            set
            {
                try
                {
                    using (var key = Registry.CurrentUser.CreateSubKey(RunKey))
                    {
                        if (value) key.SetValue("Culpmit", "\"" + InstalledExe + "\"");
                        else if (key.GetValue("Culpmit") != null) key.DeleteValue("Culpmit");
                    }
                }
                catch (Exception e)
                {
                    Log.Note("open at login: " + e.Message);
                }
            }
        }

        // Settings › Apps: Culpmit's entry with its version, its Uninstall running Culpmit's own removal
        public static bool WriteAppsEntry()
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(UninstallKey))
                {
                    var remove = "\"" + InstalledExe + "\" --remove";
                    key.SetValue("DisplayName", "Culpmit");
                    key.SetValue("DisplayVersion", Program.Version);
                    key.SetValue("Publisher", "Simon Booban");
                    key.SetValue("DisplayIcon", InstalledExe);
                    key.SetValue("InstallLocation", InstallDir);
                    key.SetValue("UninstallString", remove);
                    key.SetValue("QuietUninstallString", remove);
                    key.SetValue("URLInfoAbout", "https://github.com/booban1/culpmit");
                    key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                    key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                    if (File.Exists(InstalledExe)) key.SetValue("EstimatedSize", (int)Math.Max(1, new FileInfo(InstalledExe).Length / 1024), RegistryValueKind.DWord);
                    if (key.GetValue("InstallDate") == null) key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
                }
                return true;
            }
            catch (Exception e)
            {
                Log.Note("apps entry: " + e.Message);
                return false;
            }
        }

        private static bool DeleteAppsEntry()
        {
            try
            {
                Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false);
                return true;
            }
            catch (Exception e)
            {
                Log.Note("apps entry: " + e.Message);
                return false;
            }
        }

        // The running copy

        public static bool IsRunning
        {
            get
            {
                try
                {
                    using (Mutex.OpenExisting(MutexName)) return true;
                }
                catch (Exception)
                {
                    return false;
                }
            }
        }

        // asks the running app to quit (its caps lift as it leaves), then ends any copy left after five seconds
        public static bool QuitRunning()
        {
            if (!IsRunning) return true;
            try
            {
                using (var quit = EventWaitHandle.OpenExisting(QuitName)) quit.Set();
            }
            catch (Exception) { }
            for (var i = 0; i < 50 && IsRunning; i++) Thread.Sleep(100);
            if (!IsRunning) return true;
            var self = Process.GetCurrentProcess().Id;
            foreach (var p in Process.GetProcessesByName("Culpmit").Where(p => p.Id != self))
            {
                try { p.Kill(); p.WaitForExit(2000); } catch (Exception) { }
            }
            Thread.Sleep(200);
            return !IsRunning;
        }

        // "--panel": the running copy opens its panel beside the tray, for a check or a shortcut
        public static int OpenPanel()
        {
            try
            {
                using (var panel = EventWaitHandle.OpenExisting(PanelName)) panel.Set();
                return 0;
            }
            catch (Exception)
            {
                return 1;
            }
        }

        // The steps

        private static void CopySelf()
        {
            if (IsInstalledCopy)
            {
                Step("install", true, "already in place");
                return;
            }
            try
            {
                if (File.Exists(InstalledExe) && !QuitRunning()) throw new IOException("the running Culpmit kept its place");
                Directory.CreateDirectory(InstallDir);
                var temp = InstalledExe + ".new";
                File.WriteAllBytes(temp, File.ReadAllBytes(ThisExe));
                if (File.Exists(InstalledExe)) File.Delete(InstalledExe);
                File.Move(temp, InstalledExe);
                Step("install", true, InstalledExe);
            }
            catch (Exception e)
            {
                Step("install", false, e.Message);
            }
        }

        private static int RunSetup()
        {
            CopySelf();
            Step("apps", WriteAppsEntry(), "Settings › Apps");
            OpenAtLogin = true;
            Step("login", OpenAtLogin, OpenAtLogin ? "on" : "the Run entry stayed off");
            if (IsRunning) Step("launch", true, "already running");
            else
            {
                try
                {
                    // started through the shell, so the app inherits zero handles: a caller reading setup's output meets
                    // its end once setup finishes
                    Process.Start(new ProcessStartInfo(InstalledExe) { UseShellExecute = true, WorkingDirectory = InstallDir });
                    Step("launch", true, "started");
                }
                catch (Exception e)
                {
                    Step("launch", false, e.Message);
                }
            }
            return Finish();
        }

        public static int Setup()
        {
            Stdio.Attach();
            printing = true;
            return RunSetup();
        }

        // a double-click on a downloaded copy: one dialog names every change first, then the same setup runs quietly
        public static int FirstRun()
        {
            var ask = "Culpmit names the app heating or slowing the PC and holds it to a share of the processor. Setting it up:\n\n"
                + "• puts Culpmit.exe in " + InstallDir + "\n"
                + "• opens Culpmit at login\n"
                + "• lists Culpmit in Settings › Apps\n\n"
                + "Remove Culpmit… in its panel, or Uninstall in Settings › Apps, takes each change back.";
            var answer = System.Windows.Forms.MessageBox.Show(ask, "Set up Culpmit?", System.Windows.Forms.MessageBoxButtons.OKCancel,
                System.Windows.Forms.MessageBoxIcon.None, System.Windows.Forms.MessageBoxDefaultButton.Button1);
            if (answer != System.Windows.Forms.DialogResult.OK) return 0;
            var code = RunSetup();
            if (code != 0)
            {
                var log = Paths.Read(Paths.LogPath) ?? "";
                var tail = string.Join("\n", log.Split('\n').Where(l => l.Contains(" setup ")).Reverse().Take(6).Reverse());
                System.Windows.Forms.MessageBox.Show("Culpmit's setup stopped at a step:\n\n" + tail, "Culpmit",
                    System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Warning);
            }
            return code;
        }

        // the exe and its folder go once this copy has quit; the folder goes only while empty
        private static void DeleteFilesAfterExit()
        {
            var script = "ping -n 3 127.0.0.1 >nul & del /f /q \"" + InstalledExe + "\" & rmdir \"" + InstallDir + "\"";
            try
            {
                Process.Start(new ProcessStartInfo("cmd.exe", "/c " + script)
                {
                    CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden,
                    WorkingDirectory = Path.GetTempPath(),
                });
                Step("files", true, "deleted after Culpmit quits");
            }
            catch (Exception e)
            {
                Step("files", false, e.Message);
            }
        }

        private static void RemoveSteps(bool quittingOthers)
        {
            OpenAtLogin = false;
            Step("login", !OpenAtLogin, OpenAtLogin ? "the Run entry stayed on" : "off");
            if (quittingOthers) Step("quit", QuitRunning(), "every cap lifted");
            Step("apps", DeleteAppsEntry(), "out of Settings › Apps");
            if (File.Exists(InstalledExe)) DeleteFilesAfterExit();
        }

        public static int Remove()
        {
            Stdio.Attach();
            printing = true;
            RemoveSteps(true);
            return Finish();
        }

        // the panel's Remove Culpmit: every step of a removal; the app quits after
        public static void RemoveFromApp() => RemoveSteps(false);
    }
}
