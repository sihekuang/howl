using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace Howl.Injection;

internal static class TextInjector
{
    private const uint InputKeyboard = 1;
    private const ushort VkControl   = 0x11;
    private const ushort VkShift     = 0x10;
    private const ushort VkAlt       = 0x12;
    private const uint KeyUp         = 0x0002;
    private const uint KeyUnicode    = 0x0004;
    private const uint WmPaste       = 0x0302;
    private const uint WmChar        = 0x0102;

    [DllImport("user32.dll")] private static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder buf, int max);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumChildProc fn, IntPtr lp);
    private delegate bool EnumChildProc(IntPtr hwnd, IntPtr lp);

    [StructLayout(LayoutKind.Sequential)]
    private struct GUITHREADINFO
    {
        public int cbSize, flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public int left, top, right, bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUT_UNION { [FieldOffset(0)] public KEYBDINPUT ki; }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public INPUT_UNION u; }

    private static IntPtr _targetWindow;
    private static AutomationElement? _targetElement;

    internal static Action<string>? Log;

    internal static void CaptureTargetWindow()
    {
        _targetWindow = GetForegroundWindow();
        try
        {
            _targetElement = AutomationElement.FocusedElement;
            Log?.Invoke($"capture: window='{WindowClass(_targetWindow)}' element='{_targetElement?.Current.ClassName}' name='{_targetElement?.Current.Name}'");
        }
        catch (Exception ex)
        {
            _targetElement = null;
            Log?.Invoke($"capture: element failed ({ex.GetType().Name})");
        }
    }

    // ── Main injection entry point ────────────────────────────────────────
    //
    // Strategy: inject as Unicode keystrokes — the universal approach used by
    // Dragon and Windows Speech Recognition. Works in every app (Notepad,
    // Chrome, VS Code, Word, terminals) without clipboard or app cooperation.
    // Only requires the target window to be foreground, which it normally is
    // because our overlay uses ShowActivated=False.
    //
    // Exception: native Win32 Edit/RichEdit controls respond faster and more
    // reliably to WM_PASTE, so they keep the direct-paste fast path.

    internal static async Task InjectAsync(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;

        // ── Tier 1: native Win32 Edit/RichEdit — WM_PASTE (Notepad, WordPad) ──
        if (TryNativeEditPaste())
        {
            Log?.Invoke("inject: WM_PASTE → Edit/RichEdit");
            return;
        }

        // ── Tier 2: Chromium/Electron renderer — WM_CHAR direct to renderer HWND ──
        // Bypasses the foreground/focus requirement entirely, like Tier 1 for native controls.
        // Covers Chrome, Edge, VS Code, Discord, and all Electron apps.
        IntPtr renderer = FindChromiumRenderer(_targetWindow);
        if (renderer != IntPtr.Zero)
        {
            Log?.Invoke($"inject: WM_CHAR × {text.Length} → Chrome_RenderWidgetHostHWND");
            foreach (char c in text)
                PostMessage(renderer, WmChar, (IntPtr)c, (IntPtr)1);
            return;
        }

        // ── Tier 3: Unicode SendInput — universal fallback for all other apps ──
        if (GetForegroundWindow() != _targetWindow)
        {
            Log?.Invoke("inject: target not foreground — restoring");
            BringTargetToForeground();
            await Task.Delay(150);
        }
        else if (_targetElement != null)
        {
            try   { _targetElement.SetFocus(); }
            catch { _targetElement = null; }
            await Task.Delay(50);
        }

        Log?.Invoke($"inject: Unicode SendInput ({text.Length} chars)");
        ReleaseModifiers();
        InjectUnicode(text);
    }

    // ── Kept for callers that already pass through InjectAsync ───────────

    internal static async Task InjectClipboardAsync(string text) => await InjectAsync(text);

    // ── Chromium renderer discovery ───────────────────────────────────────

    private static IntPtr FindChromiumRenderer(IntPtr parent)
    {
        IntPtr found = IntPtr.Zero;
        EnumChildProc proc = (hwnd, _) =>
        {
            if (WindowClass(hwnd) == "Chrome_RenderWidgetHostHWND")
            {
                found = hwnd;
                return false;
            }
            return true;
        };
        EnumChildWindows(parent, proc, IntPtr.Zero);
        return found;
    }

    // ── Win32 native paste ────────────────────────────────────────────────

    private static bool TryNativeEditPaste()
    {
        uint tid = GetWindowThreadProcessId(_targetWindow, out _);
        var gti = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
        GetGUIThreadInfo(tid, ref gti);
        IntPtr ctrl = gti.hwndFocus != IntPtr.Zero ? gti.hwndFocus : _targetWindow;
        if (!IsNativeEditControl(ctrl)) return false;
        PostMessage(ctrl, WmPaste, IntPtr.Zero, IntPtr.Zero);
        return true;
    }

    private static bool IsNativeEditControl(IntPtr hwnd)
    {
        string cls = WindowClass(hwnd);
        return cls.StartsWith("Edit",     StringComparison.OrdinalIgnoreCase)
            || cls.StartsWith("RichEdit", StringComparison.OrdinalIgnoreCase);
    }

    // ── Focus helpers ─────────────────────────────────────────────────────

    private static void BringTargetToForeground()
    {
        uint tid     = GetWindowThreadProcessId(_targetWindow, out _);
        uint current = GetCurrentThreadId();
        AttachThreadInput(current, tid, true);
        SetForegroundWindow(_targetWindow);
        if (_targetElement != null)
        {
            try   { _targetElement.SetFocus(); }
            catch { _targetElement = null; }
        }
        AttachThreadInput(current, tid, false);
    }

    // ── Input injection ───────────────────────────────────────────────────

    private static void ReleaseModifiers()
    {
        INPUT[] ups =
        [
            MakeVKey(VkControl, KeyUp),
            MakeVKey(VkShift,   KeyUp),
            MakeVKey(VkAlt,     KeyUp),
        ];
        SendInput((uint)ups.Length, ups, Marshal.SizeOf<INPUT>());
    }

    private static void InjectUnicode(string text)
    {
        var inputs = new INPUT[text.Length * 2];
        for (int i = 0; i < text.Length; i++)
        {
            inputs[i * 2]     = MakeUnicode(text[i], 0);
            inputs[i * 2 + 1] = MakeUnicode(text[i], KeyUp);
        }
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    internal static void InjectStreaming(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        InjectUnicode(text);
    }

    private static string WindowClass(IntPtr hwnd)
    {
        var sb = new System.Text.StringBuilder(64);
        GetClassName(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    private static INPUT MakeVKey(ushort vk, uint flags) => new()
        { type = InputKeyboard, u = new INPUT_UNION { ki = new KEYBDINPUT { wVk = vk, dwFlags = flags } } };

    private static INPUT MakeUnicode(char c, uint flags) => new()
        { type = InputKeyboard, u = new INPUT_UNION { ki = new KEYBDINPUT { wScan = c, dwFlags = KeyUnicode | flags } } };
}
