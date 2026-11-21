using System;

namespace Culpmit
{
    // Keep awake, the Mac's: idle sleep held off while the switch is on, so the PC sleeps only when told to; closing a
    // laptop's lid still sleeps it, and the display still dims by its own timer. On battery under 20% it lets go, so a
    // flat battery never ends the day. Windows ties the hold to the thread that set it, so the tray's UI thread holds it.
    internal sealed class Awake
    {
        private bool holding;

        public static bool OnBatteryLow
        {
            get
            {
                if (!Native.GetSystemPowerStatus(out var s)) return false;
                // ACLineStatus 0 is battery; 255 for the percent means unknown
                return s.ACLineStatus == 0 && s.BatteryLifePercent != 255 && s.BatteryLifePercent < 20;
            }
        }

        // called each tick from the UI thread: holds while wanted and the battery allows, lets go otherwise
        public void Apply(bool wanted)
        {
            var hold = wanted && !OnBatteryLow;
            if (hold == holding) return;
            holding = hold;
            Native.SetThreadExecutionState(hold ? Native.EsContinuous | Native.EsSystemRequired : Native.EsContinuous);
            Log.Note(hold ? "keep awake: holding" : wanted ? "keep awake: let go, battery under 20%" : "keep awake: off");
        }

        public bool Holding => holding;

        public void Release() => Apply(false);
    }
}
