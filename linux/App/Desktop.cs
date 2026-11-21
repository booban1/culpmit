using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Tmds.DBus.Protocol;

namespace Culpmit
{
    // The desktop's buses: notices through org.freedesktop.Notifications, and keep awake through the session's own
    // idle-sleep hold (org.gnome.SessionManager, which Cinnamon, GNOME and MATE carry), else logind's idle inhibitor.
    // Each call fails quietly where the desktop lacks the service.

    internal static class Desktop
    {
        private static DBusConnection bus, system;
        private static readonly object gate = new object();
        public static volatile bool Dropped;

        public static async Task<DBusConnection> Bus()
        {
            lock (gate)
                if (bus != null) return bus;
            var fresh = new DBusConnection(DBusAddress.Session);
            await fresh.ConnectAsync();
            // a closed connection is forgotten, so the next call opens a fresh one, and the tray registers again
            _ = fresh.DisconnectedAsync().ContinueWith(t =>
            {
                lock (gate)
                {
                    if (!ReferenceEquals(bus, fresh)) return;
                    bus = null;
                    Dropped = true;
                }
                Log.Note("bus closed: " + (t.Result?.Message ?? "ended"));
            });
            lock (gate)
            {
                if (bus != null)
                {
                    fresh.Dispose();
                    return bus;
                }
                bus = fresh;
                return bus;
            }
        }

        private static async Task<DBusConnection> SystemBus()
        {
            lock (gate)
                if (system != null) return system;
            var fresh = new DBusConnection(DBusAddress.System);
            await fresh.ConnectAsync();
            lock (gate)
            {
                if (system != null)
                {
                    fresh.Dispose();
                    return system;
                }
                system = fresh;
                return system;
            }
        }

        // a notice with Culpmit's icon; a notice with the same replaces id takes the earlier one's place
        public static async Task<uint> Notify(string title, string body, uint replaces = 0)
        {
            try
            {
                var connection = await Bus();
                MessageBuffer message;
                using (var writer = connection.GetMessageWriter())
                {
                    writer.WriteMethodCallHeader("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                        "org.freedesktop.Notifications", "Notify", "susssasa{sv}i", MessageFlags.None);
                    writer.WriteString("Culpmit");
                    writer.WriteUInt32(replaces);
                    writer.WriteString("culpmit");
                    writer.WriteString(title ?? "");
                    writer.WriteString(body ?? "");
                    writer.WriteArray(new string[0]);
                    writer.WriteDictionary(new[] { new KeyValuePair<string, VariantValue>("desktop-entry", VariantValue.String("culpmit")) });
                    writer.WriteInt32(-1);
                    message = writer.CreateMessage();
                }
                return await connection.CallMethodAsync(message, (Message m, object s) => m.GetBodyReader().ReadUInt32(), null);
            }
            catch (Exception e)
            {
                Log.Note("notice failed: " + e.Message);
                return 0;
            }
        }

        // Keep awake: the session's hold on idle sleep (flag 8, suspend on idle), a cookie to lift it; where the session
        // lacks the service, logind's idle inhibitor, held by its file descriptor. The lid still sleeps the machine:
        // logind lets the lid pass inhibitors by default.

        private static uint cookie;
        private static SafeHandle inhibitor;

        public static async Task<bool> HoldAwake()
        {
            if (cookie != 0 || inhibitor != null) return true;
            try
            {
                var connection = await Bus();
                MessageBuffer message;
                using (var writer = connection.GetMessageWriter())
                {
                    writer.WriteMethodCallHeader("org.gnome.SessionManager", "/org/gnome/SessionManager", "org.gnome.SessionManager", "Inhibit", "susu", MessageFlags.None);
                    writer.WriteString("culpmit");
                    writer.WriteUInt32(0);
                    writer.WriteString("Keep awake");
                    writer.WriteUInt32(8);
                    message = writer.CreateMessage();
                }
                cookie = await connection.CallMethodAsync(message, (Message m, object s) => m.GetBodyReader().ReadUInt32(), null);
                return true;
            }
            catch (Exception) { }
            try
            {
                var connection = await SystemBus();
                MessageBuffer message;
                using (var writer = connection.GetMessageWriter())
                {
                    writer.WriteMethodCallHeader("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "Inhibit", "ssss", MessageFlags.None);
                    writer.WriteString("idle");
                    writer.WriteString("Culpmit");
                    writer.WriteString("Keep awake");
                    writer.WriteString("block");
                    message = writer.CreateMessage();
                }
                inhibitor = await connection.CallMethodAsync(message, (Message m, object s) => m.GetBodyReader().ReadHandle<SafeFileHandle>(), null);
                return inhibitor != null;
            }
            catch (Exception e)
            {
                Log.Note("keep awake: " + e.Message);
                return false;
            }
        }

        public static async Task LetGo()
        {
            if (cookie != 0)
            {
                try
                {
                    var connection = await Bus();
                    MessageBuffer message;
                    using (var writer = connection.GetMessageWriter())
                    {
                        writer.WriteMethodCallHeader("org.gnome.SessionManager", "/org/gnome/SessionManager", "org.gnome.SessionManager", "Uninhibit", "u", MessageFlags.None);
                        writer.WriteUInt32(cookie);
                        message = writer.CreateMessage();
                    }
                    await connection.CallMethodAsync(message);
                }
                catch (Exception) { }
                cookie = 0;
            }
            inhibitor?.Dispose();
            inhibitor = null;
        }
    }
}
