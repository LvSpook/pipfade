#Requires -Version 5.1
<#
  pipfade - see-through mini player for Brave / Chrome / Edge on Windows

  The mini player is a native window, not a web page, so no extension or
  userscript can reach it. This drives it from the OS instead: the window is made
  layered and given an alpha, so whatever is behind it shows through.

  It also remembers each player's size and position, reapplies your opacity
  automatically whenever a mini player opens, and can keep the player above
  fullscreen applications.

  A new player is picked up from a window event rather than a timer, so the
  saved look is applied the instant it appears. A one-second sweep runs behind
  that as a backstop.

    .\pipfade.ps1                 open the panel and keep watching
    .\pipfade.ps1 -Tray           start hidden in the tray
    .\pipfade.ps1 -List           list detected mini players, then exit
    .\pipfade.ps1 -Reset          put everything back to normal, then exit
    .\pipfade.ps1 -Alpha 170      set opacity now, then exit
    .\pipfade.ps1 -Hwnd 0x1A2B3C  target one specific window handle
#>
param(
    [int]$Alpha = -1,
    [switch]$List,
    [switch]$Reset,
    [switch]$Tray,
    [string]$Hwnd = ''
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is the script's folder when run as a file. Dot-sourced helpers
# (tests, the panel snapshot script) override these two right after loading.
$script:Root       = $PSScriptRoot
if (-not $script:Root) { $script:Root = (Get-Location).Path }
$script:ConfigPath = Join-Path $script:Root 'pipfade.config.json'

$MIN_ALPHA = 40      # never fully invisible: you would have no way to grab it
$MAX_ALPHA = 255
# How many preset rows the presets tab has room for. Kept here as well as in the
# UI assembly because the runtime needs the same ceiling for validation, and the
# two must not drift apart.
$script:MaxPresets = 4

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# ----------------------------------------------------------------- native side
if (-not ('PipFade.Win' -as [type])) {
Add-Type -ReferencedAssemblies 'System', 'System.Drawing', 'System.Windows.Forms' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace PipFade
{
    public static class Win
    {
        public delegate bool EnumProc(IntPtr h, IntPtr l);
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
        [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr h, uint k, byte a, uint f);
        [DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
        [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
        [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);

        // A hidden console and a powershell.exe executable with no icon of its
        // own means the shell groups this window under PowerShell and draws the
        // PowerShell icon on its button, whatever the window's own Icon says.
        // An explicit AppUserModelID gives the process its own taskbar identity,
        // and only then does the shell draw the icon the window actually sets.
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        // Hiding a player is a ShowWindow call, not a style change: the window
        // keeps its handle, geometry and stream, so showing it again is instant.
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        // RegisterHotKey only reports presses, so hold-to-hide has to ask whether
        // the key is still down.
        [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);

        // Per-pixel layering: lets the hover bar draw only its own controls with
        // true transparency instead of painting a card over the video.
        [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int CX, CY; public SIZE(int w, int h) { CX = w; CY = h; } }
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        public struct BLENDFUNCTION
        {
            public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat;
        }

        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
        [DllImport("user32.dll")]
        public static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dstDc, ref POINT dst,
            ref SIZE size, IntPtr srcDc, ref POINT src, int colorKey, ref BLENDFUNCTION blend, int flags);

        public delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd,
                                          int idObject, int idChild, uint thread, uint time);

        [DllImport("user32.dll")]
        public static extern IntPtr SetWinEventHook(uint evMin, uint evMax, IntPtr mod,
            WinEventProc cb, uint pid, uint tid, uint flags);
        [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("user32.dll")] public static extern uint MsgWaitForMultipleObjects(
            uint count, IntPtr handles, bool waitAll, uint millis, uint mask);
        [DllImport("user32.dll")] public static extern uint GetQueueStatus(uint flags);

        // GetQueueStatus answers "input" for flags a dispatched message already
        // consumed, so it says yes to an empty queue. PeekMessage is the authority
        // on whether there is something to dispatch, and PM_NOREMOVE leaves it in
        // place for the DoEvents that follows.
        [StructLayout(LayoutKind.Sequential)]
        public struct MSG
        {
            public IntPtr hwnd; public uint message; public IntPtr wParam, lParam;
            public uint time; public int x, y;
        }
        public const uint PM_NOREMOVE = 0x0000;
        [DllImport("user32.dll")]
        public static extern bool PeekMessage(out MSG msg, IntPtr hwnd, uint min, uint max, uint remove);

        // The idle wait, in one call. Every marshalled call made from PowerShell
        // costs around half a millisecond before the p/invoke itself is even
        // reached, and the old wait made several per tick - more than the work
        // the tick existed to do. Looping here means the resident loop makes one
        // call per pass and pays that cost once.
        //
        // The phantom guard is kept: MsgWait can report input while the queue is
        // genuinely empty (a sent message, or one already handled), and
        // re-waiting inside C# for the rest of the budget costs nothing.
        public static bool WaitMessages(uint millis) {
            const uint QS_INPUT = 0x04BF;
            int end = Environment.TickCount + (int)millis;
            int phantoms = 0;
            while (true) {
                int left = end - Environment.TickCount;
                if (left <= 0) return false;
                MsgWaitForMultipleObjects(0, IntPtr.Zero, false, (uint)left, QS_INPUT);
                if ((GetQueueStatus(QS_INPUT) & 0xFFFF) != 0) return true;
                phantoms++;
                // After the second empty wake-up the wait is not trustworthy, so
                // sleep out the budget instead of asking again: sleeping is what
                // the wait was for and it cannot spin.
                if (phantoms >= 2) {
                    System.Threading.Thread.Sleep(Math.Max(1, left));
                    return false;
                }
            }
        }

        // The idle wait for the resident loop, with the pointer watch folded in.
        //
        // An idle pass is not free in PowerShell: the loop body marshals dozens
        // of small calls, so at four passes a second the deciding-that-nothing-
        // happened was most of this process's CPU. One native call per idle
        // period replaces the wait and the cursor test together.
        //
        // The watch is edge-triggered. It reports the pointer arriving on a
        // player and it reports it leaving, and between those two it says
        // nothing at all - so a pointer parked on a video, which is the ordinary
        // case, costs one wake instead of one wake every 25ms forever.
        static int[] _watch = new int[0];
        static int _margin = 40;
        static bool _wasNear;

        public static void SetWatchRects(int[] rects, int margin) {
            _watch = rects != null ? rects : new int[0];
            _margin = margin;
        }

        static bool NearWatch(POINT p) {
            for (int i = 0; i + 3 < _watch.Length; i += 4) {
                if (p.X >= _watch[i] - _margin && p.X < _watch[i] + _watch[i + 2] + _margin &&
                    p.Y >= _watch[i + 1] - _margin && p.Y < _watch[i + 1] + _watch[i + 3] + _margin) return true;
            }
            return false;
        }

        public static bool IdleWait(uint millis) {
            // The whole idle period is served here, in 25ms slices, so the
            // PowerShell side pays for one call per pass instead of six.
            //
            // Sleeping rather than waiting on the message queue is deliberate:
            // MsgWaitForMultipleObjects returns within a couple of milliseconds
            // claiming input that GetQueueStatus then reports as absent, and each
            // phantom wake costs a full PowerShell loop pass - more than the sleep
            // it replaced. A sleep cannot spin, and asking the queue after it
            // still finds a real message (a hotkey, a click) within 25ms.
            //
            // PeekMessage, not GetQueueStatus, decides whether a message is real.
            // GetQueueStatus reports INPUT from flags that a dispatched message
            // already consumed, so it answers "yes" to an empty queue and the loop
            // would come back early on nearly every slice.
            int end = Environment.TickCount + (int)millis;
            MSG msg;
            while (true) {
                int left = end - Environment.TickCount;
                if (left <= 0) return false;
                System.Threading.Thread.Sleep(left < 25 ? left : 25);
                if (PeekMessage(out msg, IntPtr.Zero, 0, 0, PM_NOREMOVE)) return true;
                if (_watch.Length == 0) continue;
                POINT p;
                if (!GetCursorPos(out p)) continue;
                bool near = NearWatch(p);
                // Report the edges only: arriving, and leaving. A pointer that
                // simply stays put is not news, and repeating it woke the loop
                // every 25ms for as long as someone watched a video.
                if (near != _wasNear) { _wasNear = near; return true; }
            }
        }
    }

    // Watches for top-level windows appearing, so a new mini player is picked up
    // the moment it opens instead of on the next poll. Out-of-context hooks are
    // delivered by the message queue of the thread that installed them, which is
    // this thread, dispatched by DoEvents() in the resident loop.
    public class ShownWatcher
    {
        const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
        const uint EVENT_OBJECT_SHOW       = 0x8002;
        const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B;
        const uint OBJID_WINDOW            = 0;
        const uint WINEVENT_OUTOFCONTEXT   = 0x0000;
        const uint WINEVENT_SKIPOWNPROCESS = 0x0002;

        IntPtr _hShow = IntPtr.Zero;
        IntPtr _hFore = IntPtr.Zero;
        IntPtr _hMove = IntPtr.Zero;

        // The delegates must be held in fields: if the GC collects them while
        // Windows still holds the pointer, the process dies on the next event.
        Win.WinEventProc _cbShow;
        Win.WinEventProc _cbFore;
        Win.WinEventProc _cbMove;

        List<IntPtr> _shown = new List<IntPtr>();
        bool _foregroundMoved;
        bool _moved;
        IntPtr _movedHwnd = IntPtr.Zero;

        public bool Start()
        {
            _cbShow = delegate(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint th, uint ti)
            {
                if (obj != (int)OBJID_WINDOW || child != 0) return;
                if (hwnd == IntPtr.Zero) return;
                _shown.Add(hwnd);
            };
            _cbFore = delegate(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint th, uint ti)
            {
                _foregroundMoved = true;
            };
            // Drags and resizes arrive here. Only the window itself is interesting:
            // scroll bars and caret events would make this fire constantly.
            _cbMove = delegate(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint th, uint ti)
            {
                if (obj != (int)OBJID_WINDOW || child != 0) return;
                if (hwnd == IntPtr.Zero) return;
                _moved = true;
                _movedHwnd = hwnd;
            };

            _hShow = Win.SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW,
                IntPtr.Zero, _cbShow, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
            _hFore = Win.SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
                IntPtr.Zero, _cbFore, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
            _hMove = Win.SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE,
                IntPtr.Zero, _cbMove, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
            return _hShow != IntPtr.Zero;
        }

        // Handles shown since the last call. Bounded so a burst of windows can't
        // grow the list without limit.
        public IntPtr[] TakeShown()
        {
            if (_shown.Count == 0) return new IntPtr[0];
            IntPtr[] a = _shown.ToArray();
            _shown.Clear();
            return a;
        }

        public bool TakeForegroundMoved()
        {
            bool v = _foregroundMoved;
            _foregroundMoved = false;
            return v;
        }

        // True when some window moved or resized since the last call. The handle
        // is reported so the caller can tell whether it was a player.
        public bool TakeMoved(out IntPtr hwnd)
        {
            hwnd = _movedHwnd;
            bool v = _moved;
            _moved = false;
            _movedHwnd = IntPtr.Zero;
            return v;
        }

        public void Dispose()
        {
            if (_hShow != IntPtr.Zero) { Win.UnhookWinEvent(_hShow); _hShow = IntPtr.Zero; }
            if (_hFore != IntPtr.Zero) { Win.UnhookWinEvent(_hFore); _hFore = IntPtr.Zero; }
            if (_hMove != IntPtr.Zero) { Win.UnhookWinEvent(_hMove); _hMove = IntPtr.Zero; }
            _cbShow = null;
            _cbFore = null;
            _cbMove = null;
        }
    }

    public class PipWindow
    {
        public IntPtr Handle;
        public string Proc = "unknown";
        public string Title = "";
        public int X, Y, W, H;
        public bool ClickThrough;
    }

    public static class Finder
    {
        const int GWL_EXSTYLE = -20;
        const int WS_EX_TOPMOST = 0x8;
        const int WS_EX_TRANSPARENT = 0x20;
        const int WS_EX_LAYERED = 0x80000;

        // Detection keys off Chromium's class prefix. Exposed as a field so the
        // rule can be exercised against a stand-in window; production never
        // changes it.
        public static string ClassPrefix = "Chrome_WidgetWin";

        // A mini player is the only Chromium window that is small, always-on-top
        // and unowned. A normal browser window fails the topmost test.
        public static List<PipWindow> Find()
        {
            List<PipWindow> found = new List<PipWindow>();
            Win.EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                if (IsPlayer(h))
                {
                    PipWindow p = Describe(h);
                    if (p != null) found.Add(p);
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }

        // The whole test, usable on a single handle. The event watcher filters
        // with this so it never has to enumerate every window on the desktop.
        public static bool IsPlayer(IntPtr h)
        {
            if (h == IntPtr.Zero || !Win.IsWindow(h) || !Win.IsWindowVisible(h)) return false;

            StringBuilder cls = new StringBuilder(256);
            Win.GetClassName(h, cls, 256);
            if (!cls.ToString().StartsWith(ClassPrefix)) return false;
            if ((Win.GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOPMOST) == 0) return false;
            if (Win.GetWindow(h, 4) != IntPtr.Zero) return false;

            Win.RECT r;
            if (!Win.GetWindowRect(h, out r)) return false;
            int w = r.R - r.L, hh = r.B - r.T;
            if (w <= 80 || hh <= 80) return false;
            Screen scr = Screen.PrimaryScreen;
            if (w > (int)(scr.Bounds.Width * 0.80)) return false;
            if (hh > (int)(scr.Bounds.Height * 0.80)) return false;
            return true;
        }

        // Reads one window into a PipWindow, or null if it is no longer valid.
        public static PipWindow Describe(IntPtr h)
        {
            Win.RECT r;
            if (!Win.GetWindowRect(h, out r)) return null;
            PipWindow p = new PipWindow();
            p.Handle = h;
            p.X = r.L; p.Y = r.T; p.W = r.R - r.L; p.H = r.B - r.T;
            p.Proc = ProcOf(h);
            StringBuilder t = new StringBuilder(512);
            Win.GetWindowText(h, t, 512);
            p.Title = t.ToString();
            p.ClickThrough = (Win.GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TRANSPARENT) != 0;
            return p;
        }

        public static string ProcOf(IntPtr h)
        {
            uint pid;
            Win.GetWindowThreadProcessId(h, out pid);
            // Process.GetProcessById builds a Process object and opens a handle.
            // Describe() runs on every hover tick, so the answer is cached per
            // pid: a mini player keeps the same pid for its whole life.
            string name;
            if (_procNames.TryGetValue(pid, out name)) return name;
            try { name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; }
            catch { name = "unknown"; }
            _procNames[pid] = name;
            return name;
        }

        static readonly Dictionary<uint, string> _procNames = new Dictionary<uint, string>();

        // True for a window this very process owns: the panel, the hover strip,
        // the tray menu. None of them should ever be faded or made click-through.
        public static bool IsOurs(IntPtr h)
        {
            uint owner;
            Win.GetWindowThreadProcessId(h, out owner);
            return owner == (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
        }

        public static void ApplyAlpha(IntPtr h, int value)
        {
            if (!Win.IsWindow(h)) return;
            // Never fade a window this process owns. The control panel, the
            // hover strip and the tray menu all live here, so a stray handle
            // from a pick would otherwise make our own UI go see-through.
            if (IsOurs(h)) return;
            if (value < 40) value = 40;
            if (value > 255) value = 255;
            int ex = Win.GetWindowLong(h, GWL_EXSTYLE);
            if ((ex & WS_EX_LAYERED) == 0)
            {
                Win.SetWindowLong(h, GWL_EXSTYLE, ex | WS_EX_LAYERED);
                // Remember that the layering was ours to take away again. A
                // window Chromium had already layered for its own reasons must
                // keep its style when we are done with it.
                _faded[h] = true;
            }
            else if (!_faded.ContainsKey(h))
            {
                _faded[h] = false;
            }
            Win.SetLayeredWindowAttributes(h, 0, (byte)value, 0x2);
        }

        // Every window this process has faded, and whether we added the layered
        // style ourselves. Restoring works from this list rather than from a
        // fresh search, because a faded window can stop matching the detector -
        // it loses always-on-top, or gains an owner - and a search would then
        // skip it, leaving it translucent for good. That is exactly what "the
        // effect lingers after the program is gone" looks like.
        static readonly Dictionary<IntPtr, bool> _faded = new Dictionary<IntPtr, bool>();

        public static int FadedCount { get { return _faded.Count; } }

        // The handles currently faded, so the list can be written to disk and a
        // later run can undo a fade that outlived this one.
        public static IntPtr[] FadedHandles()
        {
            IntPtr[] list = new IntPtr[_faded.Count];
            _faded.Keys.CopyTo(list, 0);
            return list;
        }

        // Puts every window we touched back the way we found it. Returns how many
        // were actually still alive.
        public static int RestoreAll()
        {
            IntPtr[] list = new IntPtr[_faded.Count];
            _faded.Keys.CopyTo(list, 0);
            int done = 0;
            foreach (IntPtr h in list)
            {
                if (!Win.IsWindow(h)) { _faded.Remove(h); continue; }
                Restore(h);
                done++;
            }
            return done;
        }

        // Repairs a window left translucent by a previous run that was killed
        // outright, before the cleanup could run. Only a window that is still
        // layered with a part alpha is touched: a normal opaque player is left
        // completely alone, so this cannot dim a window pipfade never faded.
        public static bool RestoreStale(IntPtr h)
        {
            if (!Win.IsWindow(h)) return false;
            if (IsOurs(h)) return false;
            int ex = Win.GetWindowLong(h, GWL_EXSTYLE);
            if ((ex & WS_EX_LAYERED) == 0) return false;
            uint key; byte alpha; uint flags;
            if (!Win.GetLayeredWindowAttributes(h, out key, out alpha, out flags)) return false;
            if ((flags & 0x2) == 0) return false;          // LWA_ALPHA
            if (alpha >= 255) return false;                 // already opaque
            Restore(h);
            return true;
        }

        public static void SetClickThrough(IntPtr h, bool on)
        {
            if (!Win.IsWindow(h)) return;
            if (IsOurs(h)) return;
            int ex = Win.GetWindowLong(h, GWL_EXSTYLE);
            if (on) ex |= WS_EX_TRANSPARENT;
            else    ex &= ~WS_EX_TRANSPARENT;
            Win.SetWindowLong(h, GWL_EXSTYLE, ex);
        }

        public static void Restore(IntPtr h)
        {
            if (!Win.IsWindow(h)) return;
            int ex = Win.GetWindowLong(h, GWL_EXSTYLE);
            Win.SetWindowLong(h, GWL_EXSTYLE, ex & ~WS_EX_TRANSPARENT);

            bool ours;
            bool known = _faded.TryGetValue(h, out ours);

            if (known && !ours)
            {
                // The window was already layered when we found it - Chromium's
                // own mini player is - so only the alpha is ours to clear. Its
                // style belongs to the program that set it.
                Win.SetLayeredWindowAttributes(h, 0, 255, 0x2);
                _faded.Remove(h);
                return;
            }

            if (!known)
            {
                // No record: either already restored, or never faded at all. Only
                // touch a window that is visibly part transparent, and never take
                // a style we cannot prove we added.
                uint key; byte alpha; uint flags;
                if (!Win.GetLayeredWindowAttributes(h, out key, out alpha, out flags)) return;
                if ((flags & 0x2) == 0 || alpha >= 255) return;
                Win.SetLayeredWindowAttributes(h, 0, 255, 0x2);
                return;
            }

            Win.SetLayeredWindowAttributes(h, 0, 255, 0x2);
            ex = Win.GetWindowLong(h, GWL_EXSTYLE);
            Win.SetWindowLong(h, GWL_EXSTYLE, ex & ~WS_EX_LAYERED);
            _faded.Remove(h);
        }

        public static void Move(IntPtr h, int x, int y, int w, int hh)
        {            if (!Win.IsWindow(h)) return;
            Win.SetWindowPos(h, IntPtr.Zero, x, y, w, hh, 0x14); // NOZORDER | NOACTIVATE
        }

        // WS_EX_TOPMOST can only be granted by SetWindowPos, not SetWindowLong.
        public static bool IsTopMost(IntPtr h)
        {
            return (Win.GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
        }

        // Puts the window at the top of the topmost band without moving,
        // resizing or activating it. Z-order inside that band follows the most
        // recent raise, so this is what lifts a player back over a fullscreen
        // app that took the foreground after it opened.
        public static void Raise(IntPtr h)
        {
            if (!Win.IsWindow(h)) return;
            Win.SetWindowPos(h, new IntPtr(-1) /*HWND_TOPMOST*/, 0, 0, 0, 0,
                0x0001 | 0x0002 | 0x0010); // NOSIZE | NOMOVE | NOACTIVATE
        }

        // Hiding a player: ShowWindow keeps the handle, the geometry and the
        // video stream, so it can be brought back instantly.
        public static bool IsHidden(IntPtr h)
        {
            return Win.IsWindow(h) && !Win.IsWindowVisible(h);
        }

        public static void Hide(IntPtr h)
        {
            if (!Win.IsWindow(h)) return;
            Win.ShowWindow(h, 0); // SW_HIDE
        }

        public static void Unhide(IntPtr h)
        {
            if (!Win.IsWindow(h)) return;
            // SW_SHOWNOACTIVATE: come back without stealing focus from whatever
            // the user is doing.
            Win.ShowWindow(h, 4);
        }

        // True while a key is physically down. RegisterHotKey fires once per
        // press, so hold-to-hide needs this to know when to let go.
        public static bool IsKeyDown(int vk)
        {
            return (Win.GetAsyncKeyState(vk) & 0x8000) != 0;
        }

        // True when some other application's visible window sits above this one
        // and covers its centre. Walks the z-order upwards from the player, so
        // it only reports what could actually be seen over the player's middle.
        // Windows belonging to ownPid are ignored: that is pipfade's own strip
        // and panel, which are allowed to sit on top.
        public static bool IsCovered(IntPtr h, uint ownPid)
        {
            if (!Win.IsWindow(h)) return false;
            Win.RECT pr;
            if (!Win.GetWindowRect(h, out pr)) return false;
            int cx = pr.L + (pr.R - pr.L) / 2;
            int cy = pr.T + (pr.B - pr.T) / 2;

            IntPtr w = Win.GetWindow(h, 3); // GW_HWNDPREV: the window above this one
            int guard = 0;
            while (w != IntPtr.Zero && guard++ < 200)
            {
                if (Win.IsWindowVisible(w))
                {
                    uint pid;
                    Win.GetWindowThreadProcessId(w, out pid);
                    if (pid != ownPid)
                    {
                        Win.RECT r;
                        if (Win.GetWindowRect(w, out r) &&
                            cx >= r.L && cx < r.R && cy >= r.T && cy < r.B) return true;
                    }
                }
                w = Win.GetWindow(w, 3);
            }
            return false;
        }
    }
}
'@
}


# ------------------------------------------------------------------- version
# The one number that has to agree with the git tag. It is only used to answer
# "is there a newer one than this": nothing else in the app reads it.
$script:Version = '1.2.0'

$script:LatestVersion = $null

# ------------------------------------------------------------------- settings
# Shape:
#   { "Alpha": 255, "ClickThrough": false,
#     "AutoApply": true,
#     "RememberGeometry": true,
#     "HoverControls": true,
#     "KeepOnTop": true,
#     "Locked": false,
#     "PanelX": -999999, "PanelY": -999999,
#     "Geometry": { "brave": { "X":.., "Y":.., "W":.., "H":.. } } }
function New-DefaultConfig {
    [pscustomobject]@{
        Alpha            = 255
        ClickThrough     = $false
        AutoApply        = $true
        RememberGeometry = $true
        HoverControls    = $true
        KeepOnTop        = $true
        # A locked frame holds the size and position it was given and puts itself
        # back when something moves it, so an accidental drag cannot undo a layout
        # that took a while to arrange.
        Locked           = $false
        # Where the panel was last left, so it opens where the hand put it rather
        # than in the middle of the screen every time. -999999 means "never moved":
        # a plain -1 would clash with a monitor placed left of or above the primary
        # one, which legitimately has negative coordinates.
        PanelX           = -999999
        PanelY           = -999999
        HideMode         = 'toggle'
        Hotkeys          = New-DefaultHotkeys
        Presets          = New-DefaultPresets
        Geometry         = @{}
    }
}

# Every action that can be bound to a key. Compound bindings (Ctrl+Alt+Shift+…)
# are written as text, so the panel can show and edit them as plain strings.
function New-DefaultHotkeys {
    [pscustomobject]@{
        'down'     = 'Ctrl+Alt+Down'
        'up'       = 'Ctrl+Alt+Up'
        'solid'    = 'Ctrl+Alt+0'
        'click'    = 'Ctrl+Alt+C'
        'pick'     = 'Ctrl+Alt+P'
        'panel'    = 'Ctrl+Alt+A'
        'reset'    = 'Ctrl+Alt+R'
        'geometry' = 'Ctrl+Alt+G'
        'lock'     = 'Ctrl+Alt+L'
        'hover'    = 'Ctrl+Alt+H'
        'ontop'    = 'Ctrl+Alt+T'
        'hide'     = 'Ctrl+Alt+X'
        'quit'     = 'Ctrl+Alt+Q'
    }
}

# A preset is a snapshot of the whole look, not just the opacity: the switches
# on the Controls tab are what make one arrangement of the player different from
# another, so a preset that only stored alpha could not actually put things back.
function New-Preset([string]$name, [int]$alpha, [string]$hotkey, $from) {
    [pscustomobject]@{
        Name             = $name
        Alpha            = $alpha
        Hotkey           = $hotkey
        ClickThrough     = [bool]$from.ClickThrough
        KeepOnTop        = [bool]$from.KeepOnTop
        HoverControls    = [bool]$from.HoverControls
        RememberGeometry = [bool]$from.RememberGeometry
        AutoApply        = [bool]$from.AutoApply
        Locked           = [bool]$from.Locked
        HideMode         = [string]$from.HideMode
    }
}

function New-DefaultPresets {
    # A literal, not New-DefaultConfig: the config's own constructor calls this
    # function, so calling back into it here would never return.
    $base = [pscustomobject]@{
        ClickThrough     = $false
        KeepOnTop        = $true
        HoverControls    = $true
        RememberGeometry = $true
        AutoApply        = $true
        Locked           = $false
        HideMode         = 'toggle'
    }
    @(
        New-Preset 'Preset 1' 200 'Ctrl+Alt+1' $base
        New-Preset 'Preset 2' 140 'Ctrl+Alt+2' $base
        New-Preset 'Preset 3' 90  'Ctrl+Alt+3' $base
    )
}

function Get-Config {
    $cfg = New-DefaultConfig
    if (-not (Test-Path $script:ConfigPath)) { return $cfg }
    try {
        $raw = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
    } catch {
        return $cfg
    }
    foreach ($name in @('Alpha', 'ClickThrough', 'AutoApply', 'RememberGeometry', 'HoverControls', 'KeepOnTop', 'Locked', 'PanelX', 'PanelY')) {
        if ($null -ne $raw.PSObject.Properties[$name]) { $cfg.$name = $raw.$name }
    }
    if ($raw.PSObject.Properties['HideMode'] -and $raw.HideMode) {
        if (@('toggle', 'hold') -contains [string]$raw.HideMode) { $cfg.HideMode = [string]$raw.HideMode }
    }
    if ($raw.PSObject.Properties['Hotkeys'] -and $raw.Hotkeys) {
        foreach ($p in $raw.Hotkeys.PSObject.Properties) {
            if ($cfg.Hotkeys.PSObject.Properties[$p.Name]) { $cfg.Hotkeys.($p.Name) = [string]$p.Value }
        }
    }
    if ($raw.PSObject.Properties['Presets'] -and $raw.Presets) {
        $base = New-DefaultConfig
        $list = @()
        foreach ($p in @($raw.Presets)) {
            if ($null -eq $p) { continue }
            $name = if ($p.Name) { [string]$p.Name } else { "Preset $($list.Count + 1)" }
            $hotkey = [string]$p.Hotkey
            $alpha = [Math]::Max($MIN_ALPHA, [Math]::Min($MAX_ALPHA, [int]$p.Alpha))
            # A preset written before presets carried the switches has no
            # ClickThrough and so on. Falling back to the beta defaults keeps
            # those files loading, and the next save writes the full shape.
            $from = [pscustomobject]@{
                ClickThrough     = if ($null -ne $p.PSObject.Properties['ClickThrough'] -and $null -ne $p.ClickThrough) { [bool]$p.ClickThrough } else { $base.ClickThrough }
                KeepOnTop        = if ($null -ne $p.PSObject.Properties['KeepOnTop'] -and $null -ne $p.KeepOnTop) { [bool]$p.KeepOnTop } else { $base.KeepOnTop }
                HoverControls    = if ($null -ne $p.PSObject.Properties['HoverControls'] -and $null -ne $p.HoverControls) { [bool]$p.HoverControls } else { $base.HoverControls }
                RememberGeometry = if ($null -ne $p.PSObject.Properties['RememberGeometry'] -and $null -ne $p.RememberGeometry) { [bool]$p.RememberGeometry } else { $base.RememberGeometry }
                AutoApply        = if ($null -ne $p.PSObject.Properties['AutoApply'] -and $null -ne $p.AutoApply) { [bool]$p.AutoApply } else { $base.AutoApply }
                Locked           = if ($null -ne $p.PSObject.Properties['Locked'] -and $null -ne $p.Locked) { [bool]$p.Locked } else { $base.Locked }
                HideMode         = if ($null -ne $p.PSObject.Properties['HideMode'] -and $null -ne $p.HideMode -and @('toggle', 'hold') -contains [string]$p.HideMode) { [string]$p.HideMode } else { $base.HideMode }
            }
            $list += New-Preset $name $alpha $hotkey $from
        }
        if ($list.Count -gt 0) { $cfg.Presets = $list }
    }
    if ($raw.PSObject.Properties['Geometry'] -and $raw.Geometry) {
        $g = @{}
        foreach ($p in $raw.Geometry.PSObject.Properties) {
            $e = $p.Value
            if ($null -ne $e.X -and $null -ne $e.W) {
                $g[$p.Name] = [pscustomobject]@{
                    X = [int]$e.X; Y = [int]$e.Y; W = [int]$e.W; H = [int]$e.H
                }
            }
        }
        $cfg.Geometry = $g
    }
    $cfg.Alpha = [Math]::Max($MIN_ALPHA, [Math]::Min($MAX_ALPHA, [int]$cfg.Alpha))
    return $cfg
}

function Save-Config($cfg) {
    try {
        if ($env:PIPFADE_TRACE) {
            $stack = (Get-PSCallStack | Select-Object -Skip 1 -First 5 | ForEach-Object { $_.Command }) -join ' < '
            Add-Content $env:PIPFADE_TRACE ("save alpha={0} via {1}" -f $cfg.Alpha, $stack)
        }
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $script:ConfigPath -Encoding UTF8
    } catch {
        Write-Warning "could not save settings: $($_.Exception.Message)"
    }
}

# Dragging the slider fires dozens of changes a second. Writing the file on
# every one of them is pure disk churn, so the write is deferred to the loop.
function Request-Save { $script:SaveDue = $true }

function Flush-Save {
    if (-not $script:SaveDue) { return }
    $script:SaveDue = $false
    Save-Config $script:Config
}

# ---------------------------------------------------------------- hotkey text
# Bindings are stored as text like "Ctrl+Alt+Shift+P" so they can be shown and
# edited in the panel. Anything the parser does not recognise is reported as
# invalid instead of silently binding the wrong key.
function ConvertTo-HotkeySpec([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $mods = 0
    $vk = 0
    $parts = $text -split '\+'
    foreach ($raw in $parts) {
        $p = $raw.Trim()
        if ($p -eq '') { continue }
        switch -Regex ($p) {
            '^(ctrl|control)$' { $mods = $mods -bor 0x2; continue }
            '^(alt)$'          { $mods = $mods -bor 0x1; continue }
            '^(shift)$'        { $mods = $mods -bor 0x4; continue }
            '^(win|windows)$'  { $mods = $mods -bor 0x8; continue }
            '^(up)$'           { $vk = 0x26; continue }
            '^(down)$'         { $vk = 0x28; continue }
            '^(left)$'         { $vk = 0x25; continue }
            '^(right)$'        { $vk = 0x27; continue }
            '^(space)$'        { $vk = 0x20; continue }
            '^(plus)$'         { $vk = 0xBB; continue }
            '^(minus)$'        { $vk = 0xBD; continue }
            # The numpad's plus and minus are different virtual keys from the ones
            # next to Backspace, so the recorder names them apart; folding both
            # spellings into Plus would bind the wrong key.
            '^(numpadplus)$'   { $vk = 0x6B; continue }
            '^(numpadminus)$'  { $vk = 0x6D; continue }
            # The rest of these exist because the recorder can produce them: the
            # keys tab fills these boxes by pressing keys, so anything it can
            # capture has to be something this parser accepts back.
            '^(home)$'         { $vk = 0x24; continue }
            '^(end)$'          { $vk = 0x23; continue }
            '^(pageup)$'       { $vk = 0x21; continue }
            '^(pagedown)$'     { $vk = 0x22; continue }
            '^(insert)$'       { $vk = 0x2D; continue }
            '^(numpad)([0-9])$' { $vk = 0x60 + [int]$matches[2]; continue }
            '^f([1-9]|1[0-2])$' { $vk = 0x6F + [int]$matches[1]; continue }
            '^[A-Z]$'          { $vk = [int][char]$p; continue }
            '^[a-z]$'          { $vk = [int][char]$p.ToUpperInvariant(); continue }
            '^[0-9]$'          { $vk = 0x30 + [int]$p; continue }
            default            { return $null }
        }
    }
    if ($vk -eq 0 -or $mods -eq 0) { return $null }
    [pscustomobject]@{ Mods = $mods; Vk = $vk }
}

function Format-HotkeySpec([int]$mods, [int]$vk) {
    $out = @()
    if ($mods -band 0x2) { $out += 'Ctrl' }
    if ($mods -band 0x1) { $out += 'Alt' }
    if ($mods -band 0x4) { $out += 'Shift' }
    if ($mods -band 0x8) { $out += 'Win' }
    $name = switch ($vk) {
        0x26 { 'Up' } 0x28 { 'Down' } 0x25 { 'Left' } 0x27 { 'Right' }
        0x20 { 'Space' } 0xBB { 'Plus' } 0xBD { 'Minus' }
        0x6B { 'NumPadPlus' } 0x6D { 'NumPadMinus' }
        0x24 { 'Home' } 0x23 { 'End' } 0x21 { 'PageUp' } 0x22 { 'PageDown' } 0x2D { 'Insert' }
        default {
            if ($vk -ge 0x70 -and $vk -le 0x7B) { "F$($vk - 0x6F)" }
            elseif ($vk -ge 0x60 -and $vk -le 0x69) { "NumPad$($vk - 0x60)" }
            elseif ($vk -ge 0x30 -and $vk -le 0x39) { [string][char]$vk }
            else { [string][char]$vk }
        }
    }
    $out += $name
    $out -join '+'
}

# --------------------------------------------------------------- geometry memory
function Get-GeometryKey([string]$proc) {
    if ([string]::IsNullOrWhiteSpace($proc)) { return 'default' }
    return $proc.ToLowerInvariant()
}

# Every window sits inside the visible desktop, or it would be lost off-screen.
function Test-OnScreen([int]$x, [int]$y, [int]$w, [int]$h) {
    $v = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $pad = 40   # keep at least a grabbable edge on screen
    if ($x + $w -lt $v.Left + $pad) { return $false }
    if ($y + $h -lt $v.Top + $pad)  { return $false }
    if ($x -gt $v.Right - $pad)     { return $false }
    if ($y -gt $v.Bottom - $pad)    { return $false }
    return $true
}

function Save-Geometry($cfg, [string]$proc, $rect) {
    if (-not $cfg.RememberGeometry) { return }
    $key = Get-GeometryKey $proc
    $cfg.Geometry[$key] = [pscustomobject]@{
        X = [int]$rect.X; Y = [int]$rect.Y; W = [int]$rect.W; H = [int]$rect.H
    }
}

# A remembered size is only worth restoring while it is still the right shape.
# The window belongs to the browser, and the browser shapes it to the video it
# is showing: a rect saved from a wide video, applied to a tall one, leaves
# black bars down the sides. So the position is always fair game and the size is
# applied only when the two shapes agree to within a couple of percent.
function Get-RestoreRect($pip, $g) {
    $sameShape = $false
    if ($pip.W -gt 0 -and $pip.H -gt 0 -and $g.W -gt 0 -and $g.H -gt 0) {
        $was = $g.W / [double]$g.H
        $now = $pip.W / [double]$pip.H
        $sameShape = ([Math]::Abs($was - $now) / $now) -le 0.02
    }
    if ($sameShape) {
        return [pscustomobject]@{ X = [int]$g.X; Y = [int]$g.Y; W = [int]$g.W; H = [int]$g.H }
    }
    # Keep the shape the player has now, and centre that shape where the saved
    # one sat: a video that changed proportions still lands on the spot you
    # left it rather than half a window away from it.
    $w = [int]$pip.W; $h = [int]$pip.H
    $x = [int]($g.X + ($g.W - $w) / 2)
    $y = [int]($g.Y + ($g.H - $h) / 2)
    # Centring can push a window that grew past the edge the old one sat against,
    # so pull it back on screen when it fits there at all. Test-OnScreen would
    # otherwise accept a window hanging a hundred pixels off the left edge.
    $v = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($w -le $v.Width) {
        if ($x -lt $v.Left) { $x = $v.Left }
        if ($x + $w -gt $v.Right) { $x = $v.Right - $w }
    }
    if ($h -le $v.Height) {
        if ($y -lt $v.Top) { $y = $v.Top }
        if ($y + $h -gt $v.Bottom) { $y = $v.Bottom - $h }
    }
    return [pscustomobject]@{
        X = $x
        Y = $y
        W = $w
        H = $h
    }
}

function Restore-Geometry($cfg, $pip) {
    if (-not $cfg.RememberGeometry) { return $false }
    $key = Get-GeometryKey $pip.Proc
    if (-not $cfg.Geometry.ContainsKey($key)) { return $false }

    $g = $cfg.Geometry[$key]
    # only move it if the player drifted from what we remembered
    if ($pip.X -eq $g.X -and $pip.Y -eq $g.Y -and $pip.W -eq $g.W -and $pip.H -eq $g.H) {
        return $false
    }
    $r = Get-RestoreRect $pip $g
    if (-not (Test-OnScreen $r.X $r.Y $r.W $r.H)) { return $false }
    if ($pip.X -eq $r.X -and $pip.Y -eq $r.Y -and $pip.W -eq $r.W -and $pip.H -eq $r.H) {
        return $false
    }
    [PipFade.Finder]::Move($pip.Handle, $r.X, $r.Y, $r.W, $r.H)
    return $true
}


# ---------------------------------------------------------------- UI (one unit)
# All UI types must live in a single Add-Type call: each call compiles into its
# own assembly and cannot see types defined by an earlier call.
if (-not ('PipFadeUI.PanelForm' -as [type])) {
Add-Type -ReferencedAssemblies 'System', 'System.Drawing', 'System.Windows.Forms' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace PipFadeUI
{
    // Each Add-Type call compiles into its own assembly, so the UI types cannot
    // see PipFade.Win from the native unit. The handful of calls the bar needs
    // to blend per pixel therefore live here as well.
    internal static class Layered
    {
        [StructLayout(LayoutKind.Sequential)] public struct XY { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] public struct WH { public int CX, CY; public WH(int w, int h) { CX = w; CY = h; } }
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        public struct Blend { public byte Op, Flags, SourceAlpha, AlphaFormat; }

        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
        [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dstDc,
            ref XY dst, ref WH size, IntPtr srcDc, ref XY src, int key, ref Blend blend, int flags);

        // Paints a bitmap with its own alpha channel onto a layered window. This
        // is what lets the bar show only its slider and icons, with nothing
        // behind them.
        public static bool Draw(IntPtr hwnd, Bitmap bmp, int left, int top)
        {
            IntPtr screen = GetDC(IntPtr.Zero);
            IntPtr mem = CreateCompatibleDC(screen);
            IntPtr hbmp = bmp.GetHbitmap(Color.FromArgb(0));
            IntPtr old = SelectObject(mem, hbmp);
            try
            {
                XY src = new XY();
                XY dst = new XY(); dst.X = left; dst.Y = top;
                WH size = new WH(bmp.Width, bmp.Height);
                Blend blend = new Blend();
                blend.Op = 0;          // AC_SRC_OVER
                blend.SourceAlpha = 255;
                blend.AlphaFormat = 1; // AC_SRC_ALPHA
                return UpdateLayeredWindow(hwnd, screen, ref dst, ref size, mem, ref src, 0, ref blend, 2);
            }
            finally
            {
                SelectObject(mem, old);
                DeleteObject(hbmp);
                DeleteDC(mem);
                ReleaseDC(IntPtr.Zero, screen);
            }
        }
    }

    public static class Palette
    {
        // Monochrome on purpose: the app draws attention to the video, not to
        // itself. Emphasis comes from brightness and weight, never from hue.
        public static readonly Color Bg      = Color.FromArgb(0x0C, 0x0C, 0x0D);
        public static readonly Color Surface = Color.FromArgb(0x17, 0x17, 0x18);
        public static readonly Color Line    = Color.FromArgb(0x2A, 0x2A, 0x2C);
        public static readonly Color Track   = Color.FromArgb(0x33, 0x33, 0x36);
        public static readonly Color Text    = Color.FromArgb(0xF5, 0xF5, 0xF6);
        public static readonly Color Muted   = Color.FromArgb(0xAB, 0xAB, 0xAF);
        public static readonly Color Accent  = Color.FromArgb(0xF0, 0xF0, 0xF2);
        public static readonly Color Warn    = Color.FromArgb(0xFF, 0xFF, 0xFF);
        public static readonly Color Hint    = Color.FromArgb(0x8E, 0x8E, 0x93);
    }

    // GDI+ font creation is one of the most expensive things a paint loop can do:
    // each object builds a font handle and parses the typeface. The panel repaints
    // on every hover and drag, so these are made once and shared.
    internal static class Fonts
    {
        public static readonly Font BarPct = new Font("Segoe UI Semibold", 8.25f);
        public static readonly Font Switch = new Font("Segoe UI", 9f);
        public static readonly Font TabOn = new Font("Segoe UI Semibold", 8.75f);
        public static readonly Font TabOff = new Font("Segoe UI", 8.75f);
        public static readonly Font ReadBig = new Font("Segoe UI Semibold", 15f);
        public static readonly Font ReadSmall = new Font("Segoe UI", 8.5f);
        public static readonly Font ReadSign = new Font("Segoe UI", 9f);
        public static readonly Font Tip = new Font("Segoe UI", 8.75f);
        public static readonly Font Notice = new Font("Segoe UI Semibold", 8.75f);
    }

    // The notification-area menu is drawn by Windows with light chrome unless it
    // is told otherwise: a bright white dropdown hanging off a near-black tray
    // icon is the one place the app's own palette visibly stops. A renderer
    // paints every part the platform normally delegates, so the menu reads as
    // part of the same window rather than as a system dialog that turned up.
    public class DarkMenu : ToolStripProfessionalRenderer
    {
        public DarkMenu() : base(new DarkColours()) { RoundedEdges = false; }

        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
        {
            using (SolidBrush b = new SolidBrush(Palette.Surface)) e.Graphics.FillRectangle(b, e.AffectedBounds);
        }

        // A 1px edge all the way round, the same line colour the panel uses for
        // its boxes. Without it the menu floats with no edge at all against a
        // dark desktop.
        protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
        {
            Rectangle r = new Rectangle(0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
            using (Pen p = new Pen(Palette.Line)) e.Graphics.DrawRectangle(p, r);
        }

        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
        {
            bool hot = e.Item.Selected && e.Item.Enabled;
            if (!hot) return;
            Rectangle r = new Rectangle(3, 1, e.Item.Width - 6, e.Item.Height - 3);
            using (GraphicsPath p = Draw.Round(r, 5))
            {
                using (SolidBrush b = new SolidBrush(Palette.Track)) e.Graphics.FillPath(b, p);
            }
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            e.TextColor = e.Item.Enabled ? Palette.Text : Palette.Hint;
            e.TextFont = Fonts.Tip;
            base.OnRenderItemText(e);
        }

        protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
        {
            int y = e.Item.Height / 2;
            using (Pen p = new Pen(Palette.Line))
                e.Graphics.DrawLine(p, 10, y, e.Item.Width - 10, y);
        }

        protected override void OnRenderImageMargin(ToolStripRenderEventArgs e)
        {
            // Nothing to draw: none of these items carries an image, and the
            // default light gutter is the widest thing the platform adds.
        }
    }

    // The professional renderer's colour table still gets consulted for a few
    // parts this subclass does not override (arrow areas, check backgrounds), so
    // it has to be dark too or those corners come back white.
    public class DarkColours : ProfessionalColorTable
    {
        public override Color ToolStripDropDownBackground { get { return Palette.Surface; } }
        public override Color MenuBorder { get { return Palette.Line; } }
        public override Color MenuItemBorder { get { return Palette.Track; } }
        public override Color MenuItemSelected { get { return Palette.Track; } }
        public override Color MenuItemSelectedGradientBegin { get { return Palette.Track; } }
        public override Color MenuItemSelectedGradientEnd { get { return Palette.Track; } }
        public override Color ImageMarginGradientBegin { get { return Palette.Surface; } }
        public override Color ImageMarginGradientMiddle { get { return Palette.Surface; } }
        public override Color ImageMarginGradientEnd { get { return Palette.Surface; } }
        public override Color SeparatorDark { get { return Palette.Line; } }
        public override Color SeparatorLight { get { return Palette.Line; } }
    }

    // A one-line label shown over a field whose text does not fit. The panel is a
    // fixed size, so a long binding or a long preset name is clipped by design;
    // hovering is how the rest of it is read. It is its own top-most window
    // rather than a ToolTip because a ToolTip is drawn by the system in the light
    // system theme, and this window can be matched to the panel exactly.
    public class TipWindow : Form
    {
        public TipWindow()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            BackColor = Palette.Surface;
            TopMost = true;
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE
                return cp;
            }
        }

        // Shows text just above a screen rectangle, nudged back on screen when
        // the field sits near an edge. Drawn rather than composed from a Label so
        // the padding and the rim are the panel's own numbers.
        public void ShowFor(string text, Rectangle anchor)
        {
            if (string.IsNullOrEmpty(text)) return;
            Size need;
            using (Graphics g = CreateGraphics())
            {
                SizeF s = g.MeasureString(text, Fonts.Tip);
                need = new Size((int)Math.Ceiling(s.Width) + 18, (int)Math.Ceiling(s.Height) + 10);
            }
            ClientSize = need;
            Rectangle v = Screen.FromRectangle(anchor).WorkingArea;
            int x = anchor.Left;
            int y = anchor.Top - need.Height - 6;
            if (y < v.Top) y = anchor.Bottom + 6;
            if (x + need.Width > v.Right) x = v.Right - need.Width;
            if (x < v.Left) x = v.Left;
            Location = new Point(x, y);
            Text = text;
            if (!Visible) Show();
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            g.Clear(Palette.Surface);
            using (SolidBrush b = new SolidBrush(Palette.Text))
                g.DrawString(Text, Fonts.Tip, b, 9, 5);
            using (Pen p = new Pen(Palette.Line))
                g.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
        }
    }

    // One shared tip window and one shared timer for the whole panel. A timer per
    // field would be twenty-five timers ticking for nothing while the window is
    // open, and only one field can be hovered at a time anyway.
    public static class Tips
    {
        static TipWindow _win;
        static Timer _timer;
        static Control _ctl;
        static Func<string> _text;

        public static bool IsOpen { get { return _win != null && _win.Visible; } }

        // Waits before showing. Half a second is long enough that sweeping the
        // pointer across the panel on the way somewhere else never flashes a
        // label, and short enough that stopping on a clipped one feels answered.
        public static void Arm(Control c, Func<string> text)
        {
            if (c == null || text == null) return;
            _ctl = c;
            _text = text;
            if (_timer == null)
            {
                _timer = new Timer();
                _timer.Interval = 520;
                _timer.Tick += delegate { Fire(); };
            }
            _timer.Stop();
            _timer.Start();
        }

        public static void Disarm(Control c)
        {
            // Only the control that armed it can disarm it: moving off a text box
            // onto the panel it sits in fires leave then enter, and the second
            // event has already armed the same field again by then.
            if (_ctl != c) return;
            _timer.Stop();
            _ctl = null;
            _text = null;
            Hide();
        }

        public static void Hide()
        {
            if (_win != null && _win.Visible) _win.Hide();
        }

        public static void Close()
        {
            if (_timer != null) { _timer.Stop(); _timer.Dispose(); _timer = null; }
            if (_win != null) { _win.Dispose(); _win = null; }
            _ctl = null;
            _text = null;
        }

        static void Fire()
        {
            _timer.Stop();
            Control c = _ctl;
            if (c == null || !c.Visible || c.IsDisposed) return;
            // The pointer may have left while the timer ran; the leave handler
            // covers the ordinary case, this covers a leave the control never saw.
            Rectangle box = c.RectangleToScreen(c.ClientRectangle);
            if (!box.Contains(Cursor.Position)) return;

            string t = _text == null ? "" : _text();
            Font f = c.Font;
            Field fd = c as Field;
            if (fd != null && fd.Box != null) f = fd.Box.Font;
            if (string.IsNullOrEmpty(t)) return;
            if (TextRenderer.MeasureText(t, f).Width <= c.ClientSize.Width) return;

            if (_win == null) _win = new TipWindow();
            _win.ShowFor(t, box);
        }
    }

    // Rounds the borderless windows with the compositor rather than clipping them
    // with a Region. A Region is cut on hard pixel edges with no antialiasing, so
    // its corners come out as bright stair-steps against whatever is behind; the
    // compositor's arc is antialiased and it also draws its own edge that follows
    // the curve exactly. Falls back to a Region on systems without the API.
    public static class Corners
    {
        [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(
            IntPtr h, int attr, ref int val, int size);

        const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        const int DWMWA_BORDER_COLOR = 34;
        const int DWMWCP_ROUND = 2;
        const int DWMWA_COLOR_NONE = unchecked((int)0xFFFFFFFE);

        public static bool Frame(Form f, int radius, Color line)
        {
            if (f == null || !f.IsHandleCreated) return false;
            bool arc, edge;
            try
            {
                int pref = DWMWCP_ROUND;
                arc = DwmSetWindowAttribute(f.Handle, DWMWA_WINDOW_CORNER_PREFERENCE,
                                           ref pref, sizeof(int)) == 0;
                // Ask the compositor to draw the rim as well as cut the shape.
                // A stroke painted by us cannot follow an arc we do not control:
                // two curves at two radii on one corner is what made the panel
                // look off, with the outer one clipping the inner one. One edge
                // drawn by the thing that also cuts the shape always matches.
                int col = line.R | (line.G << 8) | (line.B << 16);
                edge = DwmSetWindowAttribute(f.Handle, DWMWA_BORDER_COLOR,
                                             ref col, sizeof(int)) == 0;
            }
            catch { return false; }

            // With the compositor drawing the edge there must be no Region: it
            // would clip the very arc being relied on.
            if (arc && edge) { f.Region = null; return true; }
            f.Region = new Region(Draw.Round(new Rectangle(0, 0, f.Width, f.Height), radius));
            return false;
        }
    }

    // The app mark: a frame whose stroke fades out towards its right edge — the
    // mini player's own behaviour drawn as a shape. One definition, used at every
    // size the app needs it (panel header, taskbar, tray, the icon file).
    //
    // It is an outline everywhere, including the header. A filled shape in the
    // panel and an outline on the taskbar read as two different apps, which is
    // exactly what happened while the header still painted a solid plate.
    public static class Mark
    {
        public static void Paint(Graphics g, Rectangle r, Color fg)
        {
            if (r.Width < 4 || r.Height < 3) return;
            // Proportional to the height so the header mark keeps the same
            // stroke-to-shape ratio as the icon renditions.
            PaintFrame(g, r, fg, Math.Max(1.3f, r.Height * 0.115f));
        }

        // The one place the frame is drawn: a rounded rectangle outlined with a
        // horizontal gradient. Everything else is a call with a different
        // rectangle and pen width.
        static void PaintFrame(Graphics g, Rectangle r, Color fg, float penW)
        {
            GraphicsState state = g.Save();
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath p = Draw.Round(r, Math.Max(2, r.Height / 3)))
            using (LinearGradientBrush b = new LinearGradientBrush(
                       new Rectangle(r.X, r.Y, r.Width, r.Height),
                       fg, fg, LinearGradientMode.Horizontal))
            {
                // Solid across the left and middle, then down to a faint edge:
                // the same "window going see-through" read at every size.
                ColorBlend blend = new ColorBlend(3);
                blend.Colors = new Color[] { fg, Color.FromArgb(205, fg), Color.FromArgb(70, fg) };
                blend.Positions = new float[] { 0f, 0.55f, 1f };
                b.InterpolationColors = blend;
                using (Pen pen = new Pen(b, penW))
                {
                    pen.StartCap = LineCap.Round;
                    pen.EndCap = LineCap.Round;
                    pen.LineJoin = LineJoin.Round;
                    g.DrawPath(pen, p);
                }
            }
            g.Restore(state);
        }

        // Icon sizes are small enough that the mark needs a wider frame than a
        // text-height one, or it collapses into a stripe. Every size is drawn with
        // the same outline and the same proportions; only the stroke width grows
        // with the canvas. Alt-tab asks for 32px, the taskbar for 16px, and an
        // icon that changes shape between them looks like two different apps.
        public static void PaintIcon(Graphics g, int size, Color fg)
        {
            int h = Math.Max(6, (int)Math.Round(size * (size <= 24 ? 0.56 : 0.54)));
            int w = Math.Max(8, (int)Math.Round(size * (size <= 24 ? 0.86 : 0.84)));
            Rectangle r = new Rectangle((size - w) / 2, (size - h) / 2, w, h);
            float penW = size <= 16 ? 1.3f : (size <= 24 ? 1.6f : (size <= 32 ? 2.0f : 2.6f));
            PaintFrame(g, r, fg, penW);
        }

        // A taskbar button asks the shell for a 16px icon and a hover preview for
        // a 32px one. A single-size icon gets squashed to fit, which is why the
        // button looked wrong: the mark turned into a pale smear. This writes a
        // real multi-size icon so every place gets a rendition drawn at its own
        // size.
        //
        // Frames are stored as uncompressed 32-bit DIBs, not PNG. PNG frames are
        // only meant for 256x256, and both GDI+ and parts of the shell refuse to
        // decode a PNG frame at 16 or 20 pixels — the request fails and the
        // caller falls back to a squashed copy of a bigger frame, which is
        // exactly the pale smear this was meant to fix. A DIB has no such limit.
        public static Icon AppIcon(Color fg)
        {
            byte[] bytes = IconBytes(fg);
            Icon result;
            using (MemoryStream ico = new MemoryStream(bytes))
            // Clone before the stream goes away: Icon keeps a lazy reference to
            // its source otherwise, and a disposed stream gives a blank icon.
            using (Icon temp = new Icon(ico)) { result = (Icon)temp.Clone(); }
            return result;
        }

        // The same five frames as a standalone .ico file, so the launcher on disk
        // shows the identical mark as the taskbar button and the tray.
        public static byte[] IconBytes(Color fg)
        {
            int[] sizes = new int[] { 16, 20, 24, 32, 48 };
            List<byte[]> parts = new List<byte[]>();
            foreach (int s in sizes)
            {
                using (Bitmap bmp = new Bitmap(s, s, System.Drawing.Imaging.PixelFormat.Format32bppArgb))
                {
                    using (Graphics g = Graphics.FromImage(bmp))
                    {
                        g.Clear(Color.Transparent);
                        PaintIcon(g, s, fg);
                    }
                    parts.Add(Dib(bmp));
                }
            }

            using (MemoryStream ico = new MemoryStream())
            {
                BinaryWriter w = new BinaryWriter(ico);
                w.Write((short)0);                  // reserved
                w.Write((short)1);                  // 1 = icon
                w.Write((short)sizes.Length);

                int offset = 6 + 16 * sizes.Length;
                for (int i = 0; i < sizes.Length; i++)
                {
                    w.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));   // width
                    w.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));   // height
                    w.Write((byte)0);               // palette size
                    w.Write((byte)0);               // reserved
                    w.Write((short)1);              // colour planes
                    w.Write((short)32);             // bits per pixel
                    w.Write(parts[i].Length);
                    w.Write(offset);
                    offset += parts[i].Length;
                }
                foreach (byte[] p in parts) w.Write(p);
                w.Flush();
                return ico.ToArray();
            }
        }

        // One icon frame as an uncompressed 32-bit DIB: a BITMAPINFOHEADER whose
        // height is doubled (colour rows plus the legacy AND mask), then the BGRA
        // pixels bottom-up, then a 1-bit mask that is all zero because the alpha
        // channel already carries the shape. The mask has to be there and has to
        // be padded to 4 bytes a row, or the shell reads the next frame's bytes as
        // part of this one.
        static byte[] Dib(Bitmap bmp)
        {
            int w = bmp.Width, h = bmp.Height;
            int stride = ((w + 31) / 32) * 4;          // mask row, bits padded to 4 bytes
            using (MemoryStream ms = new MemoryStream())
            {
                BinaryWriter bw = new BinaryWriter(ms);
                bw.Write(40);                           // biSize
                bw.Write(w);                            // biWidth
                bw.Write(h * 2);                        // biHeight: colour + mask
                bw.Write((short)1);                     // biPlanes
                bw.Write((short)32);                    // biBitCount
                bw.Write(0);                            // biCompression = BI_RGB
                bw.Write(w * h * 4 + stride * h);       // biSizeImage
                bw.Write(0); bw.Write(0);               // resolution
                bw.Write(0); bw.Write(0);               // palette

                // Bottom-up: icon DIBs start at the last row.
                for (int y = h - 1; y >= 0; y--)
                    for (int x = 0; x < w; x++)
                    {
                        Color c = bmp.GetPixel(x, y);
                        bw.Write(c.B); bw.Write(c.G); bw.Write(c.R); bw.Write(c.A);
                    }

                byte[] blank = new byte[stride];
                for (int y = 0; y < h; y++) bw.Write(blank);

                bw.Flush();
                return ms.ToArray();
            }
        }
        // which is a separate setting from the app theme. A near-white mark
        // vanishes on a light taskbar, so swap to near-black there.
        public static Color ShellFore(Color onDark)
        {
            try
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                           @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                {
                    object v = k == null ? null : k.GetValue("SystemUsesLightTheme");
                    bool light = (v is int) && ((int)v != 0);
                    if (light) return Color.FromArgb(0x1A, 0x1A, 0x1C);
                }
            }
            catch { }
            return onDark;
        }

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool DestroyIcon(IntPtr handle);
    }

    public static class Draw
    {
        public static GraphicsPath Round(Rectangle r, int radius)
        {
            GraphicsPath p = new GraphicsPath();
            int d = radius * 2;
            if (d <= 0 || d > r.Width || d > r.Height) { p.AddRectangle(r); return p; }
            // The right and bottom arcs have to sit on the rectangle's own edge.
            // Placing them a pixel inside made the path stop short of where it
            // started, so the two far corners were drawn at a slightly different
            // radius from the two near ones and the shape never closed cleanly.
            int right = r.Right - d, bottom = r.Bottom - d;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(right, r.Y, d, d, 270, 90);
            p.AddArc(right, bottom, d, d, 0, 90);
            p.AddArc(r.X, bottom, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect
    {
        public int X, Y, W, H;
        public Rect(int x, int y, int w, int h) { X = x; Y = y; W = w; H = h; }
        public bool Same(Rect o) { return X == o.X && Y == o.Y && W == o.W && H == o.H; }
    }

    // ---------------------------------------------------------------- controls
    // A window button drawn rather than typed: the arrow and dash glyphs render
    // as blank boxes in some UI fonts, so these are plain shapes.
    public class GlyphButton : Control
    {
        public enum Kind { Minimize, Close, Plus, Remove, Save, Apply }
        public Kind Icon;
        bool _hover;

        public GlyphButton(Kind kind)
        {
            Icon = kind;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            Cursor = Cursors.Hand;
            BackColor = Color.Transparent;
        }

        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush back = new SolidBrush(_hover ? Palette.Surface : Palette.Bg))
                g.FillRectangle(back, ClientRectangle);

            Color fg = _hover ? Palette.Text : Palette.Muted;
            int cx = Width / 2, cy = Height / 2;
            using (Pen pen = new Pen(fg, 1.4f))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                switch (Icon)
                {
                    case Kind.Minimize:
                        g.DrawLine(pen, cx - 4, cy, cx + 4, cy);
                        break;
                    case Kind.Close:
                        g.DrawLine(pen, cx - 4, cy - 4, cx + 4, cy + 4);
                        g.DrawLine(pen, cx + 4, cy - 4, cx - 4, cy + 4);
                        break;
                    case Kind.Plus:
                        g.DrawLine(pen, cx - 4, cy, cx + 4, cy);
                        g.DrawLine(pen, cx, cy - 4, cx, cy + 4);
                        break;
                    case Kind.Remove:
                        g.DrawLine(pen, cx - 4, cy, cx + 4, cy);
                        break;
                    case Kind.Save:
                        // Arrow down onto a line: "put what you have into this one".
                        g.DrawLine(pen, cx, cy - 5, cx, cy + 1);
                        g.DrawLine(pen, cx - 3, cy - 2, cx, cy + 1);
                        g.DrawLine(pen, cx + 3, cy - 2, cx, cy + 1);
                        g.DrawLine(pen, cx - 4, cy + 4, cx + 4, cy + 4);
                        break;
                    case Kind.Apply:
                        // A play triangle: "use this one now".
                        g.DrawLine(pen, cx - 3, cy - 5, cx + 4, cy);
                        g.DrawLine(pen, cx + 4, cy, cx - 3, cy + 5);
                        g.DrawLine(pen, cx - 3, cy + 5, cx - 3, cy - 5);
                        break;
                }
            }
        }
    }

    public class Switch : Control
    {
        bool _on;
        public bool On { get { return _on; } set { _on = value; Invalidate(); } }
        public event EventHandler Toggled;

        public Switch(string label, bool on)
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Text = label; _on = on;
            Height = 30; Cursor = Cursors.Hand;
        }

        protected override void OnClick(EventArgs e)
        {
            _on = !_on; Invalidate();
            if (Toggled != null) Toggled(this, EventArgs.Empty);
            base.OnClick(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            g.Clear(BackColor);

            int sw = 36, sh = 18;
            Rectangle pill = new Rectangle(Width - sw, (Height - sh) / 2, sw, sh);

            using (SolidBrush b = new SolidBrush(Enabled ? Palette.Text : Palette.Muted))
                g.DrawString(Text, Fonts.Switch, b, 0, (Height - 16) / 2);

            using (GraphicsPath p = Draw.Round(pill, sh / 2))
            {
                using (SolidBrush fill = new SolidBrush(_on ? Palette.Accent : Palette.Track))
                    g.FillPath(fill, p);
                using (Pen edge = new Pen(_on ? Palette.Accent : Palette.Line))
                    g.DrawPath(edge, p);
            }
            int kd = sh - 6;
            Rectangle knob = new Rectangle(_on ? pill.Right - kd - 3 : pill.X + 3, pill.Y + 3, kd, kd);
            using (SolidBrush kb = new SolidBrush(_on ? Palette.Bg : Palette.Muted))
                g.FillEllipse(kb, knob);
        }
    }

    public class OpacitySlider : Control
    {
        int _value = 255;
        bool _drag, _hover, _onNumber, _editing;
        public int Minimum = 40, Maximum = 255;
        // Compact drops the big readout so the slider fits inside the hover strip.
        public bool Compact = false;
        public event EventHandler ValueChanged;

        public int Value
        {
            get { return _value; }
            set
            {
                int v = value;
                if (v < Minimum) v = Minimum;
                if (v > Maximum) v = Maximum;
                if (v != _value)
                {
                    _value = v; Invalidate();
                    if (ValueChanged != null) ValueChanged(this, EventArgs.Empty);
                }
            }
        }

        public int Percent { get { return (int)Math.Round(_value / 255.0 * 100); } }

        // The number is a real input field, not a readout with a box dropped on
        // top of it: a rounded well holding "63%" that inverts to an editable
        // field in place. Dragging to 140 is guesswork, typing 140 is not.
        // It takes a percentage, because a percentage is what it shows: typing
        // 63 into a field that says 63% has to mean the same thing twice.
        TextBox _edit;

        Rectangle ReadoutRect { get { return new Rectangle(10, 2, 92, 30); } }

        // 0..100 on screen, Minimum..Maximum underneath.
        public int ToAlpha(int percent)
        {
            if (percent < 0) percent = 0;
            if (percent > 100) percent = 100;
            int v = (int)Math.Round(percent / 100.0 * 255);
            if (v < Minimum) v = Minimum;
            if (v > Maximum) v = Maximum;
            return v;
        }

        public OpacitySlider()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw
                     | ControlStyles.SupportsTransparentBackColor, true);
            Height = 64; Cursor = Cursors.Hand;
        }

        public void BeginEdit()
        {
            if (_edit != null || Compact) return;
            _editing = true;
            Rectangle r = ReadoutRect;
            _edit = new TextBox();
            _edit.BorderStyle = BorderStyle.None;
            _edit.BackColor = Palette.Surface;
            _edit.ForeColor = Palette.Text;
            _edit.Font = new Font("Segoe UI Semibold", 14f);
            // Sits inside the well with the same padding as the painted number,
            // so entering and leaving the field does not shift the text.
            _edit.Bounds = new Rectangle(r.X + 12, r.Y + 4, r.Width - 22, r.Height - 8);
            _edit.MaxLength = 3;
            _edit.Text = Percent.ToString();
            _edit.KeyDown += EditKey;
            // Only digits: the value is a percentage, so anything else is a typo.
            _edit.TextChanged += delegate
            {
                string t = _edit.Text, keep = "";
                foreach (char c in t) { if (c >= '0' && c <= '9') keep += c; }
                if (keep != t) _edit.Text = keep;
            };
            _edit.LostFocus += delegate { CommitEdit(); };
            Controls.Add(_edit);
            _edit.Focus();
            _edit.SelectAll();
            Invalidate();
        }

        void EditKey(object sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; CommitEdit(); }
            else if (e.KeyCode == Keys.Escape) { e.SuppressKeyPress = true; CancelEdit(); }
        }

        public void CommitEdit()
        {
            if (_edit == null) return;
            TextBox box = _edit;
            _edit = null;                       // clears first, so the LostFocus
            _editing = false;                   // fired by Remove is a no-op
            int pct;
            if (int.TryParse(box.Text, out pct)) Value = ToAlpha(pct);
            Controls.Remove(box);
            box.Dispose();
            Invalidate();
        }

        public void CancelEdit()
        {
            if (_edit == null) return;
            TextBox box = _edit;
            _edit = null;
            _editing = false;
            Controls.Remove(box);
            box.Dispose();
            Invalidate();
        }

        int ValueFromX(int x)
        {
            // Matches the rail exactly: dragging to the very edge of the control
            // has to reach the very edge of the range, or the ends are unreachable.
            int padX = 2, spanX = Width - 4;
            if (spanX <= 0) return Minimum;
            double t = (x - padX) / (double)spanX;
            if (t < 0) t = 0;
            if (t > 1) t = 1;
            return Minimum + (int)Math.Round(t * (Maximum - Minimum));
        }

        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) {
                if (!Compact && ReadoutRect.Contains(e.X, e.Y)) { BeginEdit(); base.OnMouseDown(e); return; }
                _drag = true; Value = ValueFromX(e.X);
            }
            base.OnMouseDown(e);
        }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            if (_drag) Value = ValueFromX(e.X);
            // the number is a button as much as a readout, so it says so
            bool onNumber = !Compact && ReadoutRect.Contains(e.X, e.Y);
            Cursor = onNumber ? Cursors.IBeam : Cursors.Hand;
            if (onNumber != _onNumber) { _onNumber = onNumber; Invalidate(); }
            base.OnMouseMove(e);
        }
        protected override void OnMouseUp(MouseEventArgs e) { _drag = false; base.OnMouseUp(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            g.Clear(BackColor);

            double t = (_value - Minimum) / (double)(Maximum - Minimum);
            int pad = 8, span = Width - pad * 2;

            if (Compact)
            {
                // one thin rail, vertically centred; no readout, no word
                int cy = Height / 2;
                Rectangle railC = new Rectangle(pad, cy - 2, span, 4);
                using (GraphicsPath rp = Draw.Round(railC, 2))
                using (SolidBrush rb = new SolidBrush(Palette.Track))
                    g.FillPath(rb, rp);

                int fw = (int)(span * t);
                if (fw > 1)
                {
                    using (GraphicsPath fp = Draw.Round(new Rectangle(pad, cy - 2, fw, 4), 2))
                    using (SolidBrush fb = new SolidBrush(Palette.Accent))
                        g.FillPath(fb, fp);
                }

                int kx2 = pad + (int)(span * t);
                int kd2 = _hover || _drag ? 14 : 12;
                Rectangle k2 = new Rectangle(kx2 - kd2 / 2, cy - kd2 / 2, kd2, kd2);
                using (SolidBrush kb2 = new SolidBrush(Palette.Text)) g.FillEllipse(kb2, k2);
                using (SolidBrush ic2 = new SolidBrush(Palette.Accent))
                    g.FillEllipse(ic2, k2.X + kd2 / 2 - 2, k2.Y + kd2 / 2 - 2, 4, 4);
                return;
            }

            string pct = Percent + "%";

            // The number sits in a rounded well so it reads as a field you can
            // click into, and the word beside it says what the number means.
            Rectangle well = ReadoutRect;
            using (GraphicsPath wp = Draw.Round(well, 8))
            {
                using (SolidBrush wb = new SolidBrush(_onNumber || _editing ? Palette.Surface : Palette.Track))
                    g.FillPath(wb, wp);
                using (Pen wl = new Pen(_onNumber || _editing ? Palette.Line : Palette.Track))
                    g.DrawPath(wl, wp);
            }

            if (!_editing)
            {
                using (SolidBrush tb = new SolidBrush(Palette.Text))
                using (SolidBrush mb = new SolidBrush(Palette.Muted))
                {
                    // The number is the percentage, not the raw alpha: the fail
                    // case is "200%" on a scale that stops at 100.
                    string n = Percent.ToString();
                    SizeF ns = g.MeasureString(n, Fonts.ReadBig);
                    float nx = well.X + 13;
                    float ny = well.Y + (well.Height - ns.Height) / 2 + 1;
                    g.DrawString(n, Fonts.ReadBig, tb, nx, ny);
                    SizeF ss = g.MeasureString("%", Fonts.ReadSign);
                    g.DrawString("%", Fonts.ReadSign, mb, nx + ns.Width - 4, ny + ns.Height - ss.Height - 1);

                    string word = _value >= 250 ? "solid"
                                : (_value >= 160 ? "mostly solid"
                                : (_value >= 100 ? "balanced" : "see-through"));
                    SizeF ws = g.MeasureString(word, Fonts.ReadSmall);
                    g.DrawString(word, Fonts.ReadSmall, mb, well.Right + 12,
                                 well.Y + (well.Height - ws.Height) / 2);
                }
            }

            int railY = Height - 20;
            int railPad = 2, railSpan = Width - 4;
            Rectangle rail = new Rectangle(railPad, railY, railSpan, 4);
            using (GraphicsPath rp = Draw.Round(rail, 2))
            using (SolidBrush rb = new SolidBrush(Palette.Track))
                g.FillPath(rb, rp);

            int fillW = (int)(railSpan * t);
            if (fillW > 1)
            {
                Rectangle fr = new Rectangle(railPad, railY, fillW, 4);
                using (GraphicsPath fp = Draw.Round(fr, 2))
                using (SolidBrush fb = new SolidBrush(Palette.Accent))
                    g.FillPath(fb, fp);
            }

            int kx = railPad + (int)(railSpan * t);
            int kd = _hover || _drag ? 15 : 13;
            Rectangle k = new Rectangle(kx - kd / 2, railY + 2 - kd / 2, kd, kd);
            using (SolidBrush kb = new SolidBrush(Palette.Text)) g.FillEllipse(kb, k);
            using (SolidBrush ic = new SolidBrush(Palette.Bg))
                g.FillEllipse(ic, k.X + kd / 2 - 2, k.Y + kd / 2 - 2, 4, 4);
        }
    }

    // --------------------------------------------------------------- hotkeys
    public class HotkeyWindow : NativeWindow, IDisposable
    {
        public event Action<int> Pressed;
        // Raised when the shell has restarted. Explorer owns the notification
        // area, and every icon in it is destroyed when it exits: a tray icon that
        // is not put back leaves a program that is still running with no way to
        // see or click it, which reads exactly like the program has gone.
        public event Action TaskbarRecreated;
        readonly List<int> _ids = new List<int>();
        readonly uint _taskbarCreated;

        public HotkeyWindow()
        {
            // The message Explorer broadcasts after it starts. Registered before
            // the handle exists so no restart can slip between the two.
            _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
            CreateHandle(new CreateParams());
        }

        public bool Register(int id, uint mods, uint vk)
        {
            bool ok = RegisterHotKey(Handle, id, mods, vk);
            if (ok) _ids.Add(id);
            return ok;
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0312 && Pressed != null) Pressed(m.WParam.ToInt32());
            if (_taskbarCreated != 0 && (uint)m.Msg == _taskbarCreated && TaskbarRecreated != null)
                TaskbarRecreated();
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            foreach (int id in _ids) UnregisterHotKey(Handle, id);
            _ids.Clear();
            DestroyHandle();
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern uint RegisterWindowMessage(string name);
        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    }

    // -------------------------------------------------------------- hover strip
    // A small control bar that sits inside the mini player and only appears while
    // the pointer is over the player. It is its own topmost window: the real mini
    // player belongs to Chromium and cannot host child controls.
    //
    // There is no plate behind it. The bar is a per-pixel layered window
    // (UpdateLayeredWindow), drawn into a 32bpp bitmap, so only the slider and
    // the icons exist on screen and the gaps between them are genuinely
    // click-through to the video underneath. Fading multiplies every pixel's
    // alpha, which is why it can follow the player's opacity without the
    // washed-out border a solid card would show.
    public class HoverStrip : Form
    {
        public int Value = 255;
        public bool ClickOn = false;
        public bool LockOn = false;
        public bool Syncing;

        public event Action<int> Scrub;      // dragging the slider
        public event Action ClickToggle;
        public event Action OpenPanel;
        public event Action LockToggle;
        public event Action QuitRequested;
        public event Action PercentRequested; // clicking the percentage

        const int BarH = 34;
        const int Pad = 4;
        const int IconBox = 24;
        const int PctBox = 38;

        Timer _fade;
        Bitmap _canvas;            // reused paint target: see Render()
        Graphics _canvasG;
        double _target = 1.0;
        double _factor = 0.0;      // fade position, 0..1
        double _base = 1.0;        // follows the player's opacity
        bool _hideWhenDone;

        bool _dragging;
        // Set by Release(). Queued BeginInvoke work can land afterwards and would
        // otherwise call into a disposed timer or a disposed bitmap.
        bool _gone;
        int _hover = -1;           // 0 slider, 1 click icon, 2 panel icon, 3 percent, 4 lock, 5 quit

        public HoverStrip()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            ClientSize = new Size(320, BarH);
            SetStyle(ControlStyles.OptimizedDoubleBuffer, true);

            _fade = new Timer();
            _fade.Interval = 16;
            _fade.Tick += delegate
            {
                double d = _target - _factor;
                if (Math.Abs(d) < 0.05)
                {
                    _factor = _target;
                    Render();
                    _fade.Stop();
                    if (_hideWhenDone) { Hide(); _hideWhenDone = false; }
                    return;
                }
                _factor += d * 0.35;
                Render();
            };
        }

        // No border, no background: the window is a canvas for the bitmap.
        protected override void OnPaintBackground(PaintEventArgs e) { }
        protected override void OnPaint(PaintEventArgs e) { }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00080000;   // WS_EX_LAYERED: we paint it ourselves
                cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE
                cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW: stays out of alt-tab
                return cp;
            }
        }

        // ---------------------------------------------------------- geometry
        // Left to right: the percentage, the rail, then four icons. The
        // percentage sits in its own hit area so clicking it opens a typing field
        // instead of jumping the opacity to wherever the pointer landed.
        public Rectangle PctRect { get { return new Rectangle(Pad, (BarH - 20) / 2, PctBox, 20); } }
        public int SliderLeft { get { return Pad + PctBox + 8; } }
        public int SliderRight { get { return Width - Pad - IconBox * 4 - 6; } }
        public Rectangle DragRect { get { return new Rectangle(SliderLeft - 5, 2, Math.Max(20, SliderRight - SliderLeft + 10), BarH - 4); } }
        public Rectangle ClickRect { get { return new Rectangle(SliderRight + 4, (BarH - IconBox) / 2, IconBox, IconBox); } }
        public Rectangle PanelRect { get { return new Rectangle(SliderRight + 4 + IconBox, (BarH - IconBox) / 2, IconBox, IconBox); } }
        public Rectangle LockRect { get { return new Rectangle(SliderRight + 4 + IconBox * 2, (BarH - IconBox) / 2, IconBox, IconBox); } }
        public Rectangle QuitRect { get { return new Rectangle(SliderRight + 4 + IconBox * 3, (BarH - IconBox) / 2, IconBox, IconBox); } }

        // The strip's whole client area is one continuous target. Not just the
        // painted parts: a press a pixel wide of the last icon used to fall
        // through to the video, and in a mini player a stray click on the video
        // toggles playback - so a near miss did not feel like a miss, it felt
        // like the wrong button. Nothing outside the window passes through, so
        // the video is still clickable either side of the bar.
        public Rectangle BodyRect
        {
            get { return new Rectangle(0, 0, Math.Max(1, Width), BarH); }
        }

        // 0..100 for display and for the typing field.
        public int Percent { get { return (int)Math.Round(Value / 255.0 * 100); } }

        // Sized to the player: the bar never spills outside the video. The floor
        // is wide enough for a legible percentage, a usable rail and four icons.
        public void LayoutTo(int playerW, int playerH)
        {
            int w = Math.Min(386, Math.Max(240, playerW - 24));
            Width = w;
            Height = BarH;
            Render();
        }

        int ValueFromX(int x)
        {
            int a = SliderLeft, b = SliderRight;
            if (b <= a) return 40;
            double t = (x - a) / (double)(b - a);
            if (t < 0) t = 0;
            if (t > 1) t = 1;
            return 40 + (int)Math.Round(t * (255 - 40));
        }

        // ------------------------------------------------------------- paint
        // The bar has no background plate, so it is painted as a 32bpp image and
        // blended per pixel by the window manager.
        void ApplyLayered(Bitmap bmp)
        {
            Layered.Draw(Handle, bmp, Left, Top);
        }

        public void Render()
        {
            if (_gone) return;
            if (!IsHandleCreated) return;
            double a = _factor * _base;
            if (a < 0) a = 0;
            if (a > 1) a = 1;

            int w = Math.Max(40, Width), h = Math.Max(BarH, Height);
            // The bar repaints on every fade tick and every hover change, so the
            // canvas and its Graphics are kept between paints: allocating a 32bpp
            // bitmap per frame is the single most expensive thing this loop did.
            if (_canvas == null || _canvas.Width != w || _canvas.Height != h)
            {
                if (_canvas != null) { _canvasG.Dispose(); _canvas.Dispose(); }
                _canvas = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                _canvasG = Graphics.FromImage(_canvas);
                _canvasG.SmoothingMode = SmoothingMode.AntiAlias;
                _canvasG.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            }
            _canvasG.Clear(Color.Transparent);
            // Hit testing of a layered window follows its alpha: a pixel at
            // alpha zero lets the mouse straight through to whatever is behind.
            // Clearing to nothing therefore punched invisible holes in the bar
            // between the rail and the icons, and every click that landed in one
            // went to the video instead - which read as the bar ignoring the
            // press. One step of alpha (1/255, invisible on screen) across the
            // bar's own body makes it one continuous target instead.
            //
            // The plate stops at the body rather than covering the whole window:
            // the few pixels of margin at each end stay transparent, so a click
            // there reaches the video exactly as it did before instead of being
            // swallowed by a surface that draws nothing at that point.
            Rectangle hitBand = BodyRect;
            using (SolidBrush plate = new SolidBrush(Color.FromArgb(_factor > 0.15 ? 1 : 0, 0, 0, 0)))
                _canvasG.FillRectangle(plate, hitBand);
            DrawBar(_canvasG, a);
            ApplyLayered(_canvas);
        }

        // Every colour is pre-multiplied by the fade, so the whole bar dims
        // together and nothing is left at full strength.
        Color Tint(Color c, double a)
        {
            int al = (int)Math.Round(255 * a);
            if (al <= 0) return Color.Transparent;
            return Color.FromArgb(al, c);
        }

        void DrawBar(Graphics g, double a)
        {
            int cy = BarH / 2;
            int x0 = SliderLeft, x1 = SliderRight;

            // the percentage, as a small well so it reads as something you can
            // click rather than a label: clicking it is the way to type a value
            Rectangle pct = PctRect;
            using (GraphicsPath pw = Draw.Round(pct, 6))
            using (SolidBrush pb = new SolidBrush(Tint(_hover == 3 ? Palette.Track : Color.FromArgb(70, Palette.Track), a)))
                g.FillPath(pb, pw);

            // Full-strength text even when the bar is not hovered: the number
            // is the only numeric feedback on this surface, so it stays the
            // brightest thing in the well rather than a hint.
            TextRenderer.DrawText(g, Percent + "%", Fonts.BarPct, pct,
                Tint(Palette.Text, a),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);

            // track
            int th = 4;
            using (GraphicsPath tp = Draw.Round(new Rectangle(x0, cy - th / 2, Math.Max(8, x1 - x0), th), th / 2))
            using (SolidBrush tb = new SolidBrush(Tint(Palette.Track, a)))
                g.FillPath(tb, tp);

            // filled part, from the left up to the knob
            double t = (Value - 40) / 215.0;
            int kx = x0 + (int)Math.Round((x1 - x0) * t);
            if (kx > x0 + 1)
            {
                int fw = kx - x0;
                using (GraphicsPath fp = Draw.Round(new Rectangle(x0, cy - th / 2, fw, th), th / 2))
                using (SolidBrush fb = new SolidBrush(Tint(Palette.Accent, a * 0.92)))
                    g.FillPath(fb, fp);
            }

            // knob: grows a little while the pointer is on the bar
            int kd = (_hover == 0) ? 13 : 11;
            using (SolidBrush kb = new SolidBrush(Tint(Palette.Text, a)))
                g.FillEllipse(kb, kx - kd / 2, cy - kd / 2, kd, kd);

            // the four icons that remain
            DrawClickIcon(g, ClickRect, a);
            DrawFadersIcon(g, PanelRect, a);
            DrawLockIcon(g, LockRect, a);
            DrawQuitIcon(g, QuitRect, a);
        }

        // A padlock: the body is a small rounded rectangle, the shackle an arc
        // that sits open when the frame is free and closed when it is locked, so
        // the icon states which way the switch is without needing a tooltip.
        void DrawLockIcon(Graphics g, Rectangle box, double a)
        {
            Color fg = LockOn ? Palette.Accent : (_hover == 4 ? Palette.Text : Palette.Muted);
            int cx = box.X + box.Width / 2, cy = box.Y + box.Height / 2;
            using (Pen pen = new Pen(Tint(fg, a), 1.5f))
            using (SolidBrush brush = new SolidBrush(Tint(fg, a)))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                Rectangle body = new Rectangle(cx - 5, cy, 10, 8);
                if (LockOn)
                {
                    using (GraphicsPath bp = Draw.Round(body, 2))
                        g.FillPath(brush, bp);
                    // Closed shackle, its feet sunk a pixel into the body so the
                    // two shapes read as one object at bar size.
                    g.DrawArc(pen, cx - 3, cy - 6, 6, 8, 180, 180);
                }
                else
                {
                    using (GraphicsPath bp = Draw.Round(body, 2))
                        g.DrawPath(pen, bp);
                    // The shackle swung open to the right: free to move. It still
                    // has to touch the body at one end, or at 24 pixels it reads as
                    // a stray hook floating above the lock rather than a shackle.
                    g.DrawArc(pen, cx + 1, cy - 7, 6, 9, 170, 165);
                }
            }
        }

        // A plain cross: the one glyph that needs no explanation at this size, and
        // it is what the panel's own close button uses.
        void DrawQuitIcon(Graphics g, Rectangle box, double a)
        {
            Color fg = (_hover == 5) ? Palette.Text : Palette.Muted;
            int cx = box.X + box.Width / 2, cy = box.Y + box.Height / 2;
            using (Pen pen = new Pen(Tint(fg, a), 1.6f))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                g.DrawLine(pen, cx - 5, cy - 5, cx + 5, cy + 5);
                g.DrawLine(pen, cx + 5, cy - 5, cx - 5, cy + 5);
            }
        }

        void DrawClickIcon(Graphics g, Rectangle box, double a)
        {
            Color fg = ClickOn ? Palette.Accent : (_hover == 1 ? Palette.Text : Palette.Muted);
            int cx = box.X + box.Width / 2, cy = box.Y + box.Height / 2;
            using (Pen pen = new Pen(Tint(fg, a), 1.6f))
            using (SolidBrush brush = new SolidBrush(Tint(fg, a)))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round;
                Point[] arrow = new Point[] {
                    new Point(cx - 5, cy - 7), new Point(cx - 5, cy + 5),
                    new Point(cx - 1, cy + 2), new Point(cx + 2, cy + 7),
                    new Point(cx + 4, cy + 6), new Point(cx + 1, cy + 1),
                    new Point(cx + 5, cy - 1)
                };
                using (GraphicsPath ap = new GraphicsPath())
                {
                    ap.AddPolygon(arrow);
                    if (ClickOn) g.FillPath(brush, ap); else g.DrawPath(pen, ap);
                }
                if (ClickOn)
                {
                    using (Pen slash = new Pen(Tint(Palette.Bg, a), 1.8f))
                        g.DrawLine(slash, cx - 7, cy + 8, cx + 7, cy - 8);
                }
            }
        }

        void DrawFadersIcon(Graphics g, Rectangle box, double a)
        {
            Color fg = (_hover == 2) ? Palette.Text : Palette.Muted;
            int cx = box.X + box.Width / 2, cy = box.Y + box.Height / 2;
            using (Pen pen = new Pen(Tint(fg, a), 1.6f))
            using (SolidBrush brush = new SolidBrush(Tint(fg, a)))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                for (int i = 0; i < 3; i++)
                {
                    int y = cy - 5 + i * 5;
                    int knob = cx - 3 + i * 3;
                    g.DrawLine(pen, cx - 7, y, cx + 7, y);
                    g.FillEllipse(brush, knob - 2, y - 2, 4, 4);
                }
            }
        }

        // ------------------------------------------------------------- mouse
        // Two things made a press feel unreliable even once the window was on
        // top. The first was the bar's own alpha: a layered window only takes
        // the mouse where it has painted, so the gaps between the controls were
        // holes a click fell straight through (see Render).
        //
        // The second was the hit testing itself. Four 24px icons sit shoulder to
        // shoulder, so "the first rectangle within a couple of pixels" let the
        // left edge of one icon fire its neighbour. The icons are now four
        // contiguous columns resolved by arithmetic, which cannot overlap, and a
        // column counts for the bar's whole height: vertically there is nothing
        // else to hit, so demanding the middle 24 pixels of a 34 pixel strip was
        // asking the pointer to be more precise than it needs to be.
        int IconColumn(Point p)
        {
            int left = SliderRight + 4;
            if (p.Y < 0 || p.Y >= BarH) return -1;
            if (p.X < left || p.X >= left + IconBox * 4) return -1;
            return (p.X - left) / IconBox;
        }

        int IconAt(Point p)
        {
            switch (IconColumn(p))
            {
                case 0: return 1;
                case 1: return 2;
                case 2: return 4;
                case 3: return 5;
            }
            return -1;
        }

        // The percentage well is small because the number is small, but it is a
        // discrete target like an icon, so it gets the same treatment. It also
        // absorbs the two or three pixels before the rail starts, so there is no
        // hairline gap between the two where a press does nothing.
        bool PctHit(Point p)
        {
            Rectangle r = PctRect;
            return p.Y >= 0 && p.Y < BarH &&
                   p.X >= r.Left - 2 && p.X < r.Right + 3;
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) { base.OnMouseDown(e); return; }
            if (PctHit(e.Location)) { if (PercentRequested != null) PercentRequested(); return; }
            switch (IconAt(e.Location))
            {
                case 1: if (ClickToggle != null) ClickToggle(); return;
                case 2: if (OpenPanel != null) OpenPanel(); return;
                case 4: if (LockToggle != null) LockToggle(); return;
                case 5: if (QuitRequested != null) QuitRequested(); return;
            }
            if (DragRect.Contains(e.Location))
            {
                _dragging = true;
                SetFromMouse(e.X);
                return;
            }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            if (_dragging)
            {
                // The button can come up outside the bar, and then OnMouseUp is
                // never called: without this, moving back over the bar keeps
                // scrubbing the opacity with no button held.
                if ((Control.MouseButtons & MouseButtons.Left) == 0) { _dragging = false; }
                else { SetFromMouse(e.X); return; }
            }
            int was = _hover;
            int icon = IconAt(e.Location);
            _hover = PctHit(e.Location) ? 3
                   : icon >= 0 ? icon
                   : DragRect.Contains(e.Location) ? 0 : -1;
            if (_hover != was) Render();
            Cursor = _hover == 3 ? Cursors.IBeam : (_hover >= 0 ? Cursors.Hand : Cursors.Default);
            base.OnMouseMove(e);
        }

        protected override void OnMouseUp(MouseEventArgs e) { _dragging = false; base.OnMouseUp(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = -1; Render(); base.OnMouseLeave(e); }

        void SetFromMouse(int x)
        {
            int v = ValueFromX(x);
            if (v == Value) return;
            Value = v;
            Render();
            if (Scrub != null) Scrub(v);
        }

        // ----------------------------------------------------------- opacity
        // Called when the saved opacity changes.
        public void SetBase(int alpha)
        {
            if (InvokeRequired) { BeginInvoke((MethodInvoker)delegate { SetBase(alpha); }); return; }
            double b = alpha / 255.0;
            // Track the player closely, but keep a floor: below roughly a third
            // the bar stops being readable over bright video.
            if (b < 0.35) b = 0.35;
            _base = b;
            Render();
        }

        public void SyncAlpha(int alpha)
        {
            if (InvokeRequired) { BeginInvoke((MethodInvoker)delegate { SyncAlpha(alpha); }); return; }
            Value = alpha;
            Render();
        }

        public void SyncClicks(bool on)
        {
            if (InvokeRequired) { BeginInvoke((MethodInvoker)delegate { SyncClicks(on); }); return; }
            ClickOn = on;
            Render();
        }

        public void SyncLock(bool on)
        {
            if (InvokeRequired) { BeginInvoke((MethodInvoker)delegate { SyncLock(on); }); return; }
            if (LockOn == on) return;
            LockOn = on;
            Render();
        }

        // The bar can arrive under a pointer that is already sitting still: the
        // pointer never moves, so Windows never sends a move message, and the
        // control underneath it stays highlighted as nothing. Asking where the
        // pointer is when the bar is placed costs one call and makes the first
        // frame correct.
        public void SyncHover()
        {
            if (InvokeRequired) { BeginInvoke((MethodInvoker)delegate { SyncHover(); }); return; }
            if (_gone || !Visible) return;
            Point p = PointToClient(Cursor.Position);
            int was = _hover;
            int icon = IconAt(p);
            _hover = PctHit(p) ? 3
                   : icon >= 0 ? icon
                   : DragRect.Contains(p) ? 0 : -1;
            if (_hover != was) Render();
        }

        // Is a fade in flight? The main loop uses this to decide whether it has
        // to pump at frame rate: a fade needs every tick to look smooth, while a
        // bar that is simply sitting there does not.
        public bool Animating
        {
            get
            {
                // The main loop asks this every tick, including the tick where
                // the bar is being released, so a disposed timer must answer
                // "no" rather than throw inside the message loop.
                if (_gone || _fade == null) return false;
                return _fade.Enabled && Math.Abs(_target - _factor) > 0.01;
            }
        }

        public void FadeIn()
        {
            if (InvokeRequired) { BeginInvoke((MethodInvoker)delegate { FadeIn(); }); return; }
            if (_gone) return;
            _hideWhenDone = false;
            _target = 1.0;
            if (_factor < 0.99) { _fade.Start(); }
            // Already fully visible: nothing to fade and nothing to redraw.
            // Step-Strip calls this every tick while the pointer is over the
            // player, and re-rendering an unchanged bar was the hottest paint
            // path in the app.
        }

        // An in-flight fade-out is reversed rather than restarted, so re-entering
        // the player does not flash the bar from nothing.
        public void Reveal() { FadeIn(); }

        public void FadeOutAndHide()
        {
            if (InvokeRequired) { BeginInvoke((MethodInvoker)delegate { FadeOutAndHide(); }); return; }
            if (_gone) return;
            _hideWhenDone = true;
            _target = 0.0;
            _fade.Start();
        }

        public void Vanish()
        {
            if (InvokeRequired) { BeginInvoke((MethodInvoker)delegate { Vanish(); }); return; }
            if (_gone) return;
            _fade.Stop();
            _factor = 0.0; _target = 0.0; _hideWhenDone = false;
            Render();
            Hide();
        }

        public void StopFade()
        {
            if (_gone) return;
            _fade.Stop();
            if (_hideWhenDone) { Hide(); _hideWhenDone = false; }
        }

        public void Release()
        {
            // Marked first: a BeginInvoke posted to this control can still arrive
            // after the timer is disposed, and calling Start() on a disposed timer
            // throws inside the message loop where nothing catches it.
            _gone = true;
            _fade.Stop();
            _fade.Dispose();
            if (_canvasG != null) { _canvasG.Dispose(); _canvasG = null; }
            if (_canvas != null) { _canvas.Dispose(); _canvas = null; }
            Dispose();
        }
    }


    // A rounded well with a borderless box inside it. A bare TextBox sitting on
    // the dark panel reads as a hole rather than a field, and gives no hint that
    // it is editable until the caret appears; the well and the border say so.
    //
    // A recordable field is a different thing: instead of typing a key name, the
    // user presses the combination. It is read-only and fills itself in, because
    // spelling "Ctrl+Alt+Shift+P" by hand is exactly the kind of typing that
    // produces bindings nobody meant.
    public class Field : Panel
    {
        public TextBox Box;
        public event EventHandler Committed;
        /// <summary>When true, this box captures a key combination instead of text.</summary>
        public bool Recordable
        {
            get { return _recordable; }
            set { _recordable = value; if (Box != null) Box.ReadOnly = value; }
        }
        public bool Recording;
        bool _recordable;
        bool _focus;
        bool _digits;
        string _before = "";
        // Modifiers seen going down during this capture. Sampling
        // Control.ModifierKeys only when the main key arrives is what used to
        // lose the Alt: with Alt held the press arrives as WM_SYSKEYDOWN, the
        // system offers it to the menu path first, and by the time the box sees
        // its KeyDown the Alt has already been consumed. So each modifier press
        // is remembered here and merged in instead.
        int _latched;

        public Field(string text, bool digitsOnly)
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Palette.Surface;
            Height = 24;
            _digits = digitsOnly;

            Box = new TextBox();
            Box.BorderStyle = BorderStyle.None;
            Box.BackColor = Palette.Surface;
            Box.ForeColor = Palette.Text;
            Box.Font = new Font("Segoe UI", 9f);
            Box.Text = text;
            if (digitsOnly)
            {
                Box.TextChanged += delegate
                {
                    if (Recording) return;
                    string t = Box.Text, keep = "";
                    foreach (char c in t) { if (c >= '0' && c <= '9') keep += c; }
                    if (keep != t) Box.Text = keep;
                };
            }
            Box.GotFocus += delegate { _focus = true; Invalidate(); };
            // Committing on lost focus as well as Enter: a settings box that only
            // saved on Enter would silently throw away a value the user typed and
            // then clicked away from.
            Box.LostFocus += delegate
            {
                _focus = false;
                Invalidate();
                // Leaving a box that is waiting for a keypress must not save the
                // "press keys" placeholder as if it were a binding.
                if (Recording) { CancelRecord(); return; }
                if (Committed != null) Committed(this, EventArgs.Empty);
            };
            Box.KeyDown += delegate(object s, KeyEventArgs e)
            {
                if (Recording)
                {
                    CaptureKey(e);
                    return;
                }
                if (e.KeyCode == Keys.Enter)
                {
                    e.SuppressKeyPress = true;
                    if (Recordable) { BeginRecord(); return; }
                    if (Committed != null) Committed(this, EventArgs.Empty);
                }
            };
            // A click is the obvious way to say "record this one". Read-only boxes
            // still get mouse messages, so it works without a second control.
            Box.MouseDown += delegate
            {
                if (Recordable && !Recording) BeginRecord();
            };
            Controls.Add(Box);

            // A field is one of the few things in this window that can be wider
            // than the space it is given, and the panel no longer resizes, so a
            // long binding or preset name is simply clipped. Hovering is how the
            // rest of it is read. Both the box and the panel around it arm the
            // same tip, because the pointer can be over either.
            Box.MouseEnter += delegate { ArmTip(); };
            Box.MouseLeave += delegate { Tips.Disarm(this); };
            MouseEnter += delegate { ArmTip(); };
            MouseLeave += delegate { Tips.Disarm(this); };
            Box.TextChanged += delegate { if (Tips.IsOpen) Tips.Hide(); };
        }

        void ArmTip()
        {
            // Not while a capture is running: the box is showing an instruction
            // rather than a binding, and there is nothing clipped to explain.
            if (Recording || Box == null) return;
            Tips.Arm(this, delegate { return Box.Text; });
        }

        public string Text2 { get { return Box.Text; } set { Box.Text = value; } }

        // Text set on a focused box arrives fully selected, which paints a bright
        // system-blue block across a monochrome window and scrolls the prompt to
        // its tail. Every value this control writes goes through here instead.
        void Put(string text)
        {
            Box.Text = text;
            Box.SelectionStart = 0;
            Box.SelectionLength = 0;
        }

        public void BeginRecord()
        {
            if (!Recordable || Recording) return;
            _before = Box.Text;
            Recording = true;
            _latched = 0;
            Hotkey.Raw = 0;
            Box.ReadOnly = true;
            Box.ForeColor = Palette.Muted;
            Put("press a key combination");
            Box.Focus();
            Invalidate();
        }

        // Two ends of the correction. Latch is called from the form's message
        // loop for every modifier going down; Unlatch runs on a modifier going
        // back up, so holding Ctrl, tapping Alt and then pressing a digit binds
        // Ctrl+1 rather than a Ctrl+Alt+1 that no finger is still holding.
        public void Latch(int bit) { _latched |= bit; }

        public void Unlatch(int bit) { _latched &= ~bit; }

        public int Latched { get { return _latched; } }

        // Called from the form's own message loop, before WinForms routes the
        // press to a control: by then the modifiers are gone. Not named Capture
        // because that hides System.Windows.Forms.Control.Capture and Add-Type
        // refuses the warning-as-error.
        public bool CaptureCombo(int vk, int mods)
        {
            if (!Recording) return false;
            int key = Hotkey.VkFrom((Keys)vk);
            if (key == 0)
            {
                // A key this app cannot register: say so instead of staying in
                // capture mode forever with no explanation.
                Put("that key cannot be used");
                return false;
            }
            if (mods == 0)
            {
                Put("hold Ctrl or Alt too");
                return false;
            }
            if (Hotkey.Unreachable(mods, key))
            {
                // Windows will not deliver this one, and RegisterHotKey still
                // says yes, so the box has to refuse it here or it saves a
                // binding that never fires.
                Put("Shift+keypad needs NumLock off");
                return false;
            }
            Recording = false;
            _latched = 0;
            Hotkey.Raw = 0;
            Box.ReadOnly = Recordable;
            Box.ForeColor = Palette.Text;
            Put(Hotkey.Format(mods, key));
            Invalidate();
            if (Committed != null) Committed(this, EventArgs.Empty);
            return true;
        }

        // Escape during a capture means "leave this binding alone"; Backspace
        // means "clear it". Both used to live in the box's KeyDown, but while a
        // capture runs the form intercepts the keys, so they live here now and
        // the box's handler stays as the fallback for any route that avoids it.
        public void Cancel()
        {
            if (!Recording) return;
            CancelRecord();
        }

        public void ClearBinding()
        {
            if (!Recording) return;
            Recording = false;
            _latched = 0;
            Hotkey.Raw = 0;
            Box.ReadOnly = Recordable;
            Box.ForeColor = Palette.Text;
            Put("");
            Invalidate();
            if (Committed != null) Committed(this, EventArgs.Empty);
        }

        void CancelRecord()
        {
            Recording = false;
            _latched = 0;
            Hotkey.Raw = 0;
            Box.ReadOnly = Recordable;
            Box.ForeColor = Palette.Text;
            Put(_before);
            Invalidate();
        }

        void CaptureKey(KeyEventArgs e)
        {
            e.SuppressKeyPress = true;
            e.Handled = true;

            if (e.KeyCode == Keys.Escape) { CancelRecord(); return; }
            if (e.KeyCode == Keys.Back)
            {
                // Backspace clears the binding: the same thing the old text box
                // meant by an empty string, without needing to select anything.
                Recording = false;
                Box.ReadOnly = Recordable;
                Box.ForeColor = Palette.Text;
                Put("");
                Invalidate();
                if (Committed != null) Committed(this, EventArgs.Empty);
                return;
            }

            // Modifier-only presses are the user still on the way to the real key.
            if (Hotkey.IsModifierOnly(e.KeyCode)) return;

            int mods = Hotkey.ModsFrom(Control.ModifierKeys) | _latched;
            int vk = Hotkey.VkFrom(e.KeyCode);
            if (vk == 0) { Put("that key needs Ctrl or Alt"); return; }
            if (mods == 0)
            {
                // A bare key would be swallowed system-wide, so it is refused
                // rather than quietly registered.
                Put("hold Ctrl or Alt too");
                return;
            }

            Recording = false;
            Box.ReadOnly = Recordable;
            Box.ForeColor = Palette.Text;
            Put(Hotkey.Format(mods, vk));
            Invalidate();
            if (Committed != null) Committed(this, EventArgs.Empty);
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            if (Box != null) Box.Bounds = new Rectangle(9, (Height - 20) / 2, Math.Max(10, Width - 18), 20);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            // The border brightens on focus: with no other chrome, this is the
            // only cue that keystrokes are going into this field and not another.
            using (Pen p = new Pen(_focus ? Palette.Text : Palette.Line))
                e.Graphics.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
        }
    }

    // Key combination text, in the same form the config stores and the parser
    // reads: "Ctrl+Alt+Shift+P". The UI has to produce it itself because this
    // assembly cannot call into the script that parses it.
    public static class Hotkey
    {
        public static bool IsModifierOnly(Keys k)
        {
            return k == Keys.ControlKey || k == Keys.LControlKey || k == Keys.RControlKey
                || k == Keys.Menu || k == Keys.LMenu || k == Keys.RMenu
                || k == Keys.ShiftKey || k == Keys.LShiftKey || k == Keys.RShiftKey
                || k == Keys.LWin || k == Keys.RWin;
        }

        public static int ModsFrom(Keys m)
        {
            int mods = 0;
            if ((m & Keys.Control) != 0) mods |= 0x2;
            if ((m & Keys.Alt) != 0) mods |= 0x1;
            if ((m & Keys.Shift) != 0) mods |= 0x4;
            return mods;
        }

        // The modifier state the message loop has actually seen. Control.ModifierKeys
        // reports what Windows considers held right now, which is not the same
        // thing during a capture: an Alt press can be swallowed by the menu path
        // before any control hears about it.
        public static int Raw;

        public static bool IsModifierOnlyVk(int vk)
        {
            return vk == 0x10 || vk == 0x11 || vk == 0x12
                || (vk >= 0xA0 && vk <= 0xA5)
                || vk == 0x5B || vk == 0x5C;
        }

        // Bit for a virtual key code, from the message stream rather than from a
        // Keys value: WndProc sees raw VKs and has no KeyEventArgs to consult.
        public static int BitForVk(int vk)
        {
            // Left and right variants share a bit: a binding says "Alt", not
            // "the right Alt", and registering both would double every hotkey.
            if (vk == 0x11 || vk == 0xA2 || vk == 0xA3) return 0x2;
            if (vk == 0x12 || vk == 0xA4 || vk == 0xA5) return 0x1;
            if (vk == 0x10 || vk == 0xA0 || vk == 0xA1) return 0x4;
            if (vk == 0x5B || vk == 0x5C) return 0x8;
            return 0;
        }

        public static void Observe(int msg, int vk)
        {
            int bit = BitForVk(vk);
            if (bit == 0) return;
            bool down = msg == 0x0100 || msg == 0x0104;
            if (down) Raw |= bit;
            else Raw &= ~bit;
        }

        // Only the keypad's digits are the ones NumLock swaps between numbers
        // and navigation keys, and that swap is what eats the Shift. Plus,
        // minus, multiply and divide mean the same thing either way, so Shift
        // with those still fires and must not be refused.
        public static bool IsNumpad(int vk)
        {
            return vk >= 0x60 && vk <= 0x69;
        }

        // A keypad key with Shift held and NumLock on is the one combination
        // Windows will not deliver. The keypad press is translated to the
        // navigation key and the Shift is consumed doing it, so a registration
        // for the keypad key can never match - and RegisterHotKey still returns
        // True, so the binding looks fine and then does nothing. Measured:
        // Ctrl+Alt+Shift+NumPad2 never fires with NumLock on, and fires with it
        // off. Better to say so than to store a key that cannot work.
        public static bool Unreachable(int mods, int vk)
        {
            return IsNumpad(vk) && (mods & 0x4) != 0 && Control.IsKeyLocked(Keys.NumLock);
        }

        // WinForms key codes already equal virtual key codes for everything this
        // app binds; the few that do not are translated, and anything else is
        // rejected with 0 so the caller can say so instead of binding a mystery.
        public static int VkFrom(Keys k)
        {
            if (k >= Keys.A && k <= Keys.Z) return (int)k;
            if (k >= Keys.D0 && k <= Keys.D9) return (int)k;
            if (k >= Keys.F1 && k <= Keys.F12) return (int)k;
            if (k >= Keys.NumPad0 && k <= Keys.NumPad9) return (int)k;
            switch (k)
            {
                case Keys.Up: return 0x26;
                case Keys.Down: return 0x28;
                case Keys.Left: return 0x25;
                case Keys.Right: return 0x27;
                case Keys.Space: return 0x20;
                case Keys.Oemplus: return 0xBB;
                case Keys.OemMinus: return 0xBD;
                case Keys.Add: return 0x6B;
                case Keys.Subtract: return 0x6D;
                case Keys.Home: return 0x24;
                case Keys.End: return 0x23;
                case Keys.PageUp: return 0x21;
                case Keys.PageDown: return 0x22;
                case Keys.Insert: return 0x2D;
            }
            return 0;
        }

        public static string Format(int mods, int vk)
        {
            List<string> parts = new List<string>();
            if ((mods & 0x2) != 0) parts.Add("Ctrl");
            if ((mods & 0x1) != 0) parts.Add("Alt");
            if ((mods & 0x4) != 0) parts.Add("Shift");
            if ((mods & 0x8) != 0) parts.Add("Win");
            parts.Add(Name(vk));
            return string.Join("+", parts.ToArray());
        }

        public static string Name(int vk)
        {
            switch (vk)
            {
                case 0x26: return "Up";
                case 0x28: return "Down";
                case 0x25: return "Left";
                case 0x27: return "Right";
                case 0x20: return "Space";
                case 0xBB: return "Plus";
                case 0xBD: return "Minus";
                // The numpad's plus and minus are separate keys, so they get
                // separate names: writing both as "Plus" would record a binding
                // for a key the user did not press.
                case 0x6B: return "NumPadPlus";
                case 0x6D: return "NumPadMinus";
                case 0x24: return "Home";
                case 0x23: return "End";
                case 0x21: return "PageUp";
                case 0x22: return "PageDown";
                case 0x2D: return "Insert";
            }
            if (vk >= 0x70 && vk <= 0x7B) return "F" + (vk - 0x6F).ToString();
            if (vk >= 0x60 && vk <= 0x69) return "NumPad" + (vk - 0x60).ToString();
            if (vk >= 0x30 && vk <= 0x39) return ((char)vk).ToString();
            if (vk >= 0x41 && vk <= 0x5A) return ((char)vk).ToString();
            return "";
        }
    }

    // Action -> the words shown beside its box. Kept here, in the same assembly
    // as the panel, so the settings window can lay itself out without the runtime
    // handing it a table; the runtime uses the same list to know what to save.
    public static class Labels
    {
        public static readonly string[,] Actions = new string[,] {
            { "up",       "More opaque" },
            { "down",     "More see-through" },
            { "solid",    "Solid again" },
            { "click",    "Click-through" },
            { "hide",     "Hide the player" },
            { "pick",     "Pick a window" },
            { "panel",    "Open the panel" },
            { "reset",    "Reset everything" },
            { "geometry", "Remember size" },
            { "lock",     "Lock the frame" },
            { "hover",    "Controls on hover" },
            { "ontop",    "Always on top" },
            { "quit",     "Quit pipfade" }
        };

        public static int Count { get { return Actions.GetLength(0); } }
        public static string Action(int i) { return Actions[i, 0]; }
        public static string Label(int i) { return Actions[i, 1]; }
    }

    // Three words with an underline under the current one. A tab strip rather
    // than a dropdown: these are three short, permanently relevant groups, and a
    // dropdown would hide two thirds of the settings for no gain.
    public class Segmented : Control
    {
        public string[] Items;
        public int Selected;
        public event EventHandler Changed;
        int _hover = -1;

        public Segmented(string[] items)
        {
            Items = items;
            Height = 26;
            Cursor = Cursors.Hand;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }

        int SegWidth { get { return Math.Max(1, Width / Items.Length); } }

        int HitTest(int x)
        {
            int i = x / SegWidth;
            if (i < 0) i = 0;
            if (i >= Items.Length) i = Items.Length - 1;
            return i;
        }

        public void Select(int index)
        {
            if (index < 0 || index >= Items.Length || index == Selected) return;
            Selected = index;
            Invalidate();
            if (Changed != null) Changed(this, EventArgs.Empty);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            int h = HitTest(e.X);
            if (h != _hover) { _hover = h; Invalidate(); }
            base.OnMouseMove(e);
        }
        protected override void OnMouseLeave(EventArgs e) { _hover = -1; Invalidate(); base.OnMouseLeave(e); }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) Select(HitTest(e.X));
            base.OnMouseDown(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(BackColor);
            using (Pen baseLine = new Pen(Palette.Line))
                g.DrawLine(baseLine, 0, Height - 1, Width - 1, Height - 1);

            using (Pen mark = new Pen(Palette.Text, 1.6f))
            {
                for (int i = 0; i < Items.Length; i++)
                {
                    Rectangle cell = new Rectangle(i * SegWidth, 0, SegWidth, Height - 1);
                    bool sel = i == Selected;
                    Color fg = sel || i == _hover ? Palette.Text : Palette.Muted;
                    TextRenderer.DrawText(g, Items[i], sel ? Fonts.TabOn : Fonts.TabOff, cell, fg,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                    if (sel) g.DrawLine(mark, cell.X + 10, Height - 2, cell.Right - 11, Height - 2);
                }
            }
        }
    }

    // The hover bar cannot host a text box: it is a layered window painted as a
    // bitmap, so it has no children to draw. Clicking its percentage opens this
    // tiny field on top of that spot instead, which is the smallest thing that
    // can really take a keystroke.
    public class StripEntry : Form
    {
        public TextBox Box;
        public event Action<int> Applied;
        public event Action Done;
        bool _closing;

        public StripEntry()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            ClientSize = new Size(78, 30);
            BackColor = Palette.Surface;
            TopMost = true;

            Box = new TextBox();
            Box.BorderStyle = BorderStyle.None;
            Box.BackColor = Palette.Surface;
            Box.ForeColor = Palette.Text;
            Box.Font = new Font("Segoe UI Semibold", 12f);
            Box.Bounds = new Rectangle(10, 5, 58, 22);
            Box.TextChanged += delegate
            {
                string t = Box.Text, keep = "";
                foreach (char c in t) { if (c >= '0' && c <= '9') keep += c; }
                if (keep != t) Box.Text = keep;
            };
            Box.KeyDown += delegate(object s, KeyEventArgs e)
            {
                if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; Apply(); }
                else if (e.KeyCode == Keys.Escape) { e.SuppressKeyPress = true; Finish(); }
            };
            Box.LostFocus += delegate { Apply(); };
            Controls.Add(Box);
        }

        void Apply()
        {
            // A LostFocus fired by closing the field must not commit anything:
            // it happens when the bar goes away, not because the user agreed.
            if (_closing) return;
            int pct;
            if (int.TryParse(Box.Text, out pct))
            {
                // Typed text has no upper bound of its own: 999 would otherwise
                // sail past the alpha range and be stored as an impossible value.
                if (pct < 0) pct = 0;
                if (pct > 100) pct = 100;
                if (Applied != null) Applied(pct);
            }
            Finish();
        }

        void Finish()
        {
            if (_closing) return;
            _closing = true;
            if (Done != null) Done();
            Close();
            Dispose();
        }

        // Closing because the bar is going away is not the user confirming a
        // value: closing quietly must not push a half-typed number through.
        public void CloseQuietly()
        {
            _closing = true;
            Close();
            Dispose();
        }

        public void Open(Point screen, int percent)
        {
            Box.Text = percent.ToString();
            Location = screen;
            Show();
            Activate();
            Box.Focus();
            Box.SelectAll();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            // A plain edge, brighter than the bar: the field has to be findable
            // against video of any colour, so it does not rely on translucency.
            using (Pen p = new Pen(Palette.Text))
                e.Graphics.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
        }

        // Windows enforces a minimum window size (SM_CXMINTRACK, 136x39 on this
        // machine) and quietly grows anything smaller. That turned this 78x30
        // field into a 136x39 slab. A popup whose edges are never dragged can
        // just refuse the limit.
        [StructLayout(LayoutKind.Sequential)]
        struct POINT { public int x, y; }

        [StructLayout(LayoutKind.Sequential)]
        struct MINMAXINFO
        {
            public POINT ptReserved, ptMaxSize, ptMaxPosition, ptMinTrackSize, ptMaxTrackSize;
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0024)        // WM_GETMINMAXINFO
            {
                MINMAXINFO mm = (MINMAXINFO)m.GetLParam(typeof(MINMAXINFO));
                mm.ptMinTrackSize.x = 1;
                mm.ptMinTrackSize.y = 1;
                Marshal.StructureToPtr(mm, m.LParam, false);
                m.Result = IntPtr.Zero;
                return;
            }
            base.WndProc(ref m);
        }
    }

    // The update notice is a row rather than a dialog: a modal box that
    // interrupts what you were already doing just to say a newer version exists
    // is worse than a line you can ignore. It sits above the footer, names the
    // version that is out, and opens the release page when clicked - the app
    // never replaces itself.
    public class UpdateNotice : Control
    {
        public string Version = "";
        bool _hover;

        public UpdateNotice()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
                     | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            Cursor = Cursors.Hand;
            BackColor = Color.Transparent;
        }

        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath p = Draw.Round(r, 7))
            {
                using (SolidBrush b = new SolidBrush(_hover ? Palette.Track : Palette.Surface)) g.FillPath(b, p);
                using (Pen pen = new Pen(_hover ? Palette.Hint : Palette.Line)) g.DrawPath(pen, p);
            }

            string label = Version.Length > 0 ? "v" + Version + " is available" : "An update is available";
            // Measured and placed by hand: TextRenderer's VerticalCenter flag is
            // ignored when NoPadding is also set, which left the text riding the
            // top edge with its ascenders cut off.
            Size ms = TextRenderer.MeasureText(label, Fonts.Notice, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPadding);
            int ty = (Height - ms.Height) / 2;
            Rectangle lr = new Rectangle(10, ty, Width - 30, ms.Height);
            TextRenderer.DrawText(g, label, Fonts.Notice, lr, _hover ? Palette.Text : Palette.Muted,
                                  TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);

            // The link is painted rather than a real LinkLabel: a child window
            // inside this row would paint a second background over the plate.
            string link = "Download";
            Size ls = TextRenderer.MeasureText(link, Fonts.Notice, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPadding);
            Rectangle dl = new Rectangle(Width - 10 - ls.Width, ty, ls.Width, ms.Height);
            TextRenderer.DrawText(g, link, Fonts.Notice, dl, _hover ? Palette.Text : Palette.Accent,
                                  TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            if (_hover)
                using (Pen pen = new Pen(Palette.Text))
                    g.DrawLine(pen, dl.Left, ty + ms.Height - 1, dl.Right, ty + ms.Height - 1);
        }
    }

    // ----------------------------------------------------------------- panel
    public class PanelForm : Form
    {
        public OpacitySlider Slider;
        public Switch ClickSwitch, GeometrySwitch, LockSwitch, AutoSwitch, KeepTopSwitch, StartupSwitch, HoverSwitch, HoldSwitch;
        public UpdateNotice Notice;
        public Action OpenDownload;
        // Whether the notice row is occupying layout space. Separate from
        // Notice.Visible because a child of an unshown form always reports false,
        // and this decision has to be right before the first Show.
        bool NoticeActive;
        public Segmented Tabs;
        public Panel PageControls, PageKeys, PagePresets;
        public Dictionary<string, Field> KeyFields;
        public List<Field> PresetNames, PresetKeys;
        public List<Label> PresetSummary;
        public List<GlyphButton> PresetApply, PresetSave, PresetRemove;
        public LinkLabel PresetAdd;
        public Label Status;
        public Action ResetRequested;
        public Action QuitRequested;
        public Action KeysChanged;
        /// <summary>Put this preset slot's settings back.</summary>
        public Action<int> PresetApplied;
        /// <summary>Store the live settings into this preset slot.</summary>
        public Action<int> PresetSaved;
        /// <summary>Forget this preset slot.</summary>
        public Action<int> PresetRemoved;
        public Action PresetAdded;
        public bool Syncing;
        // Four rows fit between the headers and the add link at 7.75pt. More than
        // that and the tab would scroll, which this window does not do.
        public const int MaxPresets = 4;

        Point _off;
        bool _drag;
        // Guards against saving the position on a plain click: a click is a
        // MouseDown plus a MouseUp with no actual travel.
        bool _moved;
        bool _closing;
        bool _building;
        // Set when the compositor is drawing the rim: the fallback stroke in
        // OnPaint must stay off in that case or two curves land on one corner.
        bool _dwmEdge;
        GlyphButton _minimise, _close;
        Label _name;
        LinkLabel _reset, _quit;
        Panel _divider;
        List<Label> _keyLabels;
        Label[] _presetHeads;
        Label _presetNote;

        public PanelForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = true;
            Text = "pipfade";
            // One size, and it cannot be dragged. The window holds a fixed set of
            // rows and a tab strip; letting it stretch only moved the frames
            // further apart. A field that ends up clipped says the rest of itself
            // on hover instead (see Tips).
            ClientSize = new Size(360, 470);
            MinimumSize = new Size(360, 470);
            MaximumSize = new Size(360, 470);
            BackColor = Palette.Bg;
            DoubleBuffered = true;
            // A multi-size icon: one bitmap squashed to 16px for the taskbar
            // turned into a pale smear. See Mark.AppIcon.
            Icon = Mark.AppIcon(Mark.ShellFore(Palette.Accent));

            Label name = new Label();
            name.Text = "pipfade";
            name.Font = new Font("Segoe UI Semibold", 10.5f);
            name.ForeColor = Palette.Text;
            name.AutoSize = true;
            name.BackColor = Color.Transparent;
            Controls.Add(name);
            _name = name;

            Status = new Label();
            Status.Text = "looking for a mini player";
            Status.Font = new Font("Segoe UI", 8f);
            Status.ForeColor = Palette.Muted;
            Status.AutoSize = false;
            Status.TextAlign = ContentAlignment.MiddleRight;
            Status.BackColor = Color.Transparent;
            Controls.Add(Status);

            GlyphButton minimise = new GlyphButton(GlyphButton.Kind.Minimize);
            // Minimise means minimise: the window goes to the taskbar, where its
            // button stays, and clicking that button brings it back. Hiding to the
            // tray is what the close button does.
            minimise.Click += delegate { WindowState = FormWindowState.Minimized; };
            Controls.Add(minimise);
            _minimise = minimise;

            GlyphButton close = new GlyphButton(GlyphButton.Kind.Close);
            close.Click += delegate { RequestClose(); };
            Controls.Add(close);
            _close = close;

            Tabs = new Segmented(new string[] { "Controls", "Hotkeys", "Presets" });
            Tabs.BackColor = Palette.Bg;
            Controls.Add(Tabs);

            PageControls = NewPage();
            PageKeys = NewPage();
            PagePresets = NewPage();

            _building = true;
            BuildControlsPage();
            BuildKeysPage();
            BuildPresetsPage();
            _building = false;

            Tabs.Changed += delegate { ShowPage(Tabs.Selected); };
            ShowPage(0);

            _divider = new Panel();
            _divider.BackColor = Palette.Line;
            Controls.Add(_divider);

            // Hidden until something actually knows a newer version exists. An
            // empty strip that says "up to date" is furniture; one that appears
            // only when there is news is information.
            Notice = new UpdateNotice();
            Notice.Visible = false;
            Notice.Click += delegate { if (OpenDownload != null) OpenDownload(); };
            Controls.Add(Notice);

            LinkLabel reset = new LinkLabel();
            reset.Text = "reset size, position and opacity";
            reset.Font = new Font("Segoe UI", 8.25f);
            reset.LinkColor = Palette.Muted;
            reset.ActiveLinkColor = Palette.Text;
            reset.VisitedLinkColor = Palette.Muted;
            reset.LinkBehavior = LinkBehavior.HoverUnderline;
            reset.AutoSize = true;
            reset.BackColor = Color.Transparent;
            reset.LinkClicked += delegate { if (ResetRequested != null) ResetRequested(); };
            Controls.Add(reset);
            _reset = reset;

            // Quitting has to be reachable from here as well as from the tray:
            // the tray icon is easy to lose in a crowded notification area, and
            // closing this window only hides it.
            LinkLabel quit = new LinkLabel();
            quit.Text = "quit pipfade";
            quit.Font = new Font("Segoe UI", 8.25f);
            quit.LinkColor = Palette.Muted;
            quit.ActiveLinkColor = Palette.Text;
            quit.VisitedLinkColor = Palette.Muted;
            quit.LinkBehavior = LinkBehavior.HoverUnderline;
            quit.AutoSize = false;
            quit.TextAlign = ContentAlignment.MiddleRight;
            quit.BackColor = Color.Transparent;
            quit.LinkClicked += delegate { if (QuitRequested != null) QuitRequested(); };
            Controls.Add(quit);
            _quit = quit;

            // A settings window opened with a keyboard shortcut should close with
            // one. Ctrl+Alt+A twice is two chords; Escape is the gesture everyone
            // already tries on a panel with no title bar.
            KeyPreview = true;
            KeyDown += delegate(object sender, KeyEventArgs e)
            {
                if (e.KeyCode != Keys.Escape) return;
                // Escape in a box that is waiting for a combination means "leave
                // this binding alone". KeyPreview runs the form first, so without
                // this check Escape would close the whole panel instead.
                if (AnyRecording()) return;
                e.Handled = true;
                e.SuppressKeyPress = true;
                RequestClose();
            };

            _dwmEdge = Corners.Frame(this, 12, Palette.Line);
            // Children are placed from the client size, so the first pass happens
            // here; every later resize repeats it.
            LayoutAll();
        }

        Panel NewPage()
        {
            // Clipped two pixels in from each edge. A child window paints over
            // its parent, so a page running edge to edge hid the rounded border
            // behind it for the whole height of the tab area: the stroke only
            // survived above and below, which is exactly what "the border does
            // not go around the whole thing" looked like. The pixels this
            // uncovers are the form's own background colour, so the only change
            // is that the border runs unbroken from top to bottom.
            Panel p = new Panel();
            p.BackColor = Palette.Bg;
            Controls.Add(p);
            return p;
        }

        // Every child is placed from the client size rather than from a list of
        // absolute points, so the whole window is one function rather than a pile
        // of arithmetic scattered through a dozen handlers. The size is fixed, so
        // this runs once - but it still reads the client size instead of
        // hardcoding points, because that is what keeps the numbers in one place.
        void LayoutAll()
        {
            if (Tabs == null) return;
            {
                int w = ClientSize.Width, h = ClientSize.Height;
                // The content column is the window minus a 18px margin each side,
                // capped at 520px and centred. Rows that read badly when
                // stretched (a switch and its name) get their own narrower cap
                // below.
                int inner = Math.Min(520, Math.Max(120, w - 36));
                int left = (w - inner) / 2;

                int closeX = w - 34;
                int minX = w - 58;
                if (_close != null) _close.Bounds = new Rectangle(closeX, 10, 24, 24);
                if (_minimise != null) _minimise.Bounds = new Rectangle(minX, 10, 24, 24);
                if (_name != null) _name.Location = new Point(42, 15);
                if (Status != null)
                {
                    // The status line gives up its width first: it truncates
                    // gracefully, the buttons do not.
                    int statusX = 126;
                    Status.Bounds = new Rectangle(statusX, 16, Math.Max(20, minX - 6 - statusX), 15);
                }

                Tabs.Bounds = new Rectangle(left, 42, inner, 26);

                // The footer used to leave a third of its space to a hotkey cheat
                // sheet; without it the divider and the two links sit closer to
                // the bottom edge and the tab area takes the difference.
                int dividerY = h - 46;
                int rowY = h - 36;
                int pageY = 76;
                // The update row borrows its height from the tab area rather
                // than hovering over it, so a page never has a control sitting
                // underneath a strip that can appear later.
                int noticeH = 28;
                // Not Notice.Visible: a child of a form that has not been shown
                // yet reports Visible as false no matter what was set on it, and
                // the announcement can easily arrive before the window does.
                bool notice = NoticeActive;
                int pageBottom = dividerY - 6 - (notice ? noticeH + 10 : 0);
                int pageH = Math.Max(120, pageBottom - pageY);

                if (Notice != null)
                    Notice.Bounds = new Rectangle(left, dividerY - 6 - noticeH, inner, noticeH);

                if (_divider != null) _divider.Bounds = new Rectangle(left, dividerY, inner, 1);
                if (_reset != null) _reset.Location = new Point(left, rowY);
                if (_quit != null) _quit.Bounds = new Rectangle(left + inner - 102, rowY, 102, 18);

                Rectangle pr = new Rectangle(2, 0, Math.Max(40, w - 6), pageH);
                Panel[] pages = new Panel[] { PageControls, PageKeys, PagePresets };
                foreach (Panel p in pages)
                {
                    if (p == null) continue;
                    p.Bounds = new Rectangle(0, pageY, w, pageH);
                    Region old = p.Region;
                    p.Region = new Region(pr);
                    if (old != null) old.Dispose();
                }

                LayoutControlsPage(left, inner, pageH);
                LayoutKeysPage(left, inner, pageH);
                LayoutPresetsPage(left, w, inner, pageH);
            }
        }

        void LayoutControlsPage(int left, int inner, int pageH)
        {
            if (Slider == null) return;
            // The switch rows keep a cap of their own inside the column. It never
            // bites at 360, but the row is what decides how far a switch sits
            // from the words it belongs to, and that is a reading-width question
            // rather than a window-width one.
            int rowW = Math.Min(340, inner);
            int rowX = left + (inner - rowW) / 2;
            Slider.Bounds = new Rectangle(rowX, 4, rowW, 58);

            // Eight rows sharing the space under the slider, spaced from the page
            // height so the group fills the tab rather than crowding its top.
            // The floor drops when the update row is on screen: that row is real
            // estate taken from the page, and eight rows at the old minimum
            // would push the last switch under the strip.
            int room = pageH - 78;
            int pitch = Math.Max(NoticeActive ? 27 : 31, Math.Min(38, room / 8));
            Switch[] list = new Switch[] { ClickSwitch, GeometrySwitch, LockSwitch, AutoSwitch,
                                           KeepTopSwitch, StartupSwitch, HoverSwitch, HoldSwitch };
            int swH = NoticeActive ? 26 : 28;
            int y = 68;
            foreach (Switch s in list)
            {
                if (s == null) continue;
                s.Bounds = new Rectangle(rowX, y, rowW, swH);
                y += pitch;
            }
        }

        // The pixels the name column and the binding column each want, measured
        // once from the fonts. The longest binding this app can produce is four
        // modifiers and a key name, so the field is sized from that rather than
        // from a guess about how wide "Shift" is. Measured once and kept: the
        // panel has a single size, so these numbers are a property of the build
        // rather than of the window.
        int _keyLabelNeed;
        int _keyTextNeed;

        void KeyColumnNeeds()
        {
            if (_keyLabelNeed > 0 && _keyTextNeed > 0) return;
            int lw = 80;
            int tw = 130;
            using (Graphics g = CreateGraphics())
            {
                foreach (Label l in _keyLabels)
                {
                    if (l == null) continue;
                    int need = (int)Math.Ceiling(g.MeasureString(l.Text, l.Font).Width) + 4;
                    if (need > lw) lw = need;
                }
                foreach (Field f in KeyFields.Values)
                {
                    if (f == null || f.Box == null) continue;
                    tw = (int)Math.Ceiling(g.MeasureString("Ctrl+Shift+Alt+NumPadPlus", f.Box.Font).Width);
                    break;
                }
            }
            _keyLabelNeed = lw;
            _keyTextNeed = tw;
        }

        void LayoutKeysPage(int left, int inner, int pageH)
        {
            if (KeyFields == null || _keyLabels == null) return;
            int count = _keyLabels.Count;
            if (count == 0) return;

            int room = pageH - 8;
            // Same floor as the Controls page: the update row shortens the page,
            // and thirteen bindings have to still fit inside it.
            int pitch = Math.Max(NoticeActive ? 22 : 24, Math.Min(30, room / count));

            KeyColumnNeeds();
            // Two measured columns. When there is room for both, the name takes
            // exactly what it needs and the binding takes all the rest - that is
            // what makes widening the window actually reveal a long hotkey
            // instead of only moving the frames further apart. When there is not
            // (the minimum window width), the binding keeps the width its
            // longest entry requires and the name ellipsizes, because the
            // binding is the content and the name is a caption.
            int labelNeed = Math.Min(_keyLabelNeed, 190);
            // The field insets its text box by 9px on each side, so it has to be
            // the binding's width plus 18 before the text even fits; 20 leaves a
            // hair of slack. Taking the name's need first and the field's after
            // it means the minimum window shows both in full rather than
            // ellipsizing a name for the sake of two spare pixels.
            int fieldMin = _keyTextNeed + 20;
            int avail = Math.Max(120, inner - 6);
            int labelW = Math.Min(labelNeed, Math.Max(84, avail - fieldMin));
            int fieldW = Math.Max(100, avail - labelW);
            for (int i = 0; i < count; i++)
            {
                int y = i * pitch;
                _keyLabels[i].Bounds = new Rectangle(left, y + 2, labelW, 18);
                Field f = KeyFields[Labels.Action(i)];
                if (f != null) f.Bounds = new Rectangle(left + labelW + 6, y, fieldW, 22);
            }
        }

        void LayoutPresetsPage(int left, int w, int inner, int pageH)
        {
            if (PresetNames == null) return;
            // Three columns: fixed-width buttons because they are glyphs, a
            // binding box that gets what it asks for, and a name box with the
            // rest. The name has a floor of its own - a preset called "Reading"
            // needs somewhere to be read - so on a narrow window it is the
            // binding that gives way, and the hover tip says the rest of a long
            // combination. A shortcut is a fixed string that cannot be
            // shortened, but it is also the thing you only need to check once.
            KeyColumnNeeds();
            int btnW = 74;      // three 22px buttons with 4px between them
            int nameMin = 90;   // below this a name box shows an ellipsis and little else
            int avail = inner - btnW - 12;
            int keyW = Math.Max(126, Math.Min(_keyTextNeed + 22, avail - nameMin));
            int nameW = avail - keyW;
            int keyX = left + nameW + 6;
            int applyX = keyX + keyW + 6;

            if (_presetHeads != null)
            {
                _presetHeads[0].Bounds = new Rectangle(left, 2, nameW, 14);
                _presetHeads[1].Bounds = new Rectangle(keyX, 2, keyW, 14);
            }

            for (int r = 0; r < MaxPresets; r++)
            {
                int y = 20 + r * 46;
                PresetNames[r].Bounds = new Rectangle(left, y, nameW, 24);
                PresetKeys[r].Bounds = new Rectangle(keyX, y, keyW, 24);
                PresetApply[r].Bounds = new Rectangle(applyX, y + 1, 22, 22);
                PresetSave[r].Bounds = new Rectangle(applyX + 26, y + 1, 22, 22);
                PresetRemove[r].Bounds = new Rectangle(applyX + 52, y + 1, 22, 22);
                PresetSummary[r].Bounds = new Rectangle(left, y + 25, inner, 14);
            }

            // Right under the last row, not pinned to the bottom: with a tall
            // window a bottom-anchored link floats a hand's width below the list
            // it belongs to. The note follows it, so the pair always reads as
            // one block whatever the height.
            int listEnd = 20 + MaxPresets * 46;
            if (PresetAdd != null) PresetAdd.Location = new Point(left, listEnd + 6);
            if (_presetNote != null) _presetNote.Bounds = new Rectangle(left, listEnd + 34, inner, 60);
        }

        void ShowPage(int index)
        {
            // Only one page is visible at a time: the window stays the same size
            // and the footer keeps its place, so switching tabs never moves the
            // reset link out from under the pointer.
            PageControls.Visible = index == 0;
            PageKeys.Visible = index == 1;
            PagePresets.Visible = index == 2;
        }

        void BuildControlsPage()
        {
            // The slider and the eight switches are placed for real in
            // LayoutControlsPage; the bounds here only stop the controls
            // painting once at their default corner before that runs.
            Slider = new OpacitySlider();
            Slider.Bounds = new Rectangle(18, 4, 280, 58);
            Slider.BackColor = Palette.Bg;
            Slider.Value = 255;
            PageControls.Controls.Add(Slider);

            ClickSwitch = AddSwitch(PageControls, "Click-through", false, 68);
            GeometrySwitch = AddSwitch(PageControls, "Remember size and position", true, 99);
            LockSwitch = AddSwitch(PageControls, "Lock the frame", false, 130);
            AutoSwitch = AddSwitch(PageControls, "Apply when a player opens", true, 161);
            KeepTopSwitch = AddSwitch(PageControls, "Always on top", true, 192);
            StartupSwitch = AddSwitch(PageControls, "Start with Windows", false, 223);
            HoverSwitch = AddSwitch(PageControls, "Controls on hover", true, 254);
            HoldSwitch = AddSwitch(PageControls, "Hide key holds, not toggles", false, 285);
        }

        Switch AddSwitch(Panel page, string label, bool on, int y)
        {
            Switch s = new Switch(label, on);
            s.Bounds = new Rectangle(18, y, 280, 28);
            s.BackColor = Palette.Bg;
            page.Controls.Add(s);
            return s;
        }

        void BuildKeysPage()
        {
            // Every binding fits without scrolling: a native scrollbar in this
            // dark window would be the brightest thing on it. Rows are pitched at
            // 24px, which is what thirteen of them need to land inside the page.
            KeyFields = new Dictionary<string, Field>();
            _keyLabels = new List<Label>();

            int y = 0;
            for (int i = 0; i < Labels.Count; i++)
            {
                string action = Labels.Action(i);

                Label l = new Label();
                l.Text = Labels.Label(i);
                l.Font = new Font("Segoe UI", 8.75f);
                l.ForeColor = Palette.Muted;
                l.AutoSize = false;
                // At the minimum window width the name column is narrower than
                // its longest entry. Cutting a word in half looks broken; an
                // ellipsis looks like a column doing its best.
                l.AutoEllipsis = true;
                l.BackColor = Color.Transparent;
                PageKeys.Controls.Add(l);
                _keyLabels.Add(l);

                Field f = new Field("", false);
                f.Bounds = new Rectangle(154, y, 144, 22);
                f.Box.Font = new Font("Segoe UI", 8.75f);
                // Press the combination instead of spelling it: the keyboard is
                // right there, and a typed "ctrl + alt + p" that the parser
                // rejects is a worse experience than just not being able to type.
                f.Recordable = true;
                f.Committed += delegate { if (KeysChanged != null && !_building) KeysChanged(); };
                PageKeys.Controls.Add(f);
                KeyFields[action] = f;
                y += 24;
            }
        }

        void BuildPresetsPage()
        {
            PresetNames = new List<Field>();
            PresetKeys = new List<Field>();
            PresetSummary = new List<Label>();
            PresetApply = new List<GlyphButton>();
            PresetSave = new List<GlyphButton>();
            PresetRemove = new List<GlyphButton>();

            string[] heads = new string[] { "name", "key" };
            _presetHeads = new Label[2];
            for (int i = 0; i < 2; i++)
            {
                Label h = new Label();
                h.Text = heads[i];
                h.Font = new Font("Segoe UI", 7.75f);
                h.ForeColor = Palette.Hint;
                h.AutoSize = false;
                h.BackColor = Color.Transparent;
                PagePresets.Controls.Add(h);
                _presetHeads[i] = h;
            }

            for (int r = 0; r < MaxPresets; r++)
            {
                int y = 20 + r * 46;

                Field n = new Field("", false);
                n.Box.Font = new Font("Segoe UI", 8.75f);
                PagePresets.Controls.Add(n);
                PresetNames.Add(n);

                Field k = new Field("", false);
                k.Box.Font = new Font("Segoe UI", 8.75f);
                k.Recordable = true;
                PagePresets.Controls.Add(k);
                PresetKeys.Add(k);

                // Put this row's setup back. Without a glyph here a preset could
                // only be applied by its hotkey, which leaves the mouse out.
                GlyphButton apply = new GlyphButton(GlyphButton.Kind.Apply);
                PagePresets.Controls.Add(apply);
                PresetApply.Add(apply);

                // Store what the player looks like right now into this slot. The
                // arrow-onto-a-line glyph says "write into this row" without a
                // word of label, which the 316px width cannot spare.
                GlyphButton save = new GlyphButton(GlyphButton.Kind.Save);
                PagePresets.Controls.Add(save);
                PresetSave.Add(save);

                GlyphButton remove = new GlyphButton(GlyphButton.Kind.Remove);
                PagePresets.Controls.Add(remove);
                PresetRemove.Add(remove);

                int slot = r;
                apply.Click += delegate { if (PresetApplied != null && !_building) PresetApplied(slot); };
                save.Click += delegate { if (PresetSaved != null && !_building) PresetSaved(slot); };
                remove.Click += delegate { if (PresetRemoved != null && !_building) PresetRemoved(slot); };

                Label sum = new Label();
                sum.Font = new Font("Segoe UI", 7.75f);
                sum.ForeColor = Palette.Hint;
                sum.AutoSize = false;
                sum.BackColor = Color.Transparent;
                PagePresets.Controls.Add(sum);
                PresetSummary.Add(sum);

                // Either box can be the one the user finishes with, so both commit.
                n.Committed += delegate { if (KeysChanged != null && !_building) KeysChanged(); };
                k.Committed += delegate { if (KeysChanged != null && !_building) KeysChanged(); };
            }

            PresetAdd = new LinkLabel();
            PresetAdd.Text = "add a preset";
            PresetAdd.Font = new Font("Segoe UI", 8.25f);
            PresetAdd.LinkColor = Palette.Muted;
            PresetAdd.ActiveLinkColor = Palette.Text;
            PresetAdd.VisitedLinkColor = Palette.Muted;
            PresetAdd.LinkBehavior = LinkBehavior.HoverUnderline;
            PresetAdd.AutoSize = true;
            PresetAdd.BackColor = Color.Transparent;
            PresetAdd.LinkClicked += delegate { if (PresetAdded != null && !_building) PresetAdded(); };
            PagePresets.Controls.Add(PresetAdd);

            // A footnote at the bottom of the page rather than a caption under the
            // rows: it explains the whole model once, and it does not move when a
            // preset is added.
            Label note = new Label();
            note.Text = "The triangle puts a preset back. The arrow stores what the player"
                      + " looks like right now: opacity, click-through, the bar, and the"
                      + " switches, all of it, not just the percentage.";
            note.Font = new Font("Segoe UI", 7.75f);
            note.ForeColor = Palette.Hint;
            note.AutoSize = false;
            note.BackColor = Color.Transparent;
            PagePresets.Controls.Add(note);
            _presetNote = note;
        }

        // Which rows are in use, and what each slot says it holds. The runtime owns
        // the preset list, so it pushes the state in here rather than the panel
        // reaching for the config.
        public void SetPresetRows(int count, string[] names, string[] keys, string[] summary)
        {
            if (InvokeRequired)
            {
                BeginInvoke((MethodInvoker)delegate { SetPresetRows(count, names, keys, summary); });
                return;
            }
            Syncing = true;
            try
            {
                for (int i = 0; i < MaxPresets; i++)
                {
                    bool used = i < count;
                    PresetNames[i].Visible = used;
                    PresetKeys[i].Visible = used;
                    PresetApply[i].Visible = used;
                    PresetSave[i].Visible = used;
                    PresetRemove[i].Visible = used;
                    PresetSummary[i].Visible = used;
                    if (!used) continue;

                    if (!PresetNames[i].Box.Focused) PresetNames[i].Text2 = names[i];
                    if (!PresetKeys[i].Recording && !PresetKeys[i].Box.Focused) PresetKeys[i].Text2 = keys[i];
                    PresetSummary[i].Text = summary[i];
                }
                // The add link only makes sense while there is a free slot.
                PresetAdd.Visible = count < MaxPresets;
            }
            finally { Syncing = false; }
        }

        // The handle does not exist yet inside the constructor, so the DWM
        // rounding call has to wait for it. This is why the panel used to come
        // up as a hard square with the painted arc inside it: the sharp window
        // corners showed past the rounded stroke.
        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            _dwmEdge = Corners.Frame(this, 12, Palette.Line);
        }

        void RequestClose()
        {
            _closing = true;
            // The tip is its own window and does not follow this one into hiding;
            // without this it stays over the desktop pointing at a panel that is
            // no longer there.
            Tips.Close();
            Hide();
        }

        // Closing the window hides it instead, so hotkeys keep working.
        public bool ClosingByUser { get { return _closing; } }

        // True while any key box is waiting for a combination. The form sees keys
        // first (KeyPreview), so it has to know when to keep its hands off Escape.
        bool AnyRecording()
        {
            if (KeyFields != null) { foreach (Field f in KeyFields.Values) { if (f.Recording) return true; } }
            if (PresetKeys != null) { foreach (Field f in PresetKeys) { if (f.Recording) return true; } }
            return false;
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                Hide();
                return;
            }
            base.OnFormClosing(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            // The mark sits at the left of the header, sized to the title's cap
            // height rather than its line box, so it reads as part of the name.
            Mark.Paint(e.Graphics, new Rectangle(18, 18, 19, 13), Palette.Accent);
            // When the compositor is drawing the rim there must be no second
            // stroke: two curves at two radii on one corner is what made the
            // panel look off, with the outer one clipping the inner one.
            if (_dwmEdge) return;
            using (Pen edge = new Pen(Palette.Line))
            using (GraphicsPath p = Draw.Round(new Rectangle(1, 1, Width - 3, Height - 3), 11))
                e.Graphics.DrawPath(edge, p);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                _drag = true;
                Point s = PointToScreen(e.Location);
                _off = new Point(s.X - Location.X, s.Y - Location.Y);
            }
            base.OnMouseDown(e);
        }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            if (_drag)
            {
                Point s = PointToScreen(e.Location);
                Location = new Point(s.X - _off.X, s.Y - _off.Y);
                _moved = true;
            }
            base.OnMouseMove(e);
        }
        protected override void OnMouseUp(MouseEventArgs e)
        {
            // Only report a real move: a click on the panel is also a MouseDown
            // and MouseUp, and saving an unchanged position every time the user
            // touches the window would write the settings file constantly.
            bool moved = _drag && _moved;
            _drag = false;
            _moved = false;
            base.OnMouseUp(e);
            if (moved && Placed != null) Placed();
        }

        // Raised when the user has finished dragging the window. The panel has no
        // title bar, so the whole surface is the handle, and where it was left is
        // worth keeping: a settings window that jumps back to the middle of the
        // screen every time is the sort of thing people stop opening.
        // A plain Action field, like the other panel callbacks, because PowerShell
        // assigns these directly rather than adding a handler.
        public Action Placed;

        protected override void WndProc(ref Message m)
        {
            WndProcKey(ref m);
        }

        // Every key the window receives passes through here before WinForms
        // decides which control gets it, and before any menu handling can rewrite
        // it. Two jobs: keep the modifier latch current, and capture the
        // combination itself when a box is waiting for one.
        //
        // The box's own KeyDown is not enough. With Alt down the press arrives as
        // WM_SYSKEYDOWN, which the system offers to the menu path first; by the
        // time a read-only TextBox sees a KeyDown the Alt can already be gone,
        // which is exactly the reported "it only saves Ctrl+NumPad1" symptom.
        void WndProcKey(ref Message m)
        {
            int msg = m.Msg;
            bool down = msg == 0x0100 || msg == 0x0104;
            bool up = msg == 0x0101 || msg == 0x0105;
            if (down || up)
            {
                int vk = m.WParam.ToInt32() & 0xFF;
                Hotkey.Observe(msg, vk);
                if (down)
                {
                    Field live = RecordingField();
                    if (live != null)
                    {
                        // Escape and Backspace keep the meaning they had: leave
                        // the binding alone, or clear it. Handled here too because
                        // while a capture is running the box never sees these.
                        if (vk == 0x1B) { live.Cancel(); m.Result = IntPtr.Zero; return; }
                        if (vk == 0x08) { live.ClearBinding(); m.Result = IntPtr.Zero; return; }

                        int bit = Hotkey.BitForVk(vk);
                        if (bit != 0) { live.Latch(bit); m.Result = IntPtr.Zero; return; }
                        // A modifier with no bit yet (the Windows keys are only
                        // claimed on the way up) is still not the main key.
                        if (Hotkey.IsModifierOnlyVk(vk)) { m.Result = IntPtr.Zero; return; }

                        // Anything else ends the capture, with the modifiers the
                        // message stream actually saw.
                        if (live.CaptureCombo(vk, Hotkey.Raw | live.Latched)) { m.Result = IntPtr.Zero; return; }
                    }
                }
                else
                {
                    // A modifier going back up leaves the latch, so a tap of Alt
                    // on the way to Ctrl+1 does not record an Alt the user never
                    // held, and the next chord starts clean once everything is up.
                    Field live = RecordingField();
                    if (live != null)
                    {
                        int bit = Hotkey.BitForVk(vk);
                        if (bit != 0) live.Unlatch(bit);
                    }
                }
            }
            base.WndProc(ref m);
        }

        Field RecordingField()
        {
            if (KeyFields != null)
                foreach (Field f in KeyFields.Values) if (f.Recording) return f;
            if (PresetKeys != null)
                foreach (Field f in PresetKeys) if (f.Recording) return f;
            return null;
        }

        public void SetStatus(string text, bool warn)
        {
            if (InvokeRequired) { BeginInvoke((MethodInvoker)delegate { SetStatus(text, warn); }); return; }
            Status.Text = text;
            Status.ForeColor = warn ? Palette.Warn : Palette.Muted;
        }

        // Announcing a version takes room away from the tab, so the whole layout
        // is rebuilt rather than the row simply being made visible: otherwise a
        // page would keep its old height and the last row would sit under the
        // strip.
        public void ShowUpdate(string version)
        {
            if (InvokeRequired) { BeginInvoke((MethodInvoker)delegate { ShowUpdate(version); }); return; }
            if (Notice == null || version == null || version.Length == 0) return;
            Notice.Version = version.TrimStart('v', 'V');
            Notice.Visible = true;
            NoticeActive = true;
            LayoutAll();
        }

        public void SyncControls(int alpha, bool click, bool geo, bool auto, bool keepTop, bool startup, bool hover, bool holdHide, bool locked)
        {
            if (InvokeRequired) { BeginInvoke((MethodInvoker)delegate { SyncControls(alpha, click, geo, auto, keepTop, startup, hover, holdHide, locked); }); return; }
            Syncing = true;
            try
            {
                Slider.Value = alpha;
                ClickSwitch.On = click;
                GeometrySwitch.On = geo;
                LockSwitch.On = locked;
                AutoSwitch.On = auto;
                KeepTopSwitch.On = keepTop;
                StartupSwitch.On = startup;
                HoverSwitch.On = hover;
                HoldSwitch.On = holdHide;
            }
            finally { Syncing = false; }
        }
    }
}
'@
}


# ------------------------------------------------------------------- runtime
# Give this process its own taskbar identity before any window exists. Without
# one the shell groups the window under powershell.exe and draws PowerShell's
# icon on the button, no matter what Icon the window sets: that is why the panel
# kept showing the default PowerShell icon even after it had a real multi-size
# icon of its own.
try { [void][PipFade.Win]::SetCurrentProcessExplicitAppUserModelID('PipFade.MiniplayerTweaks') } catch { }

$script:Config  = Get-Config
$script:Panel   = $null
$script:TrayIcon    = $null
$script:Known   = @{}     # hwnd -> last seen state
$script:Applied = @{}     # hwnd -> @{ Alpha=n; Click=bool }
$script:LockRects = @{}   # hwnd -> the rect a locked frame must keep
$script:Pinned  = [IntPtr]::Zero
$script:Quit    = $false
$script:Strip       = $null    # hover strip window, created on demand
$script:StripEntry  = $null    # tiny typing field that opens over the bar's percentage
$script:StripFor    = [IntPtr]::Zero
$script:StripShownAt = [DateTime]::MinValue
$script:StripHideAt = [DateTime]::MinValue
$script:StripPlaced  = ''       # last window rect the bar was placed at
# Bumped every time a player is raised. Both the player and the bar live in the
# topmost band, where the most recent raise wins, so the bar has to know that
# something was raised above it rather than assume its place is still good.
$script:RaiseGen    = 0
$script:StripZGen   = -1
$script:Watcher     = $null    # native window-shown hook, created at start
$script:LastRaise   = [DateTime]::MinValue
$script:RaiseAt     = [DateTime]::MinValue
$script:Dirty       = $false   # something happened; run a pass now
$script:LastFull    = [DateTime]::MinValue
$script:Players     = @()      # last detected players, for the hover strip
$script:ForeMoved   = $false   # the foreground window changed
$script:MovedAt     = [DateTime]::MinValue   # last time a window moved or resized
$script:HiddenFor   = [IntPtr]::Zero         # player hidden by us, if any
$script:HoldActive  = $false   # hide hotkey is being held down
$script:HideVk      = 0        # virtual key of the hide hotkey, for hold mode
$script:SaveDue     = $false   # settings changed; write them on the next pass

function Get-Players {
    if ($script:Pinned -ne [IntPtr]::Zero -and [PipFade.Win]::IsWindow($script:Pinned)) {
        $p = [PipFade.Finder]::Describe($script:Pinned)
        if ($p) { return @($p) }
    }
    $all = @([PipFade.Finder]::Find())
    if ($all.Count -le 1) { return $all }

    # Only ever work on one player. Two players open at once would fight over
    # the single saved opacity, so the one under the pointer wins, otherwise
    # the first found (Chromium keeps the newest PiP window highest in z-order).
    $pt = New-Object PipFade.Win+POINT
    [void][PipFade.Win]::GetCursorPos([ref]$pt)
    foreach ($p in $all) {
        if ($pt.X -ge $p.X -and $pt.X -lt ($p.X + $p.W) -and
            $pt.Y -ge $p.Y -and $pt.Y -lt ($p.Y + $p.H)) { return @($p) }
    }
    return @($all[0])
}

# Applies the saved look to a player: geometry first, then alpha, then clicks.
function Apply-ToPlayer($pip, [switch]$Force) {
    $cfg = $script:Config
    $h = $pip.Handle

    if ($cfg.RememberGeometry) {
        $key = Get-GeometryKey $pip.Proc
        if ($cfg.Geometry.ContainsKey($key)) {
            $g = $cfg.Geometry[$key]
            if (-not ($pip.X -eq $g.X -and $pip.Y -eq $g.Y -and $pip.W -eq $g.W -and $pip.H -eq $g.H)) {
                # Same rule as Restore-Geometry: position always, size only while
                # the video still has the proportions it had when the rect was
                # saved. Forcing an old width and height onto a differently
                # shaped video is what put black bars around it.
                $r = Get-RestoreRect $pip $g
                if (Test-OnScreen $r.X $r.Y $r.W $r.H) {
                    if (-not ($pip.X -eq $r.X -and $pip.Y -eq $r.Y -and $pip.W -eq $r.W -and $pip.H -eq $r.H)) {
                        [PipFade.Finder]::Move($h, $r.X, $r.Y, $r.W, $r.H)
                    }
                }
            }
        }
    }

    if ($cfg.KeepOnTop) { [PipFade.Finder]::Raise($h) }

    $want = if ($cfg.AutoApply -or $Force) { $cfg.Alpha } else { 255 }
    $clicks = if ($cfg.AutoApply -or $Force) { [bool]$cfg.ClickThrough } else { $false }

    $key = '0x{0:X}' -f $h.ToInt64()
    $state = $script:Applied[$key]
    if (-not $state -or $state.Alpha -ne $want -or $state.Click -ne $clicks) {
        [PipFade.Finder]::ApplyAlpha($h, $want)
        [PipFade.Finder]::SetClickThrough($h, $clicks)
        $script:Applied[$key] = @{ Alpha = $want; Click = $clicks }
    }
}

function Set-LiveAlpha([int]$value) {
    $script:Config.Alpha = $value
    # Dragging the slider fires dozens of changes a second. Writing the JSON on
    # every one of them was the slowest thing about dragging; the save is
    # deferred and the loop writes it once when the hand stops.
    Request-Save
    # Use the players already known to be alive rather than enumerating every
    # window on the desktop: during a drag this runs on every mouse move.
    $live = $(if ($script:Players -and $script:Players.Count -gt 0) { $script:Players } else { @(Get-Players) })
    foreach ($p in $live) { [PipFade.Finder]::ApplyAlpha($p.Handle, $value) }
    $script:Applied = @{}
    # Both surfaces show the same setting, so whichever one moved must refresh
    # the other. Without this the panel and the bar drift apart.
    Sync-Strip
    Sync-Panel
}

function Set-LiveClicks([bool]$on) {
    $script:Config.ClickThrough = $on
    Request-Save
    $live = $(if ($script:Players -and $script:Players.Count -gt 0) { $script:Players } else { @(Get-Players) })
    foreach ($p in $live) { [PipFade.Finder]::SetClickThrough($p.Handle, $on) }
    $script:Applied = @{}
    Sync-Strip
    Sync-Panel
}

# Locking is recorded per window rather than once for the app: two players at
# once are two layouts, and locking one must not freeze the other. Turning it on
# takes the rect the player has now, so the lock always starts from where the
# user put it.
function Set-LiveLock([bool]$on) {
    $script:Config.Locked = $on
    Save-Config $script:Config
    $script:LockRects = @{}
    if ($on) {
        foreach ($p in @(Get-Players)) {
            $script:LockRects['0x{0:X}' -f $p.Handle.ToInt64()] = [pscustomobject]@{ X = $p.X; Y = $p.Y; W = $p.W; H = $p.H }
        }
    }
    Sync-Strip
    Sync-Panel
}

function Sync-Panel {
    if (-not $script:Panel) { return }
    $script:Panel.SyncControls(
        [int]$script:Config.Alpha,
        [bool]$script:Config.ClickThrough,
        [bool]$script:Config.RememberGeometry,
        [bool]$script:Config.AutoApply,
        [bool]$script:Config.KeepOnTop,
        (Test-StartAtLogin),
        [bool]$script:Config.HoverControls,
        ($script:Config.HideMode -eq 'hold'),
        [bool]$script:Config.Locked)
    Sync-Keys
}

# A player that is already on screen when pipfade starts never fires a "shown"
# event, so it has to be found by looking rather than by waiting. This runs once
# at startup and covers every player open at that moment, not just one: the
# single-player rule exists so two players cannot fight over one saved opacity,
# which is a problem only for live changes, not for the initial dress-up.
function Adopt-Existing {    $all = @([PipFade.Finder]::Find())
    if ($script:Pinned -ne [IntPtr]::Zero -and [PipFade.Win]::IsWindow($script:Pinned)) {
        $pin = [PipFade.Finder]::Describe($script:Pinned)
        if ($pin) { $all = @($pin) }
    }
    if ($all.Count -eq 0) { return 0 }
    foreach ($p in $all) {
        $key = '0x{0:X}' -f $p.Handle.ToInt64()
        if (-not $script:Known.ContainsKey($key)) {
            $script:Known[$key] = @{ Rect = $p; SettleAt = [DateTime]::UtcNow; Proc = $p.Proc }
        }
        if ($script:Config.AutoApply) { Apply-ToPlayer $p -Force }
    }
    # adopt into the single-player view as well, so the bar and the panel know
    # about it before the first sweep
    $script:Players = @($all)
    Sync-WatchRects
    $script:Dirty = $true
    return $all.Count
}

# Hiding keeps the window, its geometry and its video stream: ShowWindow only
# takes it off screen, so bringing it back costs nothing and the saved opacity
# survives. A window hidden this way also stops matching the detector, which is
# why the handle is remembered until it comes back.
function Set-PlayerHidden([IntPtr]$h, [bool]$hidden) {
    if ($h -eq [IntPtr]::Zero -or -not [PipFade.Win]::IsWindow($h)) { return }
    if ($hidden) {
        if (-not [PipFade.Win]::IsWindowVisible($h)) { $script:HiddenFor = $h; return }
        if ($script:Strip) { $script:Strip.Vanish() }
        [PipFade.Finder]::Hide($h)
        $script:HiddenFor = $h
    } else {
        [PipFade.Finder]::Unhide($h)
        if ($script:HiddenFor -eq $h) { $script:HiddenFor = [IntPtr]::Zero }
        $script:Dirty = $true
    }
}

function Show-PlayerAgain {
    if ($script:HiddenFor -eq [IntPtr]::Zero) { return $false }
    if (-not [PipFade.Win]::IsWindow($script:HiddenFor)) { $script:HiddenFor = [IntPtr]::Zero; return $false }
    Set-PlayerHidden $script:HiddenFor $false
    return $true
}

# Toggle mode: one press hides, the next brings it back. Hold mode does nothing
# here because the key state is followed by Step-HoldHide instead.
function Invoke-Hide {
    if ([string]$script:Config.HideMode -eq 'hold') { return }
    if (Show-PlayerAgain) { return }
    $p = @(Get-Players) | Select-Object -First 1
    if ($p) { Set-PlayerHidden $p.Handle $true }
}

# Hold mode: hidden exactly while the key is down. RegisterHotKey only reports
# the press, so the key itself is polled. Only runs while a press is pending or
# a player is hidden, so it costs nothing the rest of the time.
function Step-HoldHide {
    if ([string]$script:Config.HideMode -ne 'hold') {
        if ($script:HoldActive) {
            $script:HoldActive = $false
            [void](Show-PlayerAgain)
        }
        return
    }
    if ($script:HideVk -eq 0) { return }

    $down = [PipFade.Finder]::IsKeyDown($script:HideVk)
    if ($down -and -not $script:HoldActive) {
        $script:HoldActive = $true
        $p = @(Get-Players) | Select-Object -First 1
        if ($p) { Set-PlayerHidden $p.Handle $true }
    } elseif (-not $down -and $script:HoldActive) {
        $script:HoldActive = $false
        [void](Show-PlayerAgain)
    }
}

function Reset-Everything {
    # RestoreAll first: it covers every window ever faded, including ones that no
    # longer match the detector and so would be missed by a fresh search.
    [void][PipFade.Finder]::RestoreAll()
    foreach ($p in @(Get-Players)) { [PipFade.Finder]::Restore($p.Handle) }
    $script:Config.Alpha = 255
    $script:Config.ClickThrough = $false
    $script:Config.Geometry = @{}
    # The link promises to reset the panel's position too, so the sentinel goes
    # back in and the window is put in the middle while the file is written.
    $script:Config.PanelX = -999999
    $script:Config.PanelY = -999999
    if ($script:Panel) {
        $v = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $script:Panel.Location = [System.Drawing.Point]::new(
            [int]($v.Left + ($v.Width - 360) / 2), [int]($v.Top + ($v.Height - 470) / 2))
    }
    Save-Config $script:Config
    $script:Applied = @{}
    $script:Known = @{}
    Sync-Panel
    Sync-Strip
}

function Update-Status([int]$count) {
    if (-not $script:Panel) { return }
    if ($count -gt 0) {
        $script:Panel.SetStatus(("{0} player{1}" -f $count, $(if ($count -gt 1) { 's' } else { '' })), $false)
    } else {
        $script:Panel.SetStatus('no player open', $false)
    }
}

# ------------------------------------------------------------- hover controls
# The strip lives inside the player and fades in while the pointer is over it.
# Everything here is cursor maths and window positioning, so it costs nothing
# when no player is open.
function Sync-Strip {
    if (-not $script:Strip) { return }
    $script:Strip.SyncAlpha([int]$script:Config.Alpha)
    $script:Strip.SyncClicks([bool]$script:Config.ClickThrough)
    $script:Strip.SyncLock([bool]$script:Config.Locked)
    # the bar fades with the video instead of staying fully solid on top of it
    $script:Strip.SetBase([int]$script:Config.Alpha)
}

function Show-Strip($pip) {
    if ($script:Strip) { return }
    $script:Strip = New-Object PipFadeUI.HoverStrip
    $script:Strip.TopMost = $true
    $script:Strip.LayoutTo($pip.W, $pip.H)

    $script:Strip.add_Scrub({
        param($v)
        if ($script:Strip.Syncing) { return }
        Set-LiveAlpha $v
    })
    $script:Strip.add_ClickToggle({
        Set-LiveClicks (-not $script:Config.ClickThrough)
    })
    $script:Strip.add_OpenPanel({ Show-Panel })
    $script:Strip.add_LockToggle({
        Set-LiveLock (-not $script:Config.Locked)
    })
    $script:Strip.add_QuitRequested({
        # Same path as the tray's Quit and the quit hotkey, so the cleanup in the
        # finally block runs: hidden players come back, the config is written.
        $script:Quit = $true
    })
    $script:Strip.add_PercentRequested({
        # The bar is a layered bitmap with no child controls, so typing happens
        # in a small field that opens over the percentage the user just clicked.
        if ($script:StripEntry) { return }
        $s = $script:Strip
        $p = $s.PctRect
        $entry = New-Object PipFadeUI.StripEntry
        # Sit the field on the well it replaces, clamped inside the bar so it can
        # never hang off an edge on a narrow player.
        $ex = [Math]::Max(0, [Math]::Min($s.Width - $entry.Width, $p.X - 4))
        $ey = [Math]::Max(0, [int](($s.Height - $entry.Height) / 2))
        $screen = $s.PointToScreen((New-Object System.Drawing.Point -ArgumentList $ex, $ey))
        $script:StripEntry = $entry
        $entry.add_Applied({
            param($pct)
            Set-LiveAlpha ([int][Math]::Round($pct / 100.0 * 255))
        })
        $entry.add_Done({
            $script:StripEntry = $null
        })
        $entry.Open($screen, $s.Percent)
    })

    Sync-Strip
    $script:Strip.Show()
}

function Hide-Strip {
    if (-not $script:Strip) { return }
    $script:Strip.FadeOutAndHide()
}

function Dispose-Strip {
    # A typing field floating over the bar must go with the bar, or it would be
    # left behind pointing at a player that is gone.
    if ($script:StripEntry) {
        try { $script:StripEntry.CloseQuietly() } catch { }
        $script:StripEntry = $null
    }
    if (-not $script:Strip) { return }
    $script:Strip.Release()
    $script:Strip = $null
    $script:StripFor = [IntPtr]::Zero
    # Forget the placement so a bar re-created at the same spot still gets its
    # first SetWindowPos: that call is what raises it above the player.
    $script:StripPlaced = ''
}

# Places the strip along the top edge of the player. Chromium draws its own
# play/close controls along the bottom, so the top stays clear of them.
# The player is itself a topmost window, so the strip is re-raised without
# activation each poll; otherwise the player would sit over it.
function Place-Strip($pip) {
    $s = $script:Strip
    $margin = 10
    $x = $pip.X + [int](($pip.W - $s.Width) / 2)
    $y = $pip.Y + $margin
    if ($pip.H -lt ($s.Height + $margin * 2)) {
        # a very short player: sit just inside the bottom edge
        $y = $pip.Y + [Math]::Max(2, $pip.H - $s.Height - 2)
    }
    $key = '{0},{1},{2},{3}' -f $x, $y, $s.Width, $s.Height

    # Moving the window is what the key is for: the common tick is "the player
    # has not moved", and SetWindowPos with a new size is the expensive part.
    $moved = ($script:StripPlaced -ne $key)

    # Z-order is a different question, and skipping it was the bug behind
    # "the controls only work after I leave and come back". The player is a
    # topmost window too, and Keep-PlayersOnTop raises it whenever anything
    # covers it or the foreground changes. Both windows then sit in the topmost
    # band in raise order, so a player raised after the bar buries the bar:
    # it still paints, but every click lands on the video underneath, and the
    # bar only comes back on top when it is hidden and shown again.
    $buried = ($script:StripZGen -ne $script:RaiseGen)
    if (-not $moved -and -not $buried -and $s.Visible) {
        # Last resort, and the honest test: if the pointer is over the bar but
        # the window manager says the pointer is over something else, the bar
        # has lost the topmost band. Re-raise it rather than wait for a hint.
        $probe = New-Object PipFade.Win+POINT
        [void][PipFade.Win]::GetCursorPos([ref]$probe)
        $b = $s.Bounds
        if ($probe.X -ge $b.X -and $probe.X -lt ($b.X + $b.Width) -and
            $probe.Y -ge $b.Y -and $probe.Y -lt ($b.Y + $b.Height)) {
            if (-not [PipFade.Finder]::IsOurs([PipFade.Win]::WindowFromPoint($probe))) { $buried = $true }
        }
    }
    if (-not $moved -and -not $buried) { return }

    $script:StripPlaced = $key
    $script:StripZGen = $script:RaiseGen

    $HWND_TOPMOST = [IntPtr](-1)
    $SWP_NOACTIVATE = 0x0010
    $SWP_SHOWWINDOW = 0x0040
    [void][PipFade.Win]::SetWindowPos($s.Handle, $HWND_TOPMOST, $x, $y, $s.Width, $s.Height,
        ($SWP_NOACTIVATE -bor $SWP_SHOWWINDOW))
}

# Re-reads the rect of each known player without enumerating the desktop, so the
# hover strip follows a player that is being dragged between full sweeps.
function Refresh-PlayerRects {
    if (-not $script:Players -or $script:Players.Count -eq 0) { return }
    $out = @()
    foreach ($p in $script:Players) {
        $fresh = [PipFade.Finder]::Describe($p.Handle)
        if ($fresh) { $out += $fresh }
    }
    $script:Players = $out
    Sync-WatchRects
}

# Hands the current player rects to the native idle wait, which looks at the
# pointer against them while it sleeps. Without this the sleep would be blind:
# the loop would only notice the pointer on the next pass, which is the quarter
# of a second the whole idle path is trying not to spend.
function Sync-WatchRects {
    if ($script:Config.HoverControls -and $script:Players -and $script:Players.Count -gt 0) {
        $flat = New-Object 'int[]' ($script:Players.Count * 4)
        $i = 0
        foreach ($p in $script:Players) {
            $flat[$i] = $p.X
            $flat[$i + 1] = $p.Y
            $flat[$i + 2] = $p.W
            $flat[$i + 3] = $p.H
            $i += 4
        }
        [PipFade.Win]::SetWatchRects($flat, 40)
    } else {
        [PipFade.Win]::SetWatchRects($null, 40)
    }
}

# Is this handle one of the players we already know about?
function Test-PlayerHandle([IntPtr]$h) {
    if ($h -eq [IntPtr]::Zero) { return $false }
    foreach ($p in $script:Players) { if ($p.Handle -eq $h) { return $true } }
    return $false
}

# Cheap test: is the pointer inside any known player's rect? Uses the stored
# rects, so it costs one GetCursorPos and no window calls at all.
#
# Pixel-exact on purpose. A margin here would make the loop consider itself hot
# whenever the pointer merely parks nearby, which is the common idle case: an
# idle pointer sitting a few pixels off a video would then spin the loop at the
# short wait forever. The warning that the pointer is approaching comes from the
# native idle wait instead, which looks every 25ms and wakes the loop the moment
# the pointer really is inside a player.
function Test-CursorNearPlayer {
    if (-not $script:Config.HoverControls) { return $false }
    if (-not $script:Players -or $script:Players.Count -eq 0) { return $false }
    $pt = New-Object PipFade.Win+POINT
    [void][PipFade.Win]::GetCursorPos([ref]$pt)
    foreach ($p in $script:Players) {
        if ($pt.X -ge $p.X -and $pt.X -lt ($p.X + $p.W) -and
            $pt.Y -ge $p.Y -and $pt.Y -lt ($p.Y + $p.H)) { return $true }
    }
    return $false
}

# Called from the loop. Shows the strip while the cursor is over a player,
# and gives a short grace period so moving between the player and the strip
# does not make it flicker.
function Step-Strip($players) {
    if (-not $script:Config.HoverControls -or $script:Config.ClickThrough) {
        # With click-through on the bar would be invisible to the mouse, so it
        # must not appear at all: hide it outright rather than fading.
        if ($script:Strip) { $script:Strip.Vanish() }
        return
    }

    $now = [DateTime]::UtcNow

    # While the percentage field is open, leave the bar exactly where it is.
    # Place-Strip re-raises the bar above everything every tick, which would put
    # it in front of the field the user is typing into, and moving the pointer
    # down into the field must not count as leaving the player. If the player
    # itself has gone, fall through so the bar and the field are cleaned up.
    if ($script:StripEntry -and $script:Strip -and $script:Strip.Visible -and (Test-PlayerHandle $script:StripFor)) {
        $script:StripHideAt = $now.AddMilliseconds(450)
        return
    }

    # A player being dragged or resized: get out of the way entirely instead of
    # trying to follow. Chasing a window that moves every few milliseconds can
    # only ever be one step behind, so the bar would look like it was lagging.
    # It comes back once the window has been still for a moment.
    if (($now - $script:MovedAt).TotalMilliseconds -lt 300) {
        if ($script:Strip) { $script:Strip.Vanish() }
        return
    }

    # Re-read the rects here rather than trusting the caller: placing the bar
    # from a stale position puts it where the player used to be.
    Refresh-PlayerRects
    $players = @($script:Players)

    $pt = New-Object PipFade.Win+POINT
    [void][PipFade.Win]::GetCursorPos([ref]$pt)

    $under = $null
    foreach ($p in $players) {
        if ($pt.X -ge $p.X -and $pt.X -lt ($p.X + $p.W) -and
            $pt.Y -ge $p.Y -and $pt.Y -lt ($p.Y + $p.H)) { $under = $p; break }
    }

    # The pointer resting on the bar itself has to count, even where the bar
    # hangs past the player's edge. A narrow player gets a bar wider than it is
    # (the bar has a floor so the rail stays usable), so its overhang sits on no
    # player at all; without this, moving onto that overhang made the bar
    # disappear from under the pointer.
    if (-not $under -and $script:Strip -and $script:Strip.Visible) {
        $b = $script:Strip.Bounds
        if ($pt.X -ge $b.X -and $pt.X -lt ($b.X + $b.Width) -and
            $pt.Y -ge $b.Y -and $pt.Y -lt ($b.Y + $b.Height)) {
            foreach ($p in $players) {
                if ($p.Handle -eq $script:StripFor) { $under = $p; break }
            }
        }
    }

    if ($under) {
        if (-not $script:Strip -or $script:StripFor -ne $under.Handle) {
            if ($script:Strip -and $script:Strip.Visible) { $script:Strip.Hide() }
            Dispose-Strip
            Show-Strip $under
            $script:StripFor = $under.Handle
            $script:StripShownAt = $now
        }
        Place-Strip $under
        if (-not $script:Strip.Visible) {
            $script:Strip.Show()
            $script:Strip.FadeIn()
        } else {
            $script:Strip.Reveal()
        }
        # The bar can be placed under a pointer that has not moved, and it can
        # also move out from under one that is still: either way Windows sends
        # no mouse message, so the highlight would be stale or absent. One call
        # per tick keeps it honest, and it only repaints when the answer changed.
        $script:Strip.SyncHover()
        $script:StripHideAt = $now.AddMilliseconds(450)
        return
    }

    if ($script:Strip -and $script:Strip.Visible -and $now -gt $script:StripHideAt) {
        Hide-Strip
    }
}

# Keeps players at the top of the topmost band. A window that goes fullscreen
# or takes the foreground can end up above a topmost player, because z-order
# inside that band follows the last raise.
#
# The periodic sweep only raises a player that is actually covered, so a normal
# always-on-top window next to it is left alone and there is no z-order fight.
# A foreground change raises unconditionally, shortly after the change, because
# that is the moment a fullscreen app takes over the screen.
function Keep-PlayersOnTop($players) {
    if (-not $script:Config.KeepOnTop) { return }
    if (-not $players -or $players.Count -eq 0) { return }

    $now = [DateTime]::UtcNow
    $forced = $script:ForeMoved
    $script:ForeMoved = $false
    if ($forced) {
        # give the app a moment to finish its fullscreen transition
        $script:RaiseAt = $now.AddMilliseconds(250)
    }

    $due = ($script:RaiseAt -ne [DateTime]::MinValue -and $now -ge $script:RaiseAt)
    if (-not $due -and ($now - $script:LastRaise).TotalMilliseconds -gt 2000) { $due = $true }
    if (-not $due) { return }

    $me = [uint32]$PID
    $raised = $false
    foreach ($p in $players) {
        if ($forced -or [PipFade.Finder]::IsCovered($p.Handle, $me)) {
            [PipFade.Finder]::Raise($p.Handle)
            $raised = $true
        }
    }
    # A raise puts the player above the bar, which sits in the same band. Tell
    # Place-Strip so it re-asserts itself instead of trusting its last place.
    if ($raised) { $script:RaiseGen++ }
    $script:LastRaise = $now
    $script:RaiseAt = [DateTime]::MinValue
}

# Blocks until a window message arrives or the timeout expires. Used instead of
# Start-Sleep so the hook callbacks are dispatched the instant Windows delivers
# them, without burning CPU while nothing happens.
#
# Blocks until a window message arrives or the timeout expires, so the hook
# callbacks are dispatched the instant Windows delivers them without burning CPU
# while nothing happens.
#
# The whole wait lives in C# (PipFade.Win.WaitMessages) because every call made
# from PowerShell carries marshalling overhead of roughly half a millisecond.
# Measured on this machine, the PowerShell version of this function - one
# MsgWaitForMultipleObjects, one GetQueueStatus, two DateTime reads and a
# comparison per pass, four passes a second - cost about 1% of a core to do
# nothing but sleep. One call per pass removed nearly all of it.
function Wait-Messages([int]$ms) {
    [void][PipFade.Win]::WaitMessages([uint32]$ms)
}

# Applies to a single handle the watcher just reported, without enumerating the
# desktop. This is the fast path that makes a new player adopt the saved look
# immediately rather than on the next sweep.
function Apply-NewHandle([IntPtr]$h) {
    if (-not [PipFade.Finder]::IsPlayer($h)) { return $false }
    $key = '0x{0:X}' -f $h.ToInt64()
    if ($script:Known.ContainsKey($key)) { return $false }

    $p = [PipFade.Finder]::Describe($h)
    if (-not $p) { return $false }
    $script:Known[$key] = @{ Rect = $p; SettleAt = [DateTime]::UtcNow; Proc = $p.Proc }
    Apply-ToPlayer $p
    $script:Dirty = $true
    return $true
}

# One pass: find players, auto-apply to new ones, remember geometry as it
# changes, and keep players above whatever took the foreground.
function Step {
    $players = Get-Players
    $live = @{}
    $now = [DateTime]::UtcNow

    Keep-PlayersOnTop $players

    foreach ($p in $players) {
        $h = $p.Handle
        $key = '0x{0:X}' -f $h.ToInt64()
        $live[$key] = $true

        $isNew = -not $script:Known.ContainsKey($key)
        if ($isNew) {
            $script:Known[$key] = @{ Rect = $p; SettleAt = $now; Proc = $p.Proc }
            Apply-ToPlayer $p
            continue
        }

        $prev = $script:Known[$key]
        $rect = [pscustomobject]@{ X = $p.X; Y = $p.Y; W = $p.W; H = $p.H }

        # A locked frame holds the size and position it was given. Nothing can
        # stop another process from moving its own window, so the only honest
        # implementation is to put it back the moment it is somewhere else. The
        # first sighting is the reference, so locking straight after opening a
        # player holds where it already is rather than moving it somewhere new.
        if ($script:Config.Locked) {
            $lock = $script:LockRects[$key]
            if (-not $lock) {
                $script:LockRects[$key] = $rect
            } elseif ($lock.X -ne $rect.X -or $lock.Y -ne $rect.Y -or
                      $lock.W -ne $rect.W -or $lock.H -ne $rect.H) {
                if ([PipFade.Finder]::IsPlayer($h)) {
                    [PipFade.Finder]::Move($h, $lock.X, $lock.Y, $lock.W, $lock.H)
                }
                $prev.Rect = $lock
                $prev.SettleAt = $now
                continue
            }
        }

        if ($prev.Rect.X -ne $rect.X -or $prev.Rect.Y -ne $rect.Y -or
            $prev.Rect.W -ne $rect.W -or $prev.Rect.H -ne $rect.H) {
            # the user is moving or resizing it: wait for it to settle, then save
            $prev.Rect = $rect
            $prev.SettleAt = $now
        } elseif ($script:Config.RememberGeometry) {
            $idle = ($now - $prev.SettleAt).TotalMilliseconds
            if ($idle -gt 700) {
                $saved = $script:Config.Geometry[(Get-GeometryKey $p.Proc)]
                if (-not $saved -or $saved.X -ne $rect.X -or $saved.Y -ne $rect.Y -or
                    $saved.W -ne $rect.W -or $saved.H -ne $rect.H) {
                    Save-Geometry $script:Config $p.Proc $rect
                    Save-Config $script:Config
                }
            }
        }
    }

    foreach ($key in @($script:Known.Keys)) {
        if (-not $live.ContainsKey($key)) {
            # A player we hid on purpose is invisible to the detector, so it must
            # not be forgotten here or it would come back with a stale state.
            if ($script:HiddenFor -ne [IntPtr]::Zero -and ('0x{0:X}' -f $script:HiddenFor.ToInt64()) -eq $key) {
                continue
            }
            $script:Known.Remove($key)
            $script:Applied.Remove($key)
            if ($script:StripFor -ne [IntPtr]::Zero -and ('0x{0:X}' -f $script:StripFor.ToInt64()) -eq $key) {
                Dispose-Strip
            }
        }
    }

    Update-Status $players.Count
    $script:Players = $players
    Sync-WatchRects
}


# ------------------------------------------------------------------- hotkeys
# Bindings live in the config as text, so they can be changed at runtime. Each
# registration gets a fresh id, and the id -> action table is rebuilt with it.
function Install-Hotkeys {
    $script:Hotkeys = New-Object PipFadeUI.HotkeyWindow
    $script:HkMap = @{}
    $script:HkFailed = @()
    # A counter kept on the script scope: the binder below runs in a child scope,
    # so a plain local ++ there would be written to a throwaway copy and every
    # binding would end up sharing one id.
    $script:HkId = 0

    $bind = {
        param([string]$action, [string]$text)
        if ([string]::IsNullOrWhiteSpace($text)) { return }
        $spec = ConvertTo-HotkeySpec $text
        if (-not $spec) { $script:HkFailed += "$action (bad text: '$text')"; return }
        $script:HkId++
        if ($script:Hotkeys.Register($script:HkId, $spec.Mods, $spec.Vk)) {
            $script:HkMap[$script:HkId] = $action
        } else {
            $script:HkFailed += "$action ($text)"
        }
    }

    foreach ($name in @('down', 'up', 'solid', 'click', 'pick', 'panel', 'reset', 'geometry', 'lock', 'hover', 'ontop', 'hide', 'quit')) {
        & $bind $name $script:Config.Hotkeys.$name
    }
    # Hold-to-hide polls the key itself, so the virtual key is remembered.
    $script:HideVk = 0
    $hideSpec = ConvertTo-HotkeySpec $script:Config.Hotkeys.'hide'
    if ($hideSpec) { $script:HideVk = [int]$hideSpec.Vk }
    # Presets get their own ids so one key press can put a whole saved setup back.
    for ($i = 0; $i -lt $script:Config.Presets.Count; $i++) {
        & $bind "preset:$i" $script:Config.Presets[$i].Hotkey
    }

    $script:Hotkeys.add_Pressed({
        param($keyId)
        $act = $script:HkMap[$keyId]
        if (-not $act) { return }
        Invoke-Hotkey $act
    })

    # Explorer owns the notification area, and it destroys every icon in it when
    # it restarts. An icon that is never put back leaves pipfade running with no
    # way to see or click it, which is indistinguishable from pipfade being gone.
    # The hotkeys belong to this process and survive a shell restart, so only the
    # icon needs rebuilding.
    $script:Hotkeys.add_TaskbarRecreated({
        if ($script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() }
        $script:TrayIcon = New-TrayIcon
    })
}

# Re-registering is the only way to pick up an edited binding: UnregisterHotKey
# takes the original id, so the window is thrown away and rebuilt.
function Restart-Hotkeys {
    if ($script:Hotkeys) { $script:Hotkeys.Dispose() }
    Install-Hotkeys
}

function Invoke-Hotkey([string]$action) {
    switch ($action) {
        'up'    { Set-LiveAlpha ([Math]::Min($MAX_ALPHA, $script:Config.Alpha + 20)) }
        'down'  { Set-LiveAlpha ([Math]::Max($MIN_ALPHA, $script:Config.Alpha - 20)) }
        'solid' { Set-LiveAlpha 255; Set-LiveClicks $false }
        'click' { Set-LiveClicks (-not $script:Config.ClickThrough) }
        'reset' { Reset-Everything }
        'pick'  {
            $pt = New-Object PipFade.Win+POINT
            [void][PipFade.Win]::GetCursorPos([ref]$pt)
            $hit = [PipFade.Win]::WindowFromPoint($pt)
            $root = [PipFade.Win]::GetAncestor($hit, 2)   # GA_ROOT
            # Only accept a window that really looks like a mini player. Pinning
            # whatever happened to be under the pointer used to hand the tray
            # menu, a tooltip or any small window to the opacity code.
            if ($root -ne [IntPtr]::Zero -and [PipFade.Finder]::IsPlayer($root)) {
                $script:Pinned = $root
                $script:Known = @{}
                $script:Applied = @{}
                if ($script:Panel) { $script:Panel.SetStatus('following the window you picked', $false) }
            } else {
                $script:Pinned = [IntPtr]::Zero
                if ($script:Panel) { $script:Panel.SetStatus('that window is not a mini player', $true) }
            }
        }
        'panel' { Show-Panel }
        'show'  { Show-Panel }
        'hide'  { Invoke-Hide }
        'quit'  { $script:Quit = $true }
        'geometry' {
            $script:Config.RememberGeometry = -not $script:Config.RememberGeometry
            Request-Save
        }
        'lock' {
            Set-LiveLock (-not $script:Config.Locked)
            if ($script:Panel) {
                $script:Panel.SetStatus($(if ($script:Config.Locked) { 'frame locked where it is' } else { 'frame free again' }), $false)
            }
        }
        'hover' {
            $script:Config.HoverControls = -not $script:Config.HoverControls
            Request-Save
            if (-not $script:Config.HoverControls) { Hide-Strip; Dispose-Strip }
        }
        'ontop' {
            $script:Config.KeepOnTop = -not $script:Config.KeepOnTop
            Request-Save
            if ($script:Config.KeepOnTop) {
                foreach ($p in @(Get-Players)) { [PipFade.Finder]::Raise($p.Handle) }
                $script:LastRaise = [DateTime]::UtcNow
            }
        }
        default {
            if ($action -like 'preset:*') {
                Apply-Preset ([int]($action -replace '^preset:', ''))
            }
        }
    }
    Sync-Panel
}

# A preset is an arrangement of the whole app, so it has to be stored from the
# live state. Applying one is a single pass: writing the fields one at a time
# through Set-LiveAlpha/Set-LiveClicks would save and re-apply twice.
function Apply-Preset([int]$index) {
    if ($index -lt 0 -or $index -ge $script:Config.Presets.Count) { return }
    $p = $script:Config.Presets[$index]
    $cfg = $script:Config
    $cfg.Alpha = [Math]::Max($MIN_ALPHA, [Math]::Min($MAX_ALPHA, [int]$p.Alpha))
    $cfg.ClickThrough = [bool]$p.ClickThrough
    $cfg.KeepOnTop = [bool]$p.KeepOnTop
    $cfg.HoverControls = [bool]$p.HoverControls
    $cfg.RememberGeometry = [bool]$p.RememberGeometry
    $cfg.AutoApply = [bool]$p.AutoApply
    $cfg.Locked = [bool]$p.Locked
    if (@('toggle', 'hold') -contains [string]$p.HideMode) { $cfg.HideMode = [string]$p.HideMode }

    Request-Save
    $script:Applied = @{}
    $script:LockRects = @{}
    if ($cfg.Locked) {
        foreach ($player in @(Get-Players)) {
            $script:LockRects['0x{0:X}' -f $player.Handle.ToInt64()] = [pscustomobject]@{ X = $player.X; Y = $player.Y; W = $player.W; H = $player.H }
        }
    }
    foreach ($player in @(Get-Players)) { Apply-ToPlayer $player -Force }
    Sync-Strip
    Sync-Panel
    if ($script:Panel) { $script:Panel.SetStatus(("applied {0}" -f $p.Name), $false) }
}

# "Store" on a preset row: capture the live settings into that slot. The name and
# binding already in the row are kept, because those are what the user typed.
function Save-Preset([int]$index, [string]$name) {
    if ($index -lt 0 -or $index -ge $script:Config.Presets.Count) { return }
    $cfg = $script:Config
    $p = $cfg.Presets[$index]
    $trimmed = ([string]$name).Trim()
    $p.Name = if ($trimmed) { $trimmed } else { "Preset $($index + 1)" }
    $p.Alpha = [int]$cfg.Alpha
    $p.ClickThrough = [bool]$cfg.ClickThrough
    $p.KeepOnTop = [bool]$cfg.KeepOnTop
    $p.HoverControls = [bool]$cfg.HoverControls
    $p.RememberGeometry = [bool]$cfg.RememberGeometry
    $p.AutoApply = [bool]$cfg.AutoApply
    $p.Locked = [bool]$cfg.Locked
    $p.HideMode = [string]$cfg.HideMode
    Save-Config $cfg
    Sync-Keys
    if ($script:Panel) {
        $script:Panel.SetStatus(("stored the current settings in {0}" -f $p.Name), $false)
    }
}

# A new preset starts as a copy of the live state, which is the only definition of
# "a preset" that makes sense here: the user arranges the player, then makes it.
function Add-Preset {
    $cfg = $script:Config
    if ($cfg.Presets.Count -ge $script:MaxPresets) { return }
    $base = [pscustomobject]@{
        ClickThrough     = [bool]$cfg.ClickThrough
        KeepOnTop        = [bool]$cfg.KeepOnTop
        HoverControls    = [bool]$cfg.HoverControls
        RememberGeometry = [bool]$cfg.RememberGeometry
        AutoApply        = [bool]$cfg.AutoApply
        Locked           = [bool]$cfg.Locked
        HideMode         = [string]$cfg.HideMode
    }
    $slot = $cfg.Presets.Count
    $list = @($cfg.Presets)
    $list += New-Preset ("Preset $($slot + 1)") ([int]$cfg.Alpha) '' $base
    $cfg.Presets = $list
    Save-Config $cfg
    Sync-Keys
    if ($script:Panel) { $script:Panel.SetStatus('added a preset; give it a key if you want one', $false) }
}

function Remove-Preset([int]$index) {
    $cfg = $script:Config
    if ($index -lt 0 -or $index -ge $cfg.Presets.Count) { return }
    $name = [string]$cfg.Presets[$index].Name
    $list = @($cfg.Presets)
    $kept = @()
    for ($i = 0; $i -lt $list.Count; $i++) { if ($i -ne $index) { $kept += $list[$i] } }
    # At least one slot always stays, so the tab cannot be emptied into a state
    # with nowhere to store anything.
    if ($kept.Count -eq 0) { return }
    $cfg.Presets = $kept
    Save-Config $cfg
    Restart-Hotkeys
    Sync-Keys
    if ($script:Panel) { $script:Panel.SetStatus(("removed {0}" -f $name), $false) }
}


# --------------------------------------------------------------------- tray
function New-TrayIcon {
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [PipFadeUI.Mark]::AppIcon([PipFadeUI.Mark]::ShellFore([PipFadeUI.Palette]::Accent))
    $ni.Text = 'pipfade'
    $ni.Visible = $true
    # The menu is drawn by the panel's own renderer: a system menu would arrive in
    # the light theme, which on a dark taskbar looks like a scrap of another
    # program. DarkMenu does the background, the hover plate, the separators and
    # the text colour; DarkColours feeds the professional renderer the few parts
    # it reads from a colour table instead of drawing itself.
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Renderer = New-Object PipFadeUI.DarkMenu
    $menu.BackColor = [PipFadeUI.Palette]::Surface
    $menu.ForeColor = [PipFadeUI.Palette]::Text
    $menu.ShowImageMargin = $false
    $menu.Font = [System.Drawing.Font]::new('Segoe UI', 8.75)
    $miShow = $menu.Items.Add('Open panel')
    $miShow.add_Click({ Show-Panel })
    $miSolid = $menu.Items.Add('Solid again')
    $miSolid.add_Click({ Set-LiveAlpha 255; Set-LiveClicks $false; Sync-Panel })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miReset = $menu.Items.Add('Reset size, position and opacity')
    $miReset.add_Click({ Reset-Everything })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miQuit = $menu.Items.Add('Quit')
    $miQuit.add_Click({ $script:Quit = $true })
    $ni.ContextMenuStrip = $menu
    $ni.add_MouseDoubleClick({ Show-Panel })
    return $ni
}

# ------------------------------------------------------------- update notice
# Asked once per launch, off the main thread. The app makes no other network
# request and this one is read-only: it fetches a small JSON document and does
# nothing with it but compare a number. Nothing is downloaded or installed, and
# a failure - offline, GitHub down, rate limited - is silent, because a settings
# window that complains about the internet is a worse neighbour than one that
# says nothing.
$script:UpdateTask = $null

function Start-UpdateCheck {
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        # GitHub rejects requests without a user agent.
        $client.DefaultRequestHeaders.Add('User-Agent', 'pipfade')
        $script:UpdateTask = $client.GetStringAsync('https://api.github.com/repos/LvSpook/pipfade/releases/latest')
    } catch {
        # No networking stack, or a locked-down machine: pretend it was asked and
        # answered nothing.
        $script:UpdateTask = $null
    }
}

function Test-NewerVersion([string]$latest) {
    if ([string]::IsNullOrWhiteSpace($latest)) { return $false }
    try {
        $a = [version]($latest.TrimStart('v', 'V'))
        $b = [version]$script:Version
        return ($a -gt $b)
    } catch { return $false }
}

# Called every pass. A completed task is checked once and then dropped, so the
# loop pays a single property read for as long as the request is in flight.
function Poll-UpdateCheck {
    if (-not $script:UpdateTask) { return }
    if (-not $script:UpdateTask.IsCompleted) { return }
    $task = $script:UpdateTask
    $script:UpdateTask = $null
    $tag = $null
    try {
        if (-not $task.IsFaulted -and -not $task.IsCanceled) {
            $json = $task.Result | ConvertFrom-Json
            if ($json.PSObject.Properties['tag_name']) { $tag = [string]$json.tag_name }
        }
    } catch { $tag = $null }
    if (-not $tag) { return }
    $script:LatestVersion = $tag.TrimStart('v', 'V')
    if (-not (Test-NewerVersion $script:LatestVersion)) { return }
    if ($script:Panel) { $script:Panel.ShowUpdate($script:LatestVersion) }
}

function Open-Download {
    # The release page rather than the zip: it is where the notes are, and a
    # browser download prompt is a decision the user should make with the
    # changelog in front of them.
    try { Start-Process 'https://github.com/LvSpook/pipfade/releases/latest' } catch { }
}

# ------------------------------------------------------------- panel wiring
function Show-Panel {
    if (-not $script:Panel) {
        $script:Syncing = $true
        $panel = New-Object PipFadeUI.PanelForm
        $script:Panel = $panel          # assign before wiring: events read this
        $panel.ResetRequested = { Reset-Everything }
        $panel.OpenDownload = { Open-Download }
        # Quit runs through the same path the tray menu uses, so the finally block
        # that restores every player and saves the config still runs.
        $panel.QuitRequested = { $script:Quit = $true }

        $panel.Slider.add_ValueChanged({
            if ($script:Syncing) { return }
            Set-LiveAlpha $script:Panel.Slider.Value
        })
        $panel.ClickSwitch.add_Toggled({
            if ($script:Syncing) { return }
            Set-LiveClicks $script:Panel.ClickSwitch.On
        })
        $panel.GeometrySwitch.add_Toggled({
            if ($script:Syncing) { return }
            $script:Config.RememberGeometry = $script:Panel.GeometrySwitch.On
            Save-Config $script:Config
        })
        $panel.LockSwitch.add_Toggled({
            if ($script:Syncing) { return }
            Set-LiveLock $script:Panel.LockSwitch.On
            $script:Panel.SetStatus($(if ($script:Config.Locked) { 'frame locked where it is' } else { 'frame free again' }), $false)
        })
        $panel.AutoSwitch.add_Toggled({
            if ($script:Syncing) { return }
            $script:Config.AutoApply = $script:Panel.AutoSwitch.On
            Save-Config $script:Config
            if ($script:Config.AutoApply) {
                foreach ($p in @(Get-Players)) { Apply-ToPlayer $p -Force }
            } else {
                foreach ($p in @(Get-Players)) { [PipFade.Finder]::Restore($p.Handle) }
                $script:Applied = @{}
            }
        })
        $panel.KeepTopSwitch.add_Toggled({
            if ($script:Syncing) { return }
            $script:Config.KeepOnTop = $script:Panel.KeepTopSwitch.On
            Save-Config $script:Config
            if ($script:Config.KeepOnTop) {
                foreach ($p in @(Get-Players)) { [PipFade.Finder]::Raise($p.Handle) }
                $script:LastRaise = [DateTime]::UtcNow
            }
        })
        $panel.StartupSwitch.add_Toggled({
            if ($script:Syncing) { return }
            if ($script:Panel.StartupSwitch.On) {
                if (-not (Enable-StartAtLogin)) {
                    $script:Panel.SetStatus('could not add to startup', $true)
                }
            } else {
                Disable-StartAtLogin
            }
        })
        $panel.HoverSwitch.add_Toggled({
            if ($script:Syncing) { return }
            $script:Config.HoverControls = $script:Panel.HoverSwitch.On
            Save-Config $script:Config
            if (-not $script:Config.HoverControls) { Hide-Strip; Dispose-Strip }
        })
        $panel.HoldSwitch.add_Toggled({
            if ($script:Syncing) { return }
            # Switching to hold leaves any toggle-hidden player hidden, so bring
            # it back first rather than stranding it off screen.
            if ($script:Config.HideMode -ne 'hold' -and $script:Panel.HoldSwitch.On) {
                [void](Show-PlayerAgain)
            }
            $script:Config.HideMode = if ($script:Panel.HoldSwitch.On) { 'hold' } else { 'toggle' }
            Save-Config $script:Config
        })
        $panel.KeysChanged = { Save-Keys }
        # The presets tab edits names and keys in place, but what a preset holds is
        # whatever the player looks like when the arrow is pressed. That is why
        # there is no percent box any more: the number alone was never the answer.
        $panel.PresetApplied = { param($slot) if ($slot -lt $script:Config.Presets.Count) { Apply-Preset $slot } }
        $panel.PresetSaved = { param($slot) Save-Preset $slot ([string]$script:Panel.PresetNames[$slot].Text2) }
        $panel.PresetRemoved = { param($slot) Remove-Preset $slot }
        $panel.PresetAdded = { Add-Preset }

        # Where the window was left. Written only after a real drag, so simply
        # clicking a switch never rewrites the settings file.
        $panel.Placed = {
            $script:Config.PanelX = $script:Panel.Left
            $script:Config.PanelY = $script:Panel.Top
            Request-Save
        }

        # Open where it was last left; fall back to the middle of the screen when
        # there is no remembered spot, or when that spot is on a monitor that is
        # no longer attached. A panel restored onto a disconnected screen would
        # be invisible, which is worse than losing the position.
        $v = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $panelX = [int]($v.Left + ($v.Width - $panel.Width) / 2)
        $panelY = [int]($v.Top + ($v.Height - $panel.Height) / 2)
        if ($null -ne $script:Config.PanelX -and [int]$script:Config.PanelX -ne -999999) {
            $px = [int]$script:Config.PanelX
            $py = [int]$script:Config.PanelY
            $onScreen = $px -lt ($v.Right - 40) -and ($px + $panel.Width) -gt ($v.Left + 40) -and
                        $py -lt ($v.Bottom - 40) -and ($py + $panel.Height) -gt ($v.Top + 40)
            if ($onScreen) { $panelX = $px; $panelY = $py }
        }
        # ...and then kept wholly on screen: the size cannot change, so a window
        # narrower than the screen should never be left with an edge past it.
        $panelX = [Math]::Max($v.Left, [Math]::Min($panelX, $v.Right - $panel.Width))
        $panelY = [Math]::Max($v.Top, [Math]::Min($panelY, $v.Bottom - $panel.Height))
        # A Point built with ::new rather than New-Object: a negative coordinate
        # in an -ArgumentList reads like a parameter name and is silently lost.
        $panel.Location = [System.Drawing.Point]::new($panelX, $panelY)

        Sync-Panel
        # The check may well have finished before this window existed: -Tray
        # starts without one. Whatever it found is waiting in the global.
        if ($script:LatestVersion -and (Test-NewerVersion $script:LatestVersion)) {
            $script:Panel.ShowUpdate($script:LatestVersion)
        }
        $script:Syncing = $false
    }
    $script:Panel.Show()
    $script:Panel.Activate()
}

function Hide-Panel {
    if ($script:Panel -and $script:Panel.Visible) { $script:Panel.Hide() }
}

# ------------------------------------------------------------- hotkey editor
# The bindings live in the Hotkeys and Presets tabs of the settings window, so
# there is no second window to open, position or dismiss. Labels come from the
# UI assembly's Labels table, which is also what the panel lays itself out from.

# One line per preset describing what it restores, so the row says more than its
# name. Built from the preset itself rather than from the live config: this is a
# label about stored settings, not about the current state.
function Describe-Preset($preset) {
    $bits = @()
    $bits += ('{0}%' -f [int][Math]::Round(([int]$preset.Alpha) / 255.0 * 100))
    if ($preset.ClickThrough) { $bits += 'click-through' }
    if (-not $preset.HoverControls) { $bits += 'no bar' }
    if (-not $preset.KeepOnTop) { $bits += 'not on top' }
    if (-not $preset.AutoApply) { $bits += 'opaque until applied' }
    if ($preset.Locked) { $bits += 'frame locked' }
    if ([string]$preset.HideMode -eq 'hold') { $bits += 'hold to hide' }
    # A plain comma: this string is drawn by GDI with a system font, and the
    # typographic separators that look nicer in a text editor arrive as mojibake
    # when the script is read back with a different ANSI code page.
    return ($bits -join ', ')
}

# Push the saved bindings into the boxes. Guarded by Syncing so filling a box
# does not look like the user editing it.
function Sync-Keys {
    $p = $script:Panel
    if (-not $p -or -not $p.KeyFields) { return }
    $p.Syncing = $true
    try {
        for ($i = 0; $i -lt [PipFadeUI.Labels]::Count; $i++) {
            $action = [PipFadeUI.Labels]::Action($i)
            if ($p.KeyFields.ContainsKey($action)) {
                $field = $p.KeyFields[$action]
                # A box waiting for a keypress shows a placeholder, not a binding:
                # writing the saved value into it would look like the capture failed.
                if (-not $field.Recording) { $field.Text2 = [string]$script:Config.Hotkeys.$action }
            }
        }
        $names = New-Object 'string[]' ($script:MaxPresets)
        $keys = New-Object 'string[]' ($script:MaxPresets)
        $summary = New-Object 'string[]' ($script:MaxPresets)
        for ($i = 0; $i -lt $script:MaxPresets; $i++) {
            if ($i -lt $script:Config.Presets.Count) {
                $preset = $script:Config.Presets[$i]
                $names[$i] = [string]$preset.Name
                $keys[$i] = [string]$preset.Hotkey
                $summary[$i] = Describe-Preset $preset
            } else {
                $names[$i] = ''
                $keys[$i] = ''
                $summary[$i] = ''
            }
        }
        $p.SetPresetRows($script:Config.Presets.Count, $names, $keys, $summary)
    } finally {
        $p.Syncing = $false
    }
}

# Everything is validated before anything is written: one bad binding must not
# leave the user with half their keys rebound. Only names and bindings are read
# here — a preset's settings come from Save-Preset, which stores what the player
# currently looks like, not from a box on this tab.
function Save-Keys {
    $f = $script:Panel
    if (-not $f -or -not $f.KeyFields) { return }

    $bad = @()
    $dead = @()
    $clean = [ordered]@{}
    for ($i = 0; $i -lt [PipFadeUI.Labels]::Count; $i++) {
        $action = [PipFadeUI.Labels]::Action($i)
        if (-not $f.KeyFields.ContainsKey($action)) { continue }
        # A box still waiting for a keypress holds a placeholder, not a binding;
        # saving it would store "press a key combination" as a hotkey.
        if ($f.KeyFields[$action].Recording) { continue }
        $text = [string]$f.KeyFields[$action].Text2
        if ([string]::IsNullOrWhiteSpace($text)) { $clean[$action] = ''; continue }
        $spec = ConvertTo-HotkeySpec $text
        if (-not $spec) { $bad += $text; continue }
        # Typed or pasted text takes the same route as the recorder, so a
        # combination Windows cannot deliver is refused here too rather than
        # saving quietly and never firing.
        if ([PipFadeUI.Hotkey]::Unreachable($spec.Mods, $spec.Vk)) { $dead += $text; continue }
        $clean[$action] = $text
    }

    $count = [Math]::Min($script:Config.Presets.Count, $script:MaxPresets)
    for ($i = 0; $i -lt $count; $i++) {
        $box = $f.PresetKeys[$i]
        if ($box.Recording) { continue }
        $hk = ([string]$box.Text2).Trim()
        if ([string]::IsNullOrWhiteSpace($hk)) { continue }
        $spec = ConvertTo-HotkeySpec $hk
        if (-not $spec) { $bad += $hk; continue }
        if ([PipFadeUI.Hotkey]::Unreachable($spec.Mods, $spec.Vk)) { $dead += $hk }
    }

    if ($dead.Count -gt 0) {
        $f.SetStatus('Shift + keypad needs NumLock off', $true)
        return
    }

    if ($bad.Count -gt 0) {
        $f.SetStatus('not a key name: ' + (($bad | Select-Object -Unique) -join ', '), $true)
        return
    }

    foreach ($action in $clean.Keys) { $script:Config.Hotkeys.$action = $clean[$action] }

    for ($i = 0; $i -lt $count; $i++) {
        $preset = $script:Config.Presets[$i]
        $name = ([string]$f.PresetNames[$i].Text2).Trim()
        $preset.Name = if ($name) { $name } else { "Preset $($i + 1)" }
        if (-not $f.PresetKeys[$i].Recording) {
            $preset.Hotkey = ([string]$f.PresetKeys[$i].Text2).Trim()
        }
    }
    Request-Save

    Restart-Hotkeys
    Sync-Keys

    if ($script:HkFailed -and $script:HkFailed.Count -gt 0) {
        # Valid text, but Windows refused the key because another app owns it.
        $f.SetStatus('taken: ' + (($script:HkFailed | Select-Object -Unique) -join ', '), $true)
        return
    }
    $f.SetStatus('keys saved', $false)
}



# ------------------------------------------------------- autostart + instance
# A startup shortcut runs the script through wscript so no console window flashes.
$script:StartupDir = [Environment]::GetFolderPath('Startup')
$script:StartupVbs = Join-Path $script:StartupDir 'pipfade.vbs'

function Test-StartAtLogin {
    return (Test-Path $script:StartupVbs)
}

function Enable-StartAtLogin {
    $target = Join-Path $script:Root 'pipfade.ps1'
    $lines = @(
        'Set sh = CreateObject("WScript.Shell")',
        ('sh.Run "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{0}"" -Tray", 0, False' -f $target)
    )
    try {
        $lines -join "`r`n" | Set-Content $script:StartupVbs -Encoding ASCII
        return $true
    } catch {
        Write-Warning "could not enable start at login: $($_.Exception.Message)"
        return $false
    }
}

function Disable-StartAtLogin {
    if (Test-Path $script:StartupVbs) { Remove-Item $script:StartupVbs -Force }
}

# The file you double-click has no icon of its own: Windows always draws a .vbs
# with the script-host icon and a .cmd with the console icon. So the icon is
# written as a real .ico next to the script and carried by a shortcut, which is
# the one kind of launcher that can hold an image.
function Write-Launcher {
    $ico = Join-Path $script:Root 'pipfade.ico'
    $lnk = Join-Path $script:Root 'Start pipfade.lnk'
    $vbs = Join-Path $script:Root 'Start pipfade.vbs'
    try {
        # Rewritten every start: five frames of a few hundred bytes each, and it
        # keeps the file matching the mark the rest of the app draws.
        $bytes = [PipFadeUI.Mark]::IconBytes([PipFadeUI.Mark]::ShellFore([PipFadeUI.Palette]::Accent))
        [System.IO.File]::WriteAllBytes($ico, $bytes)

        if (Test-Path $vbs) {
            $sh = New-Object -ComObject WScript.Shell
            $s = $sh.CreateShortcut($lnk)
            $s.TargetPath = $vbs
            $s.WorkingDirectory = $script:Root
            $s.IconLocation = "$ico,0"
            $s.Description = 'pipfade - see-through mini player'
            # wscript starts the hidden powershell itself, so the shortcut is only
            # here for the icon; the window style keeps a taskbar flash off it.
            $s.WindowStyle = 7
            $s.Save()
        }
    } catch {
        # A read-only folder is not a reason to refuse to run.
        Write-Warning "could not write the launcher icon: $($_.Exception.Message)"
    }
}

# Only one watcher at a time; a second copy would fight the first over alpha.
$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\pipfade-single-instance')

function Try-AcquireInstance {
    try { return $script:Mutex.WaitOne(0, $false) }
    catch { return $true }   # already owned by us in this process, or abandoned
}

function Release-Instance {
    try { $script:Mutex.ReleaseMutex() } catch { }
}


# ------------------------------------------------------------------- modes
# Read-only and one-shot modes never take the instance lock.
if ($List) {
    $pips = @(Get-Players)
    if ($pips.Count -eq 0) {
        Write-Host 'No mini player found.'
        Write-Host ''
        Write-Host 'Open one first: start a video, hover it, click the picture-in-picture'
        Write-Host 'button, then run this again.'
    } else {
        $pips | Select-Object Proc, Title, @{n='Size';e={"$($_.W)x$($_.H)"}},
            @{n='Position';e={"$($_.X),$($_.Y)"}}, ClickThrough | Format-Table -AutoSize
    }
    return
}

if ($Reset) {
    # RestoreAll only knows about windows faded by this very process, which for a
    # one-shot run is none of them. The search covers the live players, and the
    # stale repair catches a window left translucent by a run that was killed
    # before its cleanup could happen.
    $done = 0
    foreach ($p in @(Get-Players)) { [PipFade.Finder]::Restore($p.Handle); $done++ }
    foreach ($p in @([PipFade.Finder]::Find())) {
        if ([PipFade.Finder]::RestoreStale($p.Handle)) { $done++ }
    }
    $script:Config.Alpha = 255
    $script:Config.ClickThrough = $false
    $script:Config.Geometry = @{}
    [void](Save-Config $script:Config)
    if ($done -eq 0) { Write-Host 'No mini player found to reset.' }
    else { Write-Host ("Reset {0} window(s) to normal; saved settings cleared." -f $done) }
    return
}

if ($Alpha -ge 0) {
    $script:Config.Alpha = [Math]::Max($MIN_ALPHA, [Math]::Min($MAX_ALPHA, $Alpha))
    [void](Save-Config $script:Config)
    if ($Hwnd) { $script:Pinned = [IntPtr]([Convert]::ToInt64($Hwnd.TrimStart('0x'), 16)) }
    $targets = @(Get-Players)
    if ($targets.Count -eq 0) { Write-Host 'No mini player found.'; return }
    $script:Config.AutoApply = $true
    foreach ($p in $targets) { Apply-ToPlayer $p -Force }
    Write-Host ("Set {0} player(s) to alpha {1}." -f $targets.Count, $script:Config.Alpha)
    return
}

# ------------------------------------------------------------ resident mode
if (-not (Try-AcquireInstance)) {
    Write-Host 'pipfade is already running (look for its tray icon, or press Ctrl+Alt+A).'
    return
}

if ($Hwnd) { $script:Pinned = [IntPtr]([Convert]::ToInt64($Hwnd.TrimStart('0x'), 16)) }
$script:Syncing = $false
Install-Hotkeys

# The hook makes a new player appear to adopt the saved look at once. The slow
# sweep behind it is a backstop: hooks can be missed if a window is shown before
# the hook was installed, or if this thread stalls.
$script:Watcher = New-Object PipFade.ShownWatcher
if (-not $script:Watcher.Start()) {
    $script:Watcher = $null
    Write-Host 'window watcher unavailable; falling back to polling.'
}

if (-not $Tray) { Show-Panel }

# Catch anything that was already open before the hook was installed. Without
# this, a player that is on screen when pipfade starts waits for the one-second
# sweep, and looks untouched for that long.
$existing = Adopt-Existing
if ($existing -gt 0) { Update-Status $existing }
# A player that was already open at launch deserves the bar straight away: the
# pointer is usually still sitting over the video the user just popped out, and
# waiting for a pointer move or the next sweep is why the bar seemed missing
# after starting pipfade with a mini player already on screen.
if ($existing -gt 0 -and $script:Config.HoverControls) { $script:Dirty = $true }

# The tray icon is the app's home. It is created in every mode now, not just
# when started with -Tray: the launchers pass no arguments, so the icon used to
# be missing exactly when the app was started by hand.
$script:TrayIcon = New-TrayIcon

# Keep the .ico and the shortcut in step with the mark this build draws.
Write-Launcher

# One request per launch, on a background task, so a slow or absent network
# never delays the window appearing.
Start-UpdateCheck

try {
    while (-not $script:Quit) {
        # Idle waits are long because nothing needs sub-second timing; once the
        # strip is on screen, the pointer is over a player, or a window is being
        # dragged, the wait shrinks so the bar reacts within a frame or two.
        $now = [DateTime]::UtcNow
        # What this pass has to decide is only whether the loop needs to run at
        # frame rate: a fade in flight, a key being held down, an open percentage
        # field. Everything else - a click on the bar, a hotkey, a player
        # appearing or moving, the pointer arriving on a video - arrives as a
        # message or as an edge from the native watch, and wakes the loop by
        # itself without any polling here.
        $near = Test-CursorNearPlayer
        $visible = ($script:Strip -and $script:Strip.Visible)
        $hot = $script:Config.HoverControls -and (
                    ($now - $script:MovedAt).TotalMilliseconds -lt 400 -or
                    $visible -or $near)
        # Hold-to-hide has to notice the key coming up within a frame, so the
        # wait shrinks while a hold is in progress.
        $holding = ($script:Config.HideMode -eq 'hold') -and ($script:HoldActive -or $script:HiddenFor -ne [IntPtr]::Zero)
        $animating = ($script:Strip -and $script:Strip.Animating)
        # Almost always a full second, because nothing actually waits on this
        # number. What the budget controls is how often PowerShell pays for a
        # pass at all, and a pass with nothing to do still costs about a
        # millisecond of interpreter time - at four passes a second that was most
        # of this process's CPU.
        #
        # The bar on screen is the one case that wants a short wait without being
        # a fade: the grace period after the pointer leaves has to be honoured
        # promptly, or the bar lingers for up to a second after the pointer has
        # gone. That state is transient, so the cost is bounded.
        $wait = 1000
        if ($visible) { $wait = 60 }
        if ($holding -or $script:StripEntry -or $animating) { $wait = 16 }
        # Two different waits, because they do different jobs. While something is
        # happening the loop must come back the moment a message arrives (a click
        # on the bar, a key going up), so it waits on the message queue. While
        # nothing is happening no message is expected that matters, and a message
        # wait there is worse than useless: it wakes on input the queue does not
        # actually hold, and every such wake costs a whole PowerShell pass. So
        # the idle case sleeps, only waking early if the pointer reaches a player.
        if ($hot -or $holding) { Wait-Messages $wait } else { [void][PipFade.Win]::IdleWait([uint32]$wait) }
        [System.Windows.Forms.Application]::DoEvents()
        Poll-UpdateCheck

        if ($script:Watcher) {
            # process the whole queue; the sweep would eventually catch any we
            # skipped, but there is no reason to delay them by a second
            foreach ($h in $script:Watcher.TakeShown()) { [void](Apply-NewHandle $h) }
            if ($script:Watcher.TakeForegroundMoved()) {
                $script:ForeMoved = $true
                $script:Dirty = $true
            }
            $movedHwnd = [IntPtr]::Zero
            if ($script:Watcher.TakeMoved([ref]$movedHwnd)) {
                # Only a player's own movement matters. Every window in the
                # system raises location changes (a playing video, a blinking
                # cursor), so reacting to all of them would make the bar flicker.
                if (Test-PlayerHandle $movedHwnd) {
                    $script:MovedAt = [DateTime]::UtcNow
                }
            }
        }

        $now = [DateTime]::UtcNow
        # The sweep is a backstop, not the mechanism. A new player is caught by the
        # window hooks the moment it appears, a player that moves is caught by the
        # location-change hook, and the pointer reaching a player wakes the native
        # wait within 25ms. What is left for the sweep is geometry settling after a
        # drag and the once-over-everything keep-on-top check, and both of those
        # tolerate a few seconds - which matters, because every pass of this loop
        # costs about a millisecond of interpreter time whether or not it finds
        # anything to do.
        $sweepDue = ($now - $script:LastFull).TotalMilliseconds -gt 3000
        # a raise scheduled by a foreground change needs its own pass when due
        $raiseDue = ($script:RaiseAt -ne [DateTime]::MinValue -and $now -ge $script:RaiseAt)
        if ($script:Dirty -or $sweepDue -or $raiseDue) {
            $script:Dirty = $false
            $script:LastFull = $now
            Step
        }

        if ($hot) {
            Refresh-PlayerRects
            Step-Strip @($script:Players)
            [System.Windows.Forms.Application]::DoEvents()
        }

        # Hold-to-hide is the one thing that needs frequent checking while a key
        # is down; it returns immediately in toggle mode.
        Step-HoldHide

        Flush-Save
    }
}
finally {
    if ($script:Watcher) { $script:Watcher.Dispose() }
    if ($script:Hotkeys) { $script:Hotkeys.Dispose() }
    Dispose-Strip
    # Never leave a player hidden: quitting must give the window back.
    [void](Show-PlayerAgain)
    # RestoreAll covers every window this run faded, not just the one that is
    # currently under the pointer. Two players open at once both get faded, and
    # a window that has since stopped matching the detector would otherwise be
    # left translucent with nothing running to undo it.
    [void][PipFade.Finder]::RestoreAll()
    foreach ($p in @(Get-Players)) { [PipFade.Finder]::Restore($p.Handle) }
    [void](Save-Config $script:Config)
    if ($script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() }
    if ($script:Panel) { $script:Panel.Dispose() }
    Release-Instance
    Write-Host 'pipfade stopped; mini player back to normal.'
}

