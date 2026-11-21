using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

namespace Culpmit
{
    // Setup and removal on Linux, every step with the person's own rights. The app lives in ~/.local/bin/culpmit, the
    // folder Ubuntu and Mint put on the PATH; "--setup" copies this file there, writes the menu entry, its icon and the
    // autostart entry, and starts the app; "--remove" quits the running copy (which lifts every cap) and takes each step
    // back. Started from anywhere else (a download), the file sets itself up the same way. Each step prints one JSON
    // line, {"step", "ok", "note"}, and the last one {"done", "ok"}; the exit code is 0 when every step went through.

    internal static class Install
    {
        private static string Local => Path.Combine(Paths.Home, ".local");
        public static string InstalledExe => Path.Combine(Local, "bin", "culpmit");
        private static string IconPath => Path.Combine(Local, "share", "icons", "hicolor", "256x256", "apps", "culpmit.png");
        private static string MenuEntry => Path.Combine(Local, "share", "applications", "culpmit.desktop");
        private static string ConfigHome
        {
            get
            {
                var set = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
                return !string.IsNullOrEmpty(set) && set.StartsWith("/") ? set : Path.Combine(Paths.Home, ".config");
            }
        }
        private static string AutostartEntry => Path.Combine(ConfigHome, "autostart", "culpmit.desktop");
        public static string PidPath => Path.Combine(Paths.SupportDir, "app.pid");

        public static string ThisExe => Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule.FileName;
        public static bool IsInstalledCopy => Paths.Same(ThisExe, InstalledExe);

        private static bool allOK = true;

        private static void Step(string name, bool ok, string note = "")
        {
            if (!ok) allOK = false;
            var line = new JObject { ["step"] = name, ["ok"] = ok };
            if (note.Length > 0) line["note"] = note;
            Log.Note("setup " + name + ": " + (ok ? "ok" : "failed") + (note.Length > 0 ? ", " + note : ""));
            Console.WriteLine(Json.Write(line));
        }

        private static int Finish()
        {
            Console.WriteLine(Json.Write(new JObject { ["done"] = true, ["ok"] = allOK }));
            return allOK ? 0 : 1;
        }

        // The desktop entries: the menu's, and autostart's for Open at login

        private static string Entry(bool autostart) =>
            "[Desktop Entry]\nType=Application\nName=Culpmit\nComment=The app heating or slowing the machine, named and capped\n"
            + "Exec=" + InstalledExe + "\nIcon=culpmit\nTerminal=false\nCategories=Utility;System;Monitor;\n"
            + (autostart ? "X-GNOME-Autostart-enabled=true\n" : "StartupNotify=false\n");

        public static bool OpenAtLogin
        {
            get => File.Exists(AutostartEntry);
            set
            {
                try
                {
                    if (value)
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(AutostartEntry));
                        File.WriteAllText(AutostartEntry, Entry(true), new UTF8Encoding(false));
                    }
                    else if (File.Exists(AutostartEntry)) File.Delete(AutostartEntry);
                }
                catch (Exception e)
                {
                    Log.Note("open at login: " + e.Message);
                }
            }
        }

        // The running copy: its process id in app.pid, held while it runs

        public static int RunningPid
        {
            get
            {
                if (!int.TryParse(Paths.Read(PidPath)?.Trim(), out var pid) || pid == Environment.ProcessId) return 0;
                try
                {
                    using (var p = Process.GetProcessById(pid))
                        return !p.HasExited && p.ProcessName.StartsWith("culpmit", StringComparison.Ordinal) ? pid : 0;
                }
                catch (Exception)
                {
                    return 0;
                }
            }
        }

        public static bool IsRunning => RunningPid != 0;

        // asks the running app to quit (SIGTERM, which it answers by lifting its caps and closing), then ends it after
        // eight seconds
        public static bool QuitRunning()
        {
            var pid = RunningPid;
            if (pid == 0) return true;
            Process running;
            try { running = Process.GetProcessById(pid); }
            catch (Exception) { return true; }
            using (running)
            {
                RunTool("kill", "-TERM " + pid, out _, 5);
                if (running.WaitForExit(8000)) return true;
                try { running.Kill(); running.WaitForExit(2000); } catch (Exception) { }
                return running.HasExited;
            }
        }

        // "culpmit --panel": the running copy opens its panel on SIGUSR1; with zero copies running, a fresh one opens
        // with its panel showing
        public static bool AskForPanel()
        {
            var pid = RunningPid;
            return pid != 0 && RunTool("kill", "-USR1 " + pid, out _, 5) == 0;
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
                Directory.CreateDirectory(Path.GetDirectoryName(InstalledExe));
                var temp = InstalledExe + ".new";
                File.Copy(ThisExe, temp, true);
                File.SetUnixFileMode(temp, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute
                    | UnixFileMode.GroupRead | UnixFileMode.GroupExecute | UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
                File.Move(temp, InstalledExe, true);
                Step("install", true, InstalledExe);
            }
            catch (Exception e)
            {
                Step("install", false, e.Message);
            }
        }

        private static void EntriesStep()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(IconPath));
                using (var from = Assembly.GetExecutingAssembly().GetManifestResourceStream("culpmit.png"))
                using (var to = File.Create(IconPath))
                    from.CopyTo(to);
                Directory.CreateDirectory(Path.GetDirectoryName(MenuEntry));
                File.WriteAllText(MenuEntry, Entry(false), new UTF8Encoding(false));
                Step("menu", true, MenuEntry);
            }
            catch (Exception e)
            {
                Step("menu", false, e.Message);
            }
        }

        public static int Setup()
        {
            CopySelf();
            EntriesStep();
            OpenAtLogin = true;
            Step("login", OpenAtLogin, OpenAtLogin ? "on" : "the autostart entry stayed off");
            if (IsRunning) Step("launch", true, "already running");
            else
            {
                try
                {
                    // its own fresh output pipes, so the app holds zero handles of setup's: a caller reading setup's output
                    // meets its end once setup finishes
                    Process.Start(new ProcessStartInfo(InstalledExe)
                    {
                        UseShellExecute = false, WorkingDirectory = Paths.Home,
                        RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                    });
                    Step("launch", true, "started");
                }
                catch (Exception e)
                {
                    Step("launch", false, e.Message);
                }
            }
            return Finish();
        }

        private static void RemoveSteps(bool quittingOthers)
        {
            OpenAtLogin = false;
            Step("login", !OpenAtLogin, OpenAtLogin ? "the autostart entry stayed" : "off");
            if (quittingOthers) Step("quit", QuitRunning(), "every cap lifted");
            try
            {
                foreach (var file in new[] { MenuEntry, IconPath }) if (File.Exists(file)) File.Delete(file);
                // a running program's file can go on Linux: the process keeps its copy until it ends
                if (File.Exists(InstalledExe)) File.Delete(InstalledExe);
                Step("files", true, "deleted");
            }
            catch (Exception e)
            {
                Step("files", false, e.Message);
            }
        }

        public static int Remove()
        {
            RemoveSteps(true);
            return Finish();
        }

        public static void RemoveFromApp() => RemoveSteps(false);

        // a tool's exit code and output, ended after its time
        public static int RunTool(string path, string arguments, out string output, int seconds = 120)
        {
            output = "";
            try
            {
                var info = new ProcessStartInfo(path, arguments)
                {
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
                };
                using (var process = Process.Start(info))
                {
                    var text = new StringBuilder();
                    process.OutputDataReceived += (s, e) => { if (e.Data != null) lock (text) text.AppendLine(e.Data); };
                    process.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (text) text.AppendLine(e.Data); };
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    if (!process.WaitForExit(seconds * 1000))
                    {
                        try { process.Kill(); } catch (Exception) { }
                        output = "timed out";
                        return -1;
                    }
                    process.WaitForExit();
                    lock (text) output = text.ToString();
                    return process.ExitCode;
                }
            }
            catch (Exception e)
            {
                output = e.Message;
                return -1;
            }
        }
    }
}
