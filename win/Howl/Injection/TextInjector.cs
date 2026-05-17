using System.Runtime.InteropServices;
using System.Windows;

namespace Howl.Injection;

internal static class TextInjector
{
    private const uint InputKeyboard = 1;
    private const ushort VkControl   = 0x11;
    private const ushort VkV         = 0x56;
    private const uint KeyUp         = 0x0002;
    private const uint KeyUnicode    = 0x0004;
    private const uint WmPaste       = 0x0302;

    [DllImport("user32.dll")] private static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);

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

    internal static void CaptureTargetWindow() => _targetWindow = GetForegroundWindow();

    // ── Clipboard inject: set clipboard then WM_PASTE directly to target control ──

    internal static async Task InjectClipboardAsync(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;

        // Snapshot the focused control inside the target window right now.
        // GetGUIThreadInfo doesn't need the window to be foreground.
        uint targetThread = GetWindowThreadProcessId(_targetWindow, out _);
        var gti = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
        GetGUIThreadInfo(targetThread, ref gti);
        IntPtr targetControl = gti.hwndFocus != IntPtr.Zero ? gti.hwndFocus : _targetWindow;

        // Set clipboard (already on UI/STA thread via DispatcherTimer continuation).
        string? saved = Clipboard.ContainsText() ? Clipboard.GetText() : null;
        Clipboard.SetText(text);

        // Send WM_PASTE directly — works without stealing focus.
        PostMessage(targetControl, WmPaste, IntPtr.Zero, IntPtr.Zero);

        await Task.Delay(100);

        if (saved is not null) Clipboard.SetText(saved);
        else Clipboard.Clear();
    }

    // ── Unicode streaming (for future streaming injection) ──────────────────

    internal static void InjectStreaming(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        var units = text.Select(c => (ushort)c).ToArray();
        var inputs = new INPUT[units.Length * 2];
        for (int i = 0; i < units.Length; i++)
        {
            inputs[i * 2]     = MakeUnicode(units[i], 0);
            inputs[i * 2 + 1] = MakeUnicode(units[i], KeyUp);
        }
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static INPUT MakeVKey(ushort vk, uint flags) => new()
        { type = InputKeyboard, u = new INPUT_UNION { ki = new KEYBDINPUT { wVk = vk, dwFlags = flags } } };

    private static INPUT MakeUnicode(ushort scan, uint flags) => new()
        { type = InputKeyboard, u = new INPUT_UNION { ki = new KEYBDINPUT { wScan = scan, dwFlags = KeyUnicode | flags } } };
}
