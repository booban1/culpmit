using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Linq;
using System.Windows.Forms;

namespace Culpmit
{
    // The panel a click on the tray icon opens: the Mac menu's rows in Windows' own dress. Performance with Culpmit's
    // icon, the readings as tiles that take their level's colour, the app rows (each app's icon, its CPU share and
    // memory, the tortoise to cap and the moon to idle, red while on), the capped apps in two rows each (name, use and
    // switch; then the cap and the memory line side by side), Keep awake and Open at login, the alerts as one row each
    // (switch, line and value), Remove and Quit. A right click on a capped app removes it, as Option does on the Mac.
    // Drawn by hand in one pass that lays out, paints and records the clickable rows and the sliders; a wheel scrolls a
    // long panel. It closes as it loses focus or on Escape.
    internal sealed class Panel : Form
    {
        private readonly Tray tray;
        private readonly List<Hit> hits = new List<Hit>();
        private readonly List<Hit> menus = new List<Hit>();
        private readonly List<Slider> sliders = new List<Slider>();
        private Hit hover;
        private Slider dragging;
        private Palette palette = Palette.Current;
        private float s = 1;
        private int scroll, contentHeight;
        private Font body, bold, small, smallBold;
        private DateTime hiddenAt = DateTime.MinValue;
        private const int Width0 = 380;

        private sealed class Hit
        {
            public Rectangle Box;
            public Action Act;
        }

        private sealed class Slider
        {
            public string Id;
            public Rectangle Box;
            public double Low, High, Step, Value;
            public Action<double, bool> Change;
        }

        public Panel(Tray tray)
        {
            this.tray = tray;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            DoubleBuffered = true;
            KeyPreview = true;
            Text = "Culpmit";
            Deactivate += (o, e) => { if (dragging == null) Hide(); };
            KeyDown += (o, e) => { if (e.KeyCode == Keys.Escape) Hide(); };
            MouseMove += (o, e) =>
            {
                if (dragging != null) Drag(e.X, false);
                else Hover(e.Location);
            };
            MouseLeave += (o, e) => Hover(new Point(-1, -1));
            MouseDown += (o, e) =>
            {
                if (e.Button != MouseButtons.Left) return;
                var slider = sliders.FirstOrDefault(x => Grab(x.Box).Contains(e.Location));
                if (slider == null) return;
                dragging = slider;
                Capture = true;
                Drag(e.X, false);
            };
            MouseUp += (o, e) =>
            {
                if (dragging != null)
                {
                    Drag(e.X, true);
                    dragging = null;
                    Capture = false;
                    return;
                }
                if (e.Button == MouseButtons.Right)
                {
                    var target = menus.FirstOrDefault(h => h.Box.Contains(e.Location));
                    if (target == null) return;
                    var menu = new ContextMenuStrip();
                    menu.Items.Add("Remove from Capped apps", null, (a, b) => target.Act());
                    menu.Show(this, e.Location);
                    return;
                }
                if (e.Button != MouseButtons.Left) return;
                hits.FirstOrDefault(h => h.Box.Contains(e.Location))?.Act();
            };
            MouseWheel += (o, e) =>
            {
                var most = Math.Max(0, contentHeight - Height);
                scroll = Math.Max(0, Math.Min(most, scroll - e.Delta / 2));
                Invalidate();
            };
            VisibleChanged += (o, e) => { if (!Visible) hiddenAt = DateTime.UtcNow; };
        }

        // a click on the icon while the panel is open first takes its focus away, which hides it; that same click then
        // leaves it hidden
        public bool JustHidden => (DateTime.UtcNow - hiddenAt).TotalMilliseconds < 300;

        protected override CreateParams CreateParams
        {
            get
            {
                var p = base.CreateParams;
                p.ExStyle |= 0x80; // a tool window, kept out of Alt+Tab
                p.ClassStyle |= 0x20000; // its drop shadow
                return p;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            var round = Native.DwmCornerRound;
            try { Native.DwmSetWindowAttribute(Handle, Native.DwmCornerPreference, ref round, sizeof(int)); } catch (Exception) { }
        }

        private void Fonts()
        {
            s = DeviceDpi / 96f;
            body?.Dispose(); bold?.Dispose(); small?.Dispose(); smallBold?.Dispose();
            var family = Pick("Segoe UI Variable Text", "Segoe UI");
            body = new Font(family, 13 * s, FontStyle.Regular, GraphicsUnit.Pixel);
            bold = new Font(family, 13 * s, FontStyle.Bold, GraphicsUnit.Pixel);
            small = new Font(family, 12 * s, FontStyle.Regular, GraphicsUnit.Pixel);
            smallBold = new Font(family, 12 * s, FontStyle.Bold, GraphicsUnit.Pixel);
        }

        private static string Pick(params string[] names)
        {
            using (var installed = new InstalledFontCollection())
                foreach (var n in names)
                    if (installed.Families.Any(f => f.Name == n)) return n;
            return SystemFonts.MessageBoxFont.FontFamily.Name;
        }

        public void ShowNear(Point at)
        {
            palette = Palette.Current;
            Fonts();
            BackColor = palette.Back;
            scroll = 0;
            contentHeight = Pass(null);
            var screen = Screen.FromPoint(at);
            var wa = screen.WorkingArea;
            var b = screen.Bounds;
            var m = (int)(12 * s);
            var w = (int)(Width0 * s);
            var height = Math.Min(contentHeight, wa.Height - 2 * m);
            var x = Math.Max(wa.Left + m, Math.Min(at.X - w / 2, wa.Right - w - m));
            var y = wa.Bottom - height - m;
            if (wa.Top > b.Top) y = wa.Top + m;
            if (wa.Right < b.Right) x = wa.Right - w - m;
            if (wa.Left > b.Left) x = wa.Left + m;
            Bounds = new Rectangle(x, y, w, height);
            Show();
            Native.SetForegroundWindow(Handle);
            Activate();
        }

        // a fresh layout at the current height, the bottom edge held where it sits
        public void Redraw()
        {
            if (!Visible) return;
            palette = Palette.Current;
            BackColor = palette.Back;
            var saved = scroll;
            scroll = 0;
            contentHeight = Pass(null);
            scroll = Math.Min(saved, Math.Max(0, contentHeight - Height));
            var wa = Screen.FromControl(this).WorkingArea;
            var height = Math.Min(contentHeight, wa.Height - (int)(24 * s));
            if (height != Height)
            {
                var top = wa.Top > Screen.FromControl(this).Bounds.Top ? Top : Bottom - height;
                Bounds = new Rectangle(Left, top, Width, height);
            }
            Invalidate();
        }

        private void Hover(Point p)
        {
            var next = hits.FirstOrDefault(h => h.Box.Contains(p));
            var onSlider = sliders.Any(x => Grab(x.Box).Contains(p));
            Cursor = next != null || onSlider ? Cursors.Hand : Cursors.Default;
            if (next?.Box == hover?.Box) return;
            hover = next;
            Invalidate();
        }

        // a slider takes a press a little above and below its track
        private Rectangle Grab(Rectangle track) => Rectangle.Inflate(track, (int)(6 * s), (int)(10 * s));

        private void Drag(int x, bool final)
        {
            var sl = dragging;
            if (sl == null) return;
            var t = Math.Max(0, Math.Min(1, (x - sl.Box.X) / (double)Math.Max(1, sl.Box.Width)));
            var v = Levels.Snap(sl.Low + t * (sl.High - sl.Low), sl.Low, sl.High, sl.Step);
            if (!final && Math.Abs(v - sl.Value) < 1e-9) return;
            sl.Value = v;
            sl.Change(v, final);
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(palette.Back);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            Pass(e.Graphics);
            using (var line = new Pen(palette.CardLine))
                e.Graphics.DrawRectangle(line, 0, 0, Width - 1, Height - 1);
        }

        private int P(float v) => (int)Math.Round(v * s);

        // One pass: given a Graphics it paints, given null it measures; either way it returns the height and records the
        // rows and sliders
        private int Pass(Graphics g)
        {
            if (body == null) Fonts();
            hits.Clear();
            menus.Clear();
            var keep = dragging;
            sliders.Clear();
            var w = (int)(Width0 * s);
            var pad = P(16);
            var inner = w - 2 * pad;
            var y = P(12) - scroll;
            var now = tray.Now;

            // Performance, with Culpmit's own icon at the right
            Say(g, "Performance", bold, palette.Text, new Rectangle(pad, y, inner - P(24), P(20)));
            var own = AppIcons.Of(Application.ExecutablePath);
            if (g != null && own != null) g.DrawImage(own, new Rectangle(w - pad - P(16), y + P(2), P(16), P(16)));
            y += P(26);

            // the readings as tiles: temperature while its switch is on, CPU, memory used of the whole
            var tiles = new List<Tuple<string, string, Level>>();
            if (Store.Bool("temperature") && tray.Temperature.HasValue)
                tiles.Add(Tuple.Create(Icons.Temperature, Format.Degrees(tray.Temperature.Value), Levels.Temperature(tray.Temperature, Levels.HeatLine)));
            tiles.Add(Tuple.Create(Icons.Gauge, Format.Percent(now.Load), Levels.Load(now.Load, Levels.CpuLine)));
            tiles.Add(Tuple.Create(Icons.Memory, Format.Gigabytes(now.MemoryUsed).Replace(" GB", "") + "/" + Format.WholeGigabytes(now.MemoryTotal), tray.MemoryLevel));
            var gap = P(6);
            var tileW = (inner - gap * (tiles.Count - 1)) / tiles.Count;
            for (var i = 0; i < tiles.Count; i++)
                Tile(g, new Rectangle(pad + i * (tileW + gap), y, tileW, P(30)), tiles[i].Item1, tiles[i].Item2, tiles[i].Item3);
            y += P(30) + P(10);
            Rule(g, y, w);
            y += P(8);

            // the app rows: idled, busy, then the heaviest three, each with the tortoise and the moon
            Say(g, "Busy apps", bold, palette.Text, new Rectangle(pad, y, inner, P(20)));
            y += P(24);
            var rows = tray.Rows;
            if (rows.Count == 0)
            {
                Say(g, "Every app is calm", small, palette.Sub, new Rectangle(pad, y, inner, P(20)));
                y += P(26);
            }
            foreach (var app in rows)
            {
                AppRow(g, app, y, pad, w);
                y += P(28);
            }
            y += P(4);

            // the capped apps: two rows each, name, use and switch, then the cap and the memory line
            if (tray.Capped.Count > 0)
            {
                Rule(g, y, w);
                y += P(8);
                Say(g, "Capped apps", bold, palette.Text, new Rectangle(pad, y, inner, P(20)));
                y += P(24);
                var first = true;
                foreach (var c in tray.Capped.ToList())
                {
                    if (!first)
                    {
                        Rule(g, y, w, pad);
                        y += P(6);
                    }
                    first = false;
                    var top = y;
                    var app = tray.GroupOf(c.Id);
                    var id = c.Id;
                    var on = c.On;
                    var pic = AppIcons.Of(app?.Exe ?? c.Exe);
                    Picture(g, pic, Icons.App, new Rectangle(pad, y + P(5), P(16), P(16)));
                    var switchBox = new Rectangle(w - pad - P(40), y + P(3), P(40), P(20));
                    var use = app == null ? "Closed" : (tray.IsIdled(id) ? "Idled" : Format.Percent(app.Cpu)) + " · " + Format.Gigabytes(app.Memory);
                    Say(g, use, small, palette.Sub, new Rectangle(switchBox.X - P(130), y, P(122), P(26)), TextFormatFlags.Right);
                    Say(g, c.Name, body, on ? palette.Text : palette.Sub, new Rectangle(pad + P(24), y, switchBox.X - P(136) - pad - P(24), P(26)));
                    Row(new Rectangle(switchBox.X - P(4), y, switchBox.Width + P(8), P(26)), () => tray.SetCapOn(id, !on));
                    Switch(g, switchBox, on);
                    y += P(28);
                    // the cap, 5% to 80% of the machine, and the memory line in GB, side by side
                    var half = (inner - P(16)) / 2;
                    var range = Caps.LineRange(now.MemoryTotal);
                    var lineGb = Caps.LineOf(c, now.MemoryTotal);
                    SliderRow(g, "cap:" + id, Icons.Gauge, new Rectangle(pad, y, half, P(22)), Caps.Low, Caps.High, Caps.Step, c.Level, on,
                        v => Format.Percent(v * 100), (v, final) => tray.SetCap(id, v, final));
                    SliderRow(g, "line:" + id, Icons.Memory, new Rectangle(pad + half + P(16), y, half, P(22)), range[0], range[1], 1, lineGb, on,
                        v => Format.WholeGigabytes(v * Format.Gib), (v, final) => tray.SetMemoryLine(id, v, final));
                    y += P(28);
                    menus.Add(new Hit { Box = new Rectangle(0, top, w, y - top), Act = () => tray.Uncap(id) });
                }
            }

            Rule(g, y, w);
            y += P(6);

            // keep awake and open at login
            var awakeOn = Store.Bool("keepAwake");
            SwitchRow(g, Awake.OnBatteryLow && awakeOn ? "Keep awake · let go, battery under 20%" : "Keep awake", awakeOn, true, () => tray.SetSwitch("keepAwake", !awakeOn), y, pad, w);
            y += P(30);
            var canLogin = Install.IsInstalledCopy;
            var loginOn = Install.OpenAtLogin;
            SwitchRow(g, "Open at login", loginOn, canLogin, () => tray.SetOpenAtLogin(!loginOn), y, pad, w);
            y += P(30);

            Rule(g, y + P(2), w);
            y += P(8);

            // the alerts, one row each: name, line, value, switch
            y = AlertRow(g, "CPU alerts", "cpuAlerts", "cpuLine", Levels.CpuRange[0], Levels.CpuRange[1], 5, v => Format.Percent(v), y, pad, w);
            y = AlertRow(g, "Memory alerts", "memoryAlerts", "memoryAlertLine", Levels.MemoryRange[0], Levels.MemoryRange[1], 0.05, v => Format.Percent(v * 100), y, pad, w);
            if (Store.Bool("temperature"))
                y = AlertRow(g, "Heat alerts", "heatAlerts", "heatLine", Levels.HeatRange[0], Levels.HeatRange[1], 5, v => Format.Degrees(v), y, pad, w);

            Rule(g, y + P(2), w);
            y += P(8);
            if (Install.IsInstalledCopy)
            {
                Link(g, "Remove Culpmit…", new Rectangle(pad, y, inner, P(30)), tray.ConfirmRemove);
                y += P(30);
            }
            Link(g, "Quit Culpmit", new Rectangle(pad, y, inner, P(30)), tray.Quit);
            Say(g, Program.Version, small, palette.Sub, new Rectangle(w - pad - P(100), y, P(100), P(30)), TextFormatFlags.Right);
            y += P(30) + P(8);

            dragging = keep == null ? null : sliders.FirstOrDefault(x => x.Id == keep.Id) ?? keep;
            return y + scroll;
        }

        // A reading's tile: its icon and value, in its level's colour with dark ink once past its line, as on the Mac
        private void Tile(Graphics g, Rectangle box, string icon, string value, Level level)
        {
            if (g == null) return;
            var tinted = level != Level.Normal;
            var fill = tinted ? palette.Of(level) : palette.Card;
            var ink = tinted ? Palette.Hex(0x1B1B1B) : palette.Text;
            using (var path = Rounded(box, 5 * s))
            using (var brush = new SolidBrush(fill))
            {
                g.FillPath(brush, path);
                if (!tinted)
                    using (var line = new Pen(palette.CardLine)) g.DrawPath(line, path);
            }
            var size = TextRenderer.MeasureText(g, value, smallBold, Size.Empty, TextFormatFlags.NoPadding);
            var iconSize = P(15);
            var total = iconSize + P(5) + size.Width;
            var x = box.X + (box.Width - total) / 2;
            Glyphs.Draw(g, icon, new RectangleF(x, box.Y + (box.Height - iconSize) / 2f, iconSize, iconSize), ink);
            Say(g, value, smallBold, ink, new Rectangle(x + iconSize + P(5), box.Y, size.Width + P(4), box.Height));
        }

        // One app's row: its icon and name, its CPU share and memory, then the tortoise and the moon for the person's own
        private void AppRow(Graphics g, AppGroup app, int y, int pad, int w)
        {
            var isIdled = tray.IsIdled(app.Key);
            var isCapped = tray.Capped.Any(c => c.Id == app.Key);
            var target = app;
            Picture(g, AppIcons.Of(app.Exe), Icons.App, new Rectangle(pad, y + P(5), P(16), P(16)));
            var buttons = app.Mine ? P(56) : 0;
            var figures = P(118);
            var right = w - pad - buttons;
            Say(g, app.Name, body, palette.Text, new Rectangle(pad + P(24), y, right - figures - pad - P(28), P(26)));
            var fx = right - figures;
            Glyphs.Draw(g, Icons.Gauge, new RectangleF(fx, y + P(6), P(14), P(14)), palette.Sub);
            Say(g, isIdled ? "Idled" : Format.Percent(app.Cpu), small, palette.Text, new Rectangle(fx + P(17), y, P(38), P(26)));
            Glyphs.Draw(g, Icons.Memory, new RectangleF(fx + P(56), y + P(6), P(14), P(14)), palette.Sub);
            Say(g, Format.Gigabytes(app.Memory), small, palette.Text, new Rectangle(fx + P(73), y, P(46), P(26)));
            if (!app.Mine) return;
            IconButton(g, Icons.Turtle, new Rectangle(w - pad - P(54), y + P(1), P(24), P(24)), isCapped,
                () => { if (isCapped) tray.Uncap(target.Key); else tray.Cap(target); });
            IconButton(g, Icons.Moon, new Rectangle(w - pad - P(26), y + P(1), P(24), P(24)), isIdled, () => tray.ToggleIdle(target));
        }

        private void Picture(Graphics g, Bitmap picture, string fallback, Rectangle box)
        {
            if (g == null) return;
            if (picture != null) g.DrawImage(picture, box);
            else Glyphs.Draw(g, fallback, box, palette.Sub);
        }

        // an icon that acts, red while its state is on, with the hover's tint behind it
        private void IconButton(Graphics g, string icon, Rectangle box, bool on, Action act)
        {
            Row(box, act);
            if (g == null) return;
            if (hover != null && hover.Box == box)
                using (var path = Rounded(box, 4 * s))
                using (var tint = new SolidBrush(palette.Hover))
                    g.FillPath(tint, path);
            var inset = P(3);
            Glyphs.Draw(g, icon, new RectangleF(box.X + inset, box.Y + inset, box.Width - 2 * inset, box.Height - 2 * inset), on ? palette.Red : palette.Text);
        }

        private void SwitchRow(Graphics g, string text, bool on, bool enabled, Action act, int y, int pad, int w)
        {
            var row = new Rectangle(0, y, w, P(30));
            if (enabled) Row(row, act);
            Hovered(g, row);
            Say(g, text, body, enabled ? palette.Text : palette.Sub, new Rectangle(pad, y, w - 2 * pad - P(56), P(30)));
            Switch(g, new Rectangle(w - pad - P(40), y + P(5), P(40), P(20)), on);
        }

        private int AlertRow(Graphics g, string name, string switchKey, string lineKey, double low, double high, double step, Func<double, string> label, int y, int pad, int w)
        {
            var on = Store.Bool(switchKey);
            var value = Store.Num(lineKey);
            var shown = dragging != null && dragging.Id == "alert:" + lineKey ? dragging.Value : value;
            var switchBox = new Rectangle(w - pad - P(40), y + P(5), P(40), P(20));
            Row(new Rectangle(switchBox.X - P(4), y, switchBox.Width + P(8), P(30)), () => tray.SetSwitch(switchKey, !on));
            Say(g, name, body, palette.Text, new Rectangle(pad, y, P(104), P(30)));
            Say(g, label(shown), small, on ? palette.Text : palette.Sub, new Rectangle(switchBox.X - P(52), y, P(44), P(30)), TextFormatFlags.Right);
            AddSlider(g, "alert:" + lineKey, new Rectangle(pad + P(108), y + P(13), switchBox.X - P(60) - pad - P(108), P(4)), low, high, step, value, on,
                (v, final) => { if (final) tray.SetLine(lineKey, v); else Store.Set(lineKey, v); });
            Switch(g, switchBox, on);
            return y + P(30);
        }

        // a slider with its icon at the left and its value at the right
        private void SliderRow(Graphics g, string id, string icon, Rectangle box, double low, double high, double step, double value, bool enabled, Func<double, string> label, Action<double, bool> change)
        {
            var shown = dragging != null && dragging.Id == id ? dragging.Value : value;
            Glyphs.Draw(g, icon, new RectangleF(box.X, box.Y + (box.Height - P(14)) / 2f, P(14), P(14)), palette.Sub);
            Say(g, label(shown), small, enabled ? palette.Text : palette.Sub, new Rectangle(box.Right - P(44), box.Y, P(44), box.Height), TextFormatFlags.Right);
            AddSlider(g, id, new Rectangle(box.X + P(22), box.Y + box.Height / 2 - P(2), box.Width - P(22) - P(52), P(4)), low, high, step, value, enabled, change);
        }

        // Drawing

        private void Row(Rectangle box, Action act) => hits.Add(new Hit { Box = box, Act = act });

        private void Hovered(Graphics g, Rectangle row)
        {
            if (g != null && hover != null && hover.Box == row)
                using (var tint = new SolidBrush(palette.Hover))
                    g.FillRectangle(tint, row);
        }

        private void Say(Graphics g, string text, Font font, Color colour, Rectangle box, TextFormatFlags extra = 0)
        {
            if (g == null || string.IsNullOrEmpty(text)) return;
            var flags = TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | extra;
            TextRenderer.DrawText(g, text, font, box, colour, flags);
        }

        // a row that acts, in the accent colour, with the hover's tint across the panel
        private void Link(Graphics g, string text, Rectangle box, Action act)
        {
            var row = new Rectangle(0, box.Y, (int)(Width0 * s), box.Height);
            Row(row, act);
            Hovered(g, row);
            Say(g, text, body, palette.Accent, box);
        }

        private void AddSlider(Graphics g, string id, Rectangle track, double low, double high, double step, double value, bool enabled, Action<double, bool> change)
        {
            var v = dragging != null && dragging.Id == id ? dragging.Value : value;
            if (enabled) sliders.Add(new Slider { Id = id, Box = track, Low = low, High = high, Step = step, Value = v, Change = change });
            if (g == null) return;
            var t = (float)((v - low) / Math.Max(1e-9, high - low));
            var r = track.Height / 2f;
            using (var path = Rounded(track, r))
            using (var back = new SolidBrush(palette.Track))
                g.FillPath(back, path);
            var fillW = Math.Max(track.Height, (int)(track.Width * t));
            using (var path = Rounded(new Rectangle(track.X, track.Y, fillW, track.Height), r))
            using (var fill = new SolidBrush(enabled ? palette.Accent : palette.Sub))
                g.FillPath(fill, path);
            var knob = 14 * s;
            var kx = track.X + track.Width * t - knob / 2;
            var ky = track.Y + track.Height / 2f - knob / 2;
            using (var outer = new SolidBrush(palette.Card))
                g.FillEllipse(outer, kx, ky, knob, knob);
            using (var ring = new Pen(palette.CardLine, Math.Max(1, s)))
                g.DrawEllipse(ring, kx, ky, knob, knob);
            using (var dot = new SolidBrush(enabled ? palette.Accent : palette.Sub))
                g.FillEllipse(dot, kx + knob * 0.28f, ky + knob * 0.28f, knob * 0.44f, knob * 0.44f);
        }

        private void Switch(Graphics g, Rectangle box, bool on)
        {
            if (g == null) return;
            var r = box.Height / 2f;
            using (var path = Rounded(box, r))
            {
                if (on)
                    using (var fill = new SolidBrush(palette.Accent)) g.FillPath(fill, path);
                else
                    using (var line = new Pen(palette.Sub, Math.Max(1, s))) g.DrawPath(line, path);
            }
            var knob = box.Height * (on ? 0.6f : 0.5f);
            var kx = on ? box.Right - box.Height / 2f - knob / 2 : box.X + box.Height / 2f - knob / 2;
            var ky = box.Y + (box.Height - knob) / 2f;
            using (var k = new SolidBrush(on ? (Palette.AppsLight ? Color.White : Color.Black) : palette.Sub))
                g.FillEllipse(k, kx, ky, knob, knob);
        }

        private void Rule(Graphics g, int y, int w, int inset = 0)
        {
            if (g == null) return;
            using (var line = new Pen(palette.Line))
                g.DrawLine(line, inset, y, w - inset, y);
        }

        private static GraphicsPath Rounded(Rectangle box, float r)
        {
            var d = Math.Min(2 * r, Math.Min(box.Width, box.Height));
            var path = new GraphicsPath();
            if (d <= 0)
            {
                path.AddRectangle(box);
                return path;
            }
            path.AddArc(box.X, box.Y, d, d, 180, 90);
            path.AddArc(box.Right - d, box.Y, d, d, 270, 90);
            path.AddArc(box.Right - d, box.Bottom - d, d, d, 0, 90);
            path.AddArc(box.X, box.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                body?.Dispose(); bold?.Dispose(); small?.Dispose(); smallBold?.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
