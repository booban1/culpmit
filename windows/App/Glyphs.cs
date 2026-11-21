using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;

namespace Culpmit
{
    // The Fluent icons on GDI+: each icon's SVG path read once into a GraphicsPath (moves, lines, cubic and quadratic
    // curves, arcs turned into curves, the nonzero rule), then filled at any size in any colour
    internal static class Glyphs
    {
        private static readonly Dictionary<string, GraphicsPath> paths = new Dictionary<string, GraphicsPath>();

        public static void Draw(Graphics g, string data, RectangleF box, Color colour)
        {
            if (g == null) return;
            if (!paths.TryGetValue(data, out var path))
            {
                path = Parse(data);
                paths[data] = path;
            }
            using (var placed = (GraphicsPath)path.Clone())
            using (var m = new Matrix())
            using (var brush = new SolidBrush(colour))
            {
                var k = Math.Min(box.Width, box.Height) / (float)Icons.Box;
                m.Translate(box.X + (box.Width - (float)Icons.Box * k) / 2, box.Y + (box.Height - (float)Icons.Box * k) / 2);
                m.Scale(k, k);
                placed.Transform(m);
                var mode = g.SmoothingMode;
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.FillPath(brush, placed);
                g.SmoothingMode = mode;
            }
        }

        private sealed class Reader
        {
            private readonly string s;
            private int i;
            public Reader(string s) { this.s = s; }

            private void Skip()
            {
                while (i < s.Length && (s[i] == ' ' || s[i] == ',' || s[i] == '\n' || s[i] == '\t' || s[i] == '\r')) i++;
            }

            public bool AtEnd { get { Skip(); return i >= s.Length; } }

            public bool AtCommand { get { Skip(); return i < s.Length && char.IsLetter(s[i]) && s[i] != 'e' && s[i] != 'E'; } }

            public char Command()
            {
                Skip();
                return s[i++];
            }

            public float Number()
            {
                Skip();
                var start = i;
                if (i < s.Length && (s[i] == '-' || s[i] == '+')) i++;
                var dot = false;
                while (i < s.Length && (char.IsDigit(s[i]) || (s[i] == '.' && !dot)))
                {
                    if (s[i] == '.') dot = true;
                    i++;
                }
                if (i < s.Length && (s[i] == 'e' || s[i] == 'E'))
                {
                    i++;
                    if (i < s.Length && (s[i] == '-' || s[i] == '+')) i++;
                    while (i < s.Length && char.IsDigit(s[i])) i++;
                }
                return float.Parse(s.Substring(start, i - start), NumberStyles.Float, CultureInfo.InvariantCulture);
            }

            // an arc's flags are single digits, written with or without a gap
            public bool Flag()
            {
                Skip();
                return s[i++] == '1';
            }
        }

        public static GraphicsPath Parse(string d)
        {
            var path = new GraphicsPath(FillMode.Winding);
            var r = new Reader(d);
            var cur = new PointF();
            var start = new PointF();
            var lastControl = new PointF();
            var lastCubic = false;
            var lastQuad = false;
            var cmd = 'M';
            while (!r.AtEnd)
            {
                if (r.AtCommand) cmd = r.Command();
                var rel = char.IsLower(cmd);
                var up = char.ToUpperInvariant(cmd);
                PointF P(float x, float y) => rel ? new PointF(cur.X + x, cur.Y + y) : new PointF(x, y);
                var wasCubic = false;
                var wasQuad = false;
                switch (up)
                {
                    case 'M':
                        cur = P(r.Number(), r.Number());
                        start = cur;
                        path.StartFigure();
                        // more pairs after a move are lines
                        cmd = rel ? 'l' : 'L';
                        break;
                    case 'L':
                    {
                        var to = P(r.Number(), r.Number());
                        path.AddLine(cur, to);
                        cur = to;
                        break;
                    }
                    case 'H':
                    {
                        var x = r.Number();
                        var to = new PointF(rel ? cur.X + x : x, cur.Y);
                        path.AddLine(cur, to);
                        cur = to;
                        break;
                    }
                    case 'V':
                    {
                        var y = r.Number();
                        var to = new PointF(cur.X, rel ? cur.Y + y : y);
                        path.AddLine(cur, to);
                        cur = to;
                        break;
                    }
                    case 'C':
                    {
                        var c1 = P(r.Number(), r.Number());
                        var c2 = P(r.Number(), r.Number());
                        var to = P(r.Number(), r.Number());
                        path.AddBezier(cur, c1, c2, to);
                        lastControl = c2;
                        cur = to;
                        wasCubic = true;
                        break;
                    }
                    case 'S':
                    {
                        var c1 = lastCubic ? new PointF(2 * cur.X - lastControl.X, 2 * cur.Y - lastControl.Y) : cur;
                        var c2 = P(r.Number(), r.Number());
                        var to = P(r.Number(), r.Number());
                        path.AddBezier(cur, c1, c2, to);
                        lastControl = c2;
                        cur = to;
                        wasCubic = true;
                        break;
                    }
                    case 'Q':
                    {
                        var q = P(r.Number(), r.Number());
                        var to = P(r.Number(), r.Number());
                        Quad(path, cur, q, to);
                        lastControl = q;
                        cur = to;
                        wasQuad = true;
                        break;
                    }
                    case 'T':
                    {
                        var q = lastQuad ? new PointF(2 * cur.X - lastControl.X, 2 * cur.Y - lastControl.Y) : cur;
                        var to = P(r.Number(), r.Number());
                        Quad(path, cur, q, to);
                        lastControl = q;
                        cur = to;
                        wasQuad = true;
                        break;
                    }
                    case 'A':
                    {
                        var rx = r.Number();
                        var ry = r.Number();
                        var turn = r.Number();
                        var large = r.Flag();
                        var sweep = r.Flag();
                        var to = P(r.Number(), r.Number());
                        Arc(path, cur, rx, ry, turn, large, sweep, to);
                        cur = to;
                        break;
                    }
                    case 'Z':
                        path.CloseFigure();
                        cur = start;
                        break;
                    default:
                        return path;
                }
                lastCubic = wasCubic;
                lastQuad = wasQuad;
            }
            return path;
        }

        private static void Quad(GraphicsPath path, PointF from, PointF q, PointF to)
        {
            var c1 = new PointF(from.X + 2f / 3 * (q.X - from.X), from.Y + 2f / 3 * (q.Y - from.Y));
            var c2 = new PointF(to.X + 2f / 3 * (q.X - to.X), to.Y + 2f / 3 * (q.Y - to.Y));
            path.AddBezier(from, c1, c2, to);
        }

        // an SVG arc as cubic curves, a quarter turn at most each (SVG 1.1, F.6.5)
        private static void Arc(GraphicsPath path, PointF from, double rx, double ry, double turnDeg, bool large, bool sweep, PointF to)
        {
            if (Math.Abs(from.X - to.X) < 1e-6 && Math.Abs(from.Y - to.Y) < 1e-6) return;
            rx = Math.Abs(rx);
            ry = Math.Abs(ry);
            if (rx < 1e-9 || ry < 1e-9)
            {
                path.AddLine(from, to);
                return;
            }
            var phi = turnDeg * Math.PI / 180;
            var cos = Math.Cos(phi);
            var sin = Math.Sin(phi);
            var dx2 = (from.X - to.X) / 2.0;
            var dy2 = (from.Y - to.Y) / 2.0;
            var x1 = cos * dx2 + sin * dy2;
            var y1 = -sin * dx2 + cos * dy2;
            var lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry);
            if (lambda > 1)
            {
                rx *= Math.Sqrt(lambda);
                ry *= Math.Sqrt(lambda);
            }
            var num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
            var den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
            var coef = Math.Sqrt(Math.Max(0, num / den)) * (large == sweep ? -1 : 1);
            var cxp = coef * rx * y1 / ry;
            var cyp = -coef * ry * x1 / rx;
            var cx = cos * cxp - sin * cyp + (from.X + to.X) / 2.0;
            var cy = sin * cxp + cos * cyp + (from.Y + to.Y) / 2.0;
            double Angle(double ux, double uy, double vx, double vy) => Math.Atan2(ux * vy - uy * vx, ux * vx + uy * vy);
            var start = Angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry);
            var span = Angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry);
            if (!sweep && span > 0) span -= 2 * Math.PI;
            if (sweep && span < 0) span += 2 * Math.PI;
            var parts = Math.Max(1, (int)Math.Ceiling(Math.Abs(span) / (Math.PI / 2) - 1e-9));
            var step = span / parts;
            var t = 4.0 / 3 * Math.Tan(step / 4);
            PointF At(double a) => new PointF(
                (float)(cx + rx * Math.Cos(a) * cos - ry * Math.Sin(a) * sin),
                (float)(cy + rx * Math.Cos(a) * sin + ry * Math.Sin(a) * cos));
            PointF Tangent(double a) => new PointF(
                (float)(-rx * Math.Sin(a) * cos - ry * Math.Cos(a) * sin),
                (float)(-rx * Math.Sin(a) * sin + ry * Math.Cos(a) * cos));
            for (var k = 0; k < parts; k++)
            {
                var a1 = start + k * step;
                var a2 = a1 + step;
                var p1 = k == 0 ? from : At(a1);
                var p2 = k == parts - 1 ? to : At(a2);
                var e1 = Tangent(a1);
                var e2 = Tangent(a2);
                var c1 = new PointF((float)(p1.X + t * e1.X), (float)(p1.Y + t * e1.Y));
                var c2 = new PointF((float)(p2.X - t * e2.X), (float)(p2.Y - t * e2.Y));
                path.AddBezier(p1, c1, c2, p2);
            }
        }
    }

    // Each app's own icon, from its program file, read once per file; system parts without a readable file get the
    // generic app icon
    internal static class AppIcons
    {
        private static readonly Dictionary<string, Bitmap> cache = new Dictionary<string, Bitmap>(StringComparer.OrdinalIgnoreCase);

        public static Bitmap Of(string exe)
        {
            if (string.IsNullOrEmpty(exe)) return null;
            if (cache.TryGetValue(exe, out var known)) return known;
            Bitmap found = null;
            try
            {
                if (Path.IsPathRooted(exe) && File.Exists(exe))
                    using (var icon = Icon.ExtractAssociatedIcon(exe))
                        if (icon != null) found = icon.ToBitmap();
            }
            catch (Exception) { }
            if (cache.Count > 300) cache.Clear();
            cache[exe] = found;
            return found;
        }
    }
}
