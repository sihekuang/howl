using System.Runtime.InteropServices;
using System.Windows;

namespace Howl.Injection;

internal static class TextInjector
{
    // ── SendInput structures ──────────────────────────────────────────────

    private const uint InputKeyboard    = 1;
    private const ushort VkControl      = 0x11;
    private const ushort VkV            = 0x56;
    private const uint KeyUp            = 0x0002;
    private const uint KeyUnicode       = 0x0004;

    [DllImport("user32.dll")] private static extern uint SendInput(uint n, INPUT[] inputs, int size);

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUT_UNION { [FieldOffset(0)] public KEYBDINPUT ki; }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public INPUT_UNION u; }

    // ── Streaming: inject text character-by-character via SendInput ───────
    // Used for LLM chunk events so text appears at the cursor as it streams.

    internal static void InjectStreaming(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        // Convert to UTF-16 code units (handles surrogates automatically)
        var units = text.Select(c => (ushort)c).ToArray();
        var inputs = new INPUT[units.Length * 2];
        for (int i = 0; i < units.Length; i++)
        {
            inputs[i * 2]     = MakeUnicode(units[i], 0);
            inputs[i * 2 + 1] = MakeUnicode(units[i], KeyUp);
        }
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    // ── Clipboard paste: save → set → Ctrl+V → restore ───────────────────
    // Used for the final result event (fallback when no chunks were streamed).

    internal static async Task InjectClipboardAsync(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        string? saved = null;
        Application.Current.Dispatcher.Invoke(() =>
        {
            saved = Clipboard.ContainsText() ? Clipboard.GetText() : null;
            Clipboard.SetText(text);
        });

        SendCtrlV();
        await Task.Delay(50);

        Application.Current.Dispatcher.Invoke(() =>
        {
            if (saved is not null) Clipboard.SetText(saved);
            else Clipboard.Clear();
        });
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private static void SendCtrlV()
    {
        INPUT[] inputs =
        [
            MakeVKey(VkControl, 0),
            MakeVKey(VkV,       0),
            MakeVKey(VkV,       KeyUp),
            MakeVKey(VkControl, KeyUp),
        ];
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static INPUT MakeVKey(ushort vk, uint flags) => new()
        { type = InputKeyboard, u = new INPUT_UNION { ki = new KEYBDINPUT { wVk = vk, dwFlags = flags } } };

    private static INPUT MakeUnicode(ushort scan, uint flags) => new()
        { type = InputKeyboard, u = new INPUT_UNION { ki = new KEYBDINPUT { wScan = scan, dwFlags = KeyUnicode | flags } } };
}
