using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using Microsoft.Win32;

namespace Culpmit
{
    // Light and dark from Windows' own switches: the taskbar's for the tray icon, the apps' for the panel
    internal sealed class Palette
    {
        public Color Back, Card, CardLine, Text, Sub, Accent, Orange, Red, Line, Hover, Track;

        public static bool TaskbarLight => Read("SystemUsesLightTheme", 0) == 1;
        public static bool AppsLight => Read("AppsUseLightTheme", 1) == 1;

        private static int Read(string name, int fallback)
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                    return key?.GetValue(name) is int v ? v : fallback;
            }
            catch (Exception)
            {
                return fallback;
            }
        }

        // Windows 11's flyout colours
        public static Palette Current => AppsLight
            ? new Palette
            {
                Back = Hex(0xF3F3F3), Card = Hex(0xFFFFFF), CardLine = Hex(0xE5E5E5), Text = Hex(0x1B1B1B), Sub = Hex(0x616161),
                Accent = Hex(0x005FB8), Orange = Hex(0xF7630C), Red = Hex(0xD13438), Line = Hex(0xE0E0E0),
                Hover = Color.FromArgb(10, 0, 0, 0), Track = Hex(0xE1E1E1),
            }
            : new Palette
            {
                Back = Hex(0x2C2C2C), Card = Hex(0x373737), CardLine = Hex(0x3F3F3F), Text = Hex(0xFFFFFF), Sub = Hex(0xC5C5C5),
                Accent = Hex(0x60CDFF), Orange = Hex(0xFC8B3E), Red = Hex(0xFF6B7A), Line = Hex(0x404040),
                Hover = Color.FromArgb(18, 255, 255, 255), Track = Hex(0x4A4A4A),
            };

        // a reading's colour in the panel: its tone, else the text's ink
        public Color Of(Level level) => level == Level.Hot ? Red : level == Level.Warm ? Orange : Text;

        public static Color Hex(int rgb) => Color.FromArgb(255, (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);
    }

    // The tray icon: two dots stacked, the top one temperature (CPU load while Temperature is off),
    // the bottom one memory, each in its level's colour on the taskbar's own ink; grey while a reading is missing
    internal static class Dots
    {
        public static Bitmap Draw(int size, Level top, Level bottom, bool topKnown, bool lightTaskbar)
        {
            var bmp = new Bitmap(size, size);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                var d = size * 0.44f;
                var x = (size - d) / 2f;
                using (var a = new SolidBrush(topKnown ? Colour(top, lightTaskbar) : Grey(lightTaskbar)))
                    g.FillEllipse(a, x, size * 0.04f, d, d);
                using (var b = new SolidBrush(Colour(bottom, lightTaskbar)))
                    g.FillEllipse(b, x, size * 0.52f, d, d);
            }
            return bmp;
        }

        // the tones on the taskbar: the Windows tray's orange and red, white or near black for normal
        public static Color Colour(Level level, bool lightTaskbar)
        {
            if (level == Level.Hot) return lightTaskbar ? Palette.Hex(0xD13438) : Palette.Hex(0xFF6B7A);
            if (level == Level.Warm) return lightTaskbar ? Palette.Hex(0xF7630C) : Palette.Hex(0xFC8B3E);
            return lightTaskbar ? Palette.Hex(0x1B1B1B) : Color.White;
        }

        private static Color Grey(bool lightTaskbar) => lightTaskbar ? Palette.Hex(0x8A8A8A) : Palette.Hex(0x9A9A9A);
    }
}
