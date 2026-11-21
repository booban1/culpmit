using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace Culpmit
{
    // The panel a click on the tray icon opens: the Mac menu's rows in the desktop's own controls. Performance with
    // Culpmit's icon, the readings as tiles that take their level's colour, the app rows (each app's icon, its CPU share
    // and memory, the tortoise to cap and the moon to idle, red while on), the capped apps in two rows each (name, use
    // and switch; then the cap and the memory line side by side), Keep awake and Open at login, the alerts as one row
    // each (line, value, switch), Remove and Quit. A right click on a capped app removes it, as Option does on the Mac.
    // Each tick updates its figures in place; the rows rebuild only when the set of rows changes, and never while a
    // pointer is down on it, so a drag keeps its slider. It opens beside the tray point the host names (on X11; Wayland
    // places it itself) and closes as it loses focus. Light or dark follows the desktop.
    internal sealed class Panel : Window
    {
        private readonly Controller owner;
        private readonly StackPanel rows = new StackPanel { Spacing = 4, Margin = new Thickness(14, 12, 14, 10) };
        private readonly ScrollViewer scroller;
        private bool pressed;
        private string shape = "";
        private DateTime shownAt = DateTime.MinValue;
        private readonly List<Action> updaters = new List<Action>();
        private const double Width0 = 380;

        public Panel(Controller owner)
        {
            this.owner = owner;
            Title = "Culpmit";
            Width = Width0;
            SizeToContent = SizeToContent.Height;
            CanResize = false;
            ShowInTaskbar = false;
            Topmost = true;
            WindowDecorations = WindowDecorations.None;
            scroller = new ScrollViewer { Content = rows, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
            Content = new Border
            {
                BorderThickness = new Thickness(1),
                BorderBrush = Brush(0x80808080),
                CornerRadius = new CornerRadius(8),
                Child = scroller,
            };
            // the window manager's first focus pass after a show can read as a loss of focus: the panel stays put then
            Deactivated += (s, e) => { if ((DateTime.UtcNow - shownAt).TotalMilliseconds > 700) Hide(); };
            KeyDown += (s, e) => { if (e.Key == Key.Escape) Hide(); };
            AddHandler(PointerPressedEvent, (s, e) => pressed = true, RoutingStrategies.Tunnel, true);
            AddHandler(PointerReleasedEvent, (s, e) => Dispatcher.UIThread.Post(() => pressed = false), RoutingStrategies.Tunnel, true);
        }

        public void ShowNear(int x, int y)
        {
            var screen = x > 0 || y > 0 ? Screens.ScreenFromPoint(new PixelPoint(Math.Min(x, 100000), Math.Min(y, 100000))) ?? Screens.Primary : Screens.Primary;
            var area = screen?.WorkingArea ?? new PixelRect(0, 0, 1920, 1080);
            var scale = screen?.Scaling ?? 1;
            MaxHeight = area.Height / scale - 24;
            Build();
            shownAt = DateTime.UtcNow;
            if (x > 0 || y > 0)
            {
                if (x == int.MaxValue) x = area.Right;
                if (y == int.MaxValue) y = area.Bottom;
                var w = (int)(Width0 * scale);
                // measured before it maps, so it opens in its place
                var content = (Control)Content;
                content.Measure(new Size(Width0, MaxHeight));
                var h = (int)(Math.Min(content.DesiredSize.Height, MaxHeight) * scale);
                // above a bottom panel, below a top one, inside the screen's edges
                var left = Math.Max(area.X + 6, Math.Min(x - w / 2, area.Right - w - 6));
                var top = y > area.Y + area.Height / 2 ? area.Bottom - h - 6 : area.Y + 6;
                WindowStartupLocation = WindowStartupLocation.Manual;
                Position = new PixelPoint(left, top);
                Show();
                // a second pass with the real height, once laid out
                var real = (int)(Bounds.Height * scale);
                if (real > 0 && real != h && y > area.Y + area.Height / 2) Position = new PixelPoint(left, area.Bottom - real - 6);
            }
            else
            {
                WindowStartupLocation = WindowStartupLocation.CenterScreen;
                Show();
            }
            Activate();
        }

        public void Redraw()
        {
            if (!IsVisible || pressed) return;
            if (Shape() != shape) Build();
            else foreach (var update in updaters) update();
        }

        // the rows the panel holds, apart from their figures
        private string Shape()
        {
            var listed = owner.Rows.Select(g => g.Key + (owner.IsIdled(g.Key) ? "~" : "") + (owner.Capped.Any(c => c.Id == g.Key) ? "^" : ""));
            var capped = owner.Capped.Select(c => c.Id + (c.On ? "+" : "-") + (owner.GroupOf(c.Id) == null ? "x" : ""));
            var switches = new[] { "cpuAlerts", "memoryAlerts", "heatAlerts", "keepAwake" }.Select(k => Store.Bool(k) ? "1" : "0");
            return string.Join(",", listed) + "|" + string.Join(",", capped) + "|" + string.Join("", switches) + (owner.HasHeat ? "h" : "")
                + (owner.Fans.Count > 0 ? "f" : "") + (Install.OpenAtLogin ? "l" : "") + (Sensors.OnBatteryLow ? "b" : "");
        }

        private static IBrush Brush(uint argb) => new SolidColorBrush(Color.FromUInt32(argb));
        private static readonly IBrush Orange = Brush(0xFFF7630C);
        private static readonly IBrush Red = Brush(0xFFD13438);
        private static readonly IBrush DarkInk = Brush(0xFF1B1B1B);

        private bool IsDark => ActualThemeVariant == Avalonia.Styling.ThemeVariant.Dark;
        private IBrush Sub => Brush(IsDark ? 0xFFA0A0A0u : 0xFF6E6E73u);
        private IBrush CardBack => Brush(IsDark ? 0xFF2C2C2Eu : 0xFFF2F2F5u);
        private IBrush OnRed => Brush(IsDark ? 0xFFFF6B7Au : 0xFFD13438u);
        private IBrush Of(Level level) => level == Level.Hot ? Red : level == Level.Warm ? Orange : null;

        private TextBlock Say(string text, double size = 13, IBrush brush = null, FontWeight weight = FontWeight.Normal)
        {
            var block = new TextBlock { Text = text, FontSize = size, FontWeight = weight, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
            if (brush != null) block.Foreground = brush;
            return block;
        }

        // a line of figures that follows each tick
        private TextBlock Live(Func<string> text, double size = 12, IBrush brush = null)
        {
            var block = Say(text(), size, brush);
            updaters.Add(() => block.Text = text());
            return block;
        }

        private static PathIcon Glyph(string data, double size = 14, IBrush brush = null)
        {
            var icon = new PathIcon { Data = StreamGeometry.Parse("F1 " + data), Width = size, Height = size, VerticalAlignment = VerticalAlignment.Center };
            if (brush != null) icon.Foreground = brush;
            return icon;
        }

        // an app's own icon, else the generic app icon
        private Control AppPicture(string exe)
        {
            var picture = AppIcons.Picture(owner.IconFileOf(exe));
            if (picture != null) return new Image { Source = picture, Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center };
            return Glyph(Icons.App, 16, Sub);
        }

        private Control Link(string text, Action act, string right = null)
        {
            var content = new DockPanel();
            if (right != null)
            {
                var r = Say(right, 11, Sub);
                DockPanel.SetDock(r, Dock.Right);
                content.Children.Add(r);
            }
            content.Children.Add(new TextBlock { Text = text, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
            var b = new Button { Content = content, Padding = new Thickness(6, 4), Background = Brushes.Transparent, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            b.Click += (s, e) => act();
            return b;
        }

        // an icon that acts, red while its state is on
        private Button IconButton(string data, bool on, string tip, Action act)
        {
            var b = new Button
            {
                Content = Glyph(data, 18, on ? OnRed : null), Padding = new Thickness(4), Background = Brushes.Transparent,
                BorderThickness = new Thickness(0), VerticalAlignment = VerticalAlignment.Center,
            };
            ToolTip.SetTip(b, tip);
            b.Click += (s, e) => act();
            return b;
        }

        private ToggleSwitch Toggle(bool on, bool enabled, Action<bool> set)
        {
            var toggle = new ToggleSwitch { IsChecked = on, IsEnabled = enabled, OnContent = null, OffContent = null, MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
            toggle.IsCheckedChanged += (s, e) => set(toggle.IsChecked == true);
            return toggle;
        }

        private static Grid Columns(string definition, params Control[] children)
        {
            var grid = new Grid { ColumnDefinitions = new ColumnDefinitions(definition) };
            for (var i = 0; i < children.Length; i++)
            {
                if (children[i] == null) continue;
                Grid.SetColumn(children[i], i);
                grid.Children.Add(children[i]);
            }
            return grid;
        }

        // a slider; a drag changes the value live, its release keeps it
        private Slider MakeSlider(double low, double high, double step, double value, bool enabled, Action<double, bool> change, TextBlock shown, Func<double, string> label)
        {
            var slider = new Slider
            {
                Minimum = low, Maximum = high, Value = value, TickFrequency = step, IsSnapToTickEnabled = true,
                IsEnabled = enabled, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, -8),
            };
            slider.PropertyChanged += (s, e) =>
            {
                if (e.Property != RangeBase.ValueProperty) return;
                shown.Text = label(slider.Value);
                change(slider.Value, false);
            };
            slider.AddHandler(PointerReleasedEvent, (s, e) => change(slider.Value, true), RoutingStrategies.Tunnel, true);
            slider.AddHandler(PointerCaptureLostEvent, (s, e) => change(slider.Value, true), RoutingStrategies.Bubble, true);
            slider.KeyUp += (s, e) => change(slider.Value, true);
            return slider;
        }

        private static Control Heading(string text) =>
            new TextBlock { Text = text, FontSize = 13, FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 4, 0, 2) };

        private Control Rule() => new Border { Height = 1, Background = Brush(IsDark ? 0x30FFFFFFu : 0x22000000u), Margin = new Thickness(-14, 4) };

        // A reading's tile: its icon and value, in its level's colour with dark ink once past its line, as on the Mac
        private Control Tile(string icon, Func<(string Value, Level Level)> read)
        {
            var glyph = Glyph(icon, 15);
            var text = Say("", 12, null, FontWeight.SemiBold);
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, HorizontalAlignment = HorizontalAlignment.Center };
            line.Children.Add(glyph);
            line.Children.Add(text);
            var tile = new Border { CornerRadius = new CornerRadius(5), Height = 30, Child = line };
            void Update()
            {
                var r = read();
                text.Text = r.Value;
                if (Of(r.Level) is IBrush tint)
                {
                    tile.Background = tint;
                    text.Foreground = DarkInk;
                    glyph.Foreground = DarkInk;
                }
                else
                {
                    tile.Background = CardBack;
                    text.ClearValue(TextBlock.ForegroundProperty);
                    glyph.ClearValue(TemplatedControl.ForegroundProperty);
                }
            }
            Update();
            updaters.Add(Update);
            return tile;
        }

        private void Build()
        {
            rows.Children.Clear();
            updaters.Clear();
            shape = Shape();
            var now = owner.Now;

            // Performance, with Culpmit's own icon at the right
            var own = AppIcons.Own();
            Control mark = own != null ? new Image { Source = own, Width = 16, Height = 16 } : null;
            if (mark != null) ToolTip.SetTip(mark, "Culpmit " + Program.Version);
            rows.Children.Add(Columns("*,Auto", Say("Performance", 13, null, FontWeight.SemiBold), mark));

            // the readings as tiles: temperature where the kernel names a CPU sensor, the faster fan, CPU, memory
            var tiles = new List<Control>();
            if (owner.HasHeat)
                tiles.Add(Tile(Icons.Temperature, () => (Format.Degrees(owner.Temperature ?? 0), Levels.Temperature(owner.Temperature, Levels.HeatLine))));
            if (owner.Fans.Count > 0)
                tiles.Add(Tile(Icons.Fan, () => (((int)(owner.Fans.Count > 0 ? owner.Fans.Max() : 0)).ToString() + " rpm", Levels.Temperature(owner.Temperature, Levels.HeatLine))));
            tiles.Add(Tile(Icons.Gauge, () => (Format.Percent(owner.Now.Load), Levels.Load(owner.Now.Load, Levels.CpuLine))));
            tiles.Add(Tile(Icons.Memory, () => (Format.Gigabytes(owner.Now.MemoryUsed).Replace(" GB", "") + "/" + Format.WholeGigabytes(owner.Now.MemoryTotal), owner.MemoryLevel)));
            var grid = new Grid { Margin = new Thickness(0, 4, 0, 2) };
            for (var i = 0; i < tiles.Count; i++)
            {
                grid.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
                tiles[i].Margin = new Thickness(i == 0 ? 0 : 3, 0, i == tiles.Count - 1 ? 0 : 3, 0);
                Grid.SetColumn(tiles[i], i);
                grid.Children.Add(tiles[i]);
            }
            rows.Children.Add(grid);
            rows.Children.Add(Rule());

            // the app rows: idled, busy, then the heaviest three, each with the tortoise and the moon
            rows.Children.Add(Heading("Busy apps"));
            if (owner.Rows.Count == 0) rows.Children.Add(Say("Every app is calm", 12, Sub));
            foreach (var app in owner.Rows) rows.Children.Add(AppRow(app));
            rows.Children.Add(Rule());

            // the capped apps: two rows each, name, use and switch, then the cap and the memory line
            if (owner.Capped.Count > 0)
            {
                rows.Children.Add(Heading("Capped apps"));
                foreach (var c in owner.Capped.ToList()) rows.Children.Add(CappedRows(c, now));
                rows.Children.Add(Rule());
            }

            // keep awake and open at login
            var awakeOn = Store.Bool("keepAwake");
            rows.Children.Add(Columns("*,Auto", Say(Sensors.OnBatteryLow && awakeOn ? "Keep awake · let go, battery under 20%" : "Keep awake"),
                Toggle(awakeOn, true, v => owner.SetSwitch("keepAwake", v))));
            rows.Children.Add(Columns("*,Auto", Say("Open at login", 13, Install.IsInstalledCopy ? null : Sub),
                Toggle(Install.OpenAtLogin, Install.IsInstalledCopy, v => owner.SetOpenAtLogin(v))));
            rows.Children.Add(Rule());

            // the alerts, one row each: name, line, value, switch
            AlertRow("CPU alerts", "cpuAlerts", "cpuLine", Levels.CpuRange[0], Levels.CpuRange[1], 5, v => Format.Percent(v));
            AlertRow("Memory alerts", "memoryAlerts", "memoryAlertLine", Levels.MemoryRange[0], Levels.MemoryRange[1], 0.05, v => Format.Percent(v * 100));
            if (owner.HasHeat)
                AlertRow("Heat alerts", "heatAlerts", "heatLine", Levels.HeatRange[0], Levels.HeatRange[1], 5, v => Format.Degrees(v));
            rows.Children.Add(Rule());

            if (Install.IsInstalledCopy) rows.Children.Add(Link("Remove Culpmit…", ConfirmRemove));
            rows.Children.Add(Link("Quit Culpmit", () => owner.Quit(), Program.Version));
        }

        // One app's row: its icon and name, its CPU share and memory, then the tortoise and the moon for the person's own
        private Control AppRow(AppGroup app)
        {
            var key = app.Key;
            var isIdled = owner.IsIdled(key);
            var isCapped = owner.Capped.Any(c => c.Id == key);
            var name = Say(app.Name);
            name.Margin = new Thickness(8, 0);
            var cpu = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3, Width = 54 };
            cpu.Children.Add(Glyph(Icons.Gauge, 14, Sub));
            cpu.Children.Add(Live(() => isIdled ? "Idled" : Format.Percent((owner.GroupOf(key) ?? app).Cpu)));
            var memory = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3, Width = 66 };
            memory.Children.Add(Glyph(Icons.Memory, 14, Sub));
            memory.Children.Add(Live(() => Format.Gigabytes((owner.GroupOf(key) ?? app).Memory)));
            Control turtle = null, moon = null;
            if (app.Mine)
            {
                var target = app;
                turtle = IconButton(Icons.Turtle, isCapped, isCapped ? "Uncap" : "Cap", () => { if (isCapped) owner.Uncap(key); else owner.Cap(target); });
                moon = IconButton(Icons.Moon, isIdled, isIdled ? "Wake" : "Idle", () => owner.ToggleIdle(target));
            }
            var row = Columns("Auto,*,Auto,Auto,Auto,Auto", AppPicture(app.Exe), name, cpu, memory, turtle, moon);
            row.MinHeight = 28;
            return row;
        }

        private Control CappedRows(CappedApp c, Snapshot now)
        {
            var id = c.Id;
            var on = c.On;
            var app = owner.GroupOf(id);
            var name = Say(c.Name, 13, on ? null : Sub);
            name.Margin = new Thickness(8, 0);
            var use = Live(() =>
            {
                var g = owner.GroupOf(id);
                return g == null ? "Closed" : (owner.IsIdled(id) ? "Idled" : Format.Percent(g.Cpu)) + " · " + Format.Gigabytes(g.Memory);
            }, 12, Sub);
            use.Margin = new Thickness(0, 0, 8, 0);
            var top = Columns("Auto,*,Auto,Auto", AppPicture(app?.Exe ?? c.Exe), name, use, Toggle(on, true, v => owner.SetCapOn(id, v)));

            // the cap, 5% to 80% of the machine, and the memory line in GB, side by side
            var capText = Say(Format.Percent(c.Level * 100), 12, on ? null : Sub);
            capText.Width = 38;
            capText.TextAlignment = TextAlignment.Right;
            var capSlider = MakeSlider(Caps.Low, Caps.High, Caps.Step, c.Level, on, (v, final) => owner.SetCap(id, v, final), capText, v => Format.Percent(v * 100));
            var range = Caps.LineRange(now.MemoryTotal);
            var lineGb = Caps.LineOf(c, now.MemoryTotal);
            var lineText = Say(Format.WholeGigabytes(lineGb * Format.Gib), 12, on ? null : Sub);
            lineText.Width = 44;
            lineText.TextAlignment = TextAlignment.Right;
            var lineSlider = MakeSlider(range[0], range[1], 1, lineGb, on, (v, final) => owner.SetMemoryLine(id, v, final), lineText, v => Format.WholeGigabytes(v * Format.Gib));
            var bottom = Columns("Auto,*,Auto,16,Auto,*,Auto", Glyph(Icons.Gauge, 14, Sub), capSlider, capText, null, Glyph(Icons.Memory, 14, Sub), lineSlider, lineText);

            var stack = new StackPanel { Spacing = 2, Background = Brushes.Transparent, Margin = new Thickness(0, 2) };
            stack.Children.Add(top);
            stack.Children.Add(bottom);
            var remove = new MenuItem { Header = "Remove from Capped apps" };
            remove.Click += (s, e) => owner.Uncap(id);
            stack.ContextMenu = new ContextMenu { ItemsSource = new[] { remove } };
            return stack;
        }

        private void AlertRow(string name, string switchKey, string lineKey, double low, double high, double step, Func<double, string> label)
        {
            var on = Store.Bool(switchKey);
            var value = Store.Num(lineKey);
            var title = Say(name);
            title.Width = 108;
            var shown = Say(label(value), 12, on ? null : Sub);
            shown.Width = 44;
            shown.TextAlignment = TextAlignment.Right;
            var slider = MakeSlider(low, high, step, value, on, (v, final) => { if (final) owner.SetLine(lineKey, v); else Store.Set(lineKey, v); }, shown, label);
            var toggle = Toggle(on, true, v => owner.SetSwitch(switchKey, v));
            toggle.Margin = new Thickness(8, 0, 0, 0);
            rows.Children.Add(Columns("Auto,*,Auto,Auto", title, slider, shown, toggle));
        }

        // one question first, as the Windows panel's dialog asks it
        private void ConfirmRemove()
        {
            Hide();
            var ask = new Window
            {
                Title = "Remove Culpmit?", Width = 380, SizeToContent = SizeToContent.Height, CanResize = false,
                WindowStartupLocation = WindowStartupLocation.CenterScreen,
            };
            var text = new TextBlock { Text = "Every cap lifts, Open at login ends, and the menu entry and ~/.local/bin/culpmit go.", TextWrapping = TextWrapping.Wrap };
            var cancel = new Button { Content = "Cancel" };
            var remove = new Button { Content = "Remove" };
            cancel.Click += (s, e) => ask.Close();
            remove.Click += (s, e) => { ask.Close(); owner.Remove(); };
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
            buttons.Children.Add(cancel);
            buttons.Children.Add(remove);
            var stack = new StackPanel { Spacing = 14, Margin = new Thickness(18) };
            stack.Children.Add(text);
            stack.Children.Add(buttons);
            ask.Content = stack;
            ask.Show();
        }
    }
}
