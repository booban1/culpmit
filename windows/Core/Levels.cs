using System;

namespace Culpmit
{
    // Each reading's colour, as the Mac's: orange from its alert's line, red from 90%. Temperature's 90% is 90 °C. The
    // tray's two dots, the panel and the notices all read their colour here.

    public enum Level { Normal, Warm, Hot }

    public static class Levels
    {
        public const double HotShare = 0.9;
        public const double HotTemperature = 90;

        // the alert lines, each on its slider: CPU load in percent of the whole machine, memory as a share of the total,
        // temperature in °C
        public static readonly double[] CpuRange = { 25, 90 };
        public static readonly double[] MemoryRange = { 0.5, 0.95 };
        public static readonly double[] HeatRange = { 50, 90 };

        public static double CpuLine => Store.Num("cpuLine");
        public static double MemoryLine => Store.Num("memoryAlertLine");
        public static double HeatLine => Store.Num("heatLine");

        public static Level Load(double percent, double line) =>
            percent >= HotShare * 100 ? Level.Hot : percent >= line ? Level.Warm : Level.Normal;

        public static Level Memory(double used, double total, double line)
        {
            if (total <= 0) return Level.Normal;
            var share = used / total;
            return share >= HotShare ? Level.Hot : share >= line ? Level.Warm : Level.Normal;
        }

        public static Level Temperature(double? c, double line)
        {
            if (!c.HasValue) return Level.Normal;
            return c.Value >= HotTemperature ? Level.Hot : c.Value >= line ? Level.Warm : Level.Normal;
        }

        // a slider's value held inside its range, in its steps
        public static double Snap(double value, double low, double high, double step)
        {
            var v = Math.Round(value / step) * step;
            return Math.Max(low, Math.Min(high, v));
        }
    }

    // One alert's clock, the Mac's: how long its condition has held, and when it last spoke. Due once the condition has
    // held for a minute, at most once in 15 minutes.
    public sealed class AlertClock
    {
        private DateTime? since;
        public DateTime Last = DateTime.MinValue;
        public static double HoldSeconds = 60, GapSeconds = 900;

        public bool Due(bool holding, DateTime now)
        {
            if (!holding)
            {
                since = null;
                return false;
            }
            var start = since ?? now;
            since = start;
            if ((now - start).TotalSeconds < HoldSeconds || (now - Last).TotalSeconds <= GapSeconds) return false;
            Last = now;
            return true;
        }

        // "1 minute", "3 minutes": how long it has held
        public string Held(DateTime now)
        {
            var m = since.HasValue ? Math.Max(1, (int)((now - since.Value).TotalMinutes)) : 1;
            return m == 1 ? "1 minute" : m + " minutes";
        }
    }
}
