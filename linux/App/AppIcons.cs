using System;
using System.Collections.Generic;
using System.IO;
using Avalonia.Media.Imaging;

namespace Culpmit
{
    // Each app's own icon on Linux: the icon its desktop entry names, found as a PNG in the shared hicolor theme (the
    // person's, the system's, Flatpak's) or in /usr/share/pixmaps; an entry naming a file uses that file. Apps with
    // zero entry, or with an SVG alone, get the generic app icon. Each lookup runs once.
    internal static class AppIcons
    {
        private static readonly Dictionary<string, string> files = new Dictionary<string, string>(StringComparer.Ordinal);
        private static readonly Dictionary<string, Bitmap> pictures = new Dictionary<string, Bitmap>(StringComparer.Ordinal);
        private static readonly string[] sizes = { "48x48", "64x64", "32x32", "128x128", "256x256", "24x24", "22x22", "16x16" };

        public static string FileOf(string icon)
        {
            if (string.IsNullOrEmpty(icon)) return null;
            if (files.TryGetValue(icon, out var known)) return known;
            string found = null;
            if (icon.StartsWith("/")) found = icon.EndsWith(".png", StringComparison.OrdinalIgnoreCase) && File.Exists(icon) ? icon : null;
            else
            {
                var home = Environment.GetEnvironmentVariable("HOME") ?? "";
                var roots = new[] { home + "/.local/share/icons/hicolor", "/usr/share/icons/hicolor", "/var/lib/flatpak/exports/share/icons/hicolor", "/usr/local/share/icons/hicolor" };
                foreach (var size in sizes)
                {
                    foreach (var root in roots)
                    {
                        var path = root + "/" + size + "/apps/" + icon + ".png";
                        if (File.Exists(path))
                        {
                            found = path;
                            break;
                        }
                    }
                    if (found != null) break;
                }
                if (found == null && File.Exists("/usr/share/pixmaps/" + icon + ".png")) found = "/usr/share/pixmaps/" + icon + ".png";
            }
            files[icon] = found;
            return found;
        }

        // Culpmit's own icon, from inside the file
        private static Bitmap own;

        public static Bitmap Own()
        {
            if (own != null) return own;
            try
            {
                using (var stream = System.Reflection.Assembly.GetExecutingAssembly().GetManifestResourceStream("culpmit.png"))
                    if (stream != null) own = new Bitmap(stream);
            }
            catch (Exception) { }
            return own;
        }

        public static Bitmap Picture(string file)
        {
            if (string.IsNullOrEmpty(file)) return null;
            if (pictures.TryGetValue(file, out var known)) return known;
            Bitmap picture = null;
            try { picture = new Bitmap(file); }
            catch (Exception) { }
            pictures[file] = picture;
            return picture;
        }
    }
}
