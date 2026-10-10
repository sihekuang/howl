using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Howl.Hotkey;

internal sealed class HotkeyManager : IDisposable
{
    private const int WmHotkey = 0x0312;
    private const int HotkeyId = 9000;
    private const uint ModCtrl  = 0x0002;
    private const uint ModShift = 0x0004;
    private const int VkControl = 0x11;
    private const int VkShift   = 0x10;
    private const int VkSpace   = 0x20;
    private const int VkEscape  = 0x1B;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    internal event EventHandler?         Pressed;
    internal event EventHandler?         Released;
    internal event EventHandler?         Cancelled;
    internal event EventHandler<string>? Failed;     // carries error description

    private bool _isHeld;
    private readonly bool _registered;

    internal HotkeyManager()
    {
        _registered = RegisterHotKey(IntPtr.Zero, HotkeyId, ModCtrl | ModShift, VkSpace);
        if (!_registered)
        {
            int err = Marshal.GetLastWin32Error();
            // Defer the event so subscribers can wire up after construction
            Dispatcher.CurrentDispatcher.BeginInvoke(() =>
                Failed?.Invoke(this, $"Ctrl+Shift+Space is owned by another app (Win32 error {err}). " +
                                     "Change the hotkey in Settings."));
            return;
        }
        ComponentDispatcher.ThreadPreprocessMessage += OnMessage;
    }

    private void OnMessage(ref MSG msg, ref bool handled)
    {
        if (msg.message != WmHotkey || msg.wParam.ToInt32() != HotkeyId || _isHeld)
            return;

        _isHeld = true;
        Pressed?.Invoke(this, EventArgs.Empty);
        handled = true;

        // Poll in background until the hotkey is released or Escape is pressed
        Task.Run(async () =>
        {
            while ((GetAsyncKeyState(VkControl) & 0x8000) != 0 &&
                   (GetAsyncKeyState(VkShift)   & 0x8000) != 0 &&
                   (GetAsyncKeyState(VkSpace)   & 0x8000) != 0)
            {
                if ((GetAsyncKeyState(VkEscape) & 0x8000) != 0)
                {
                    _isHeld = false;
                    Application.Current.Dispatcher.Invoke(() => Cancelled?.Invoke(this, EventArgs.Empty));
                    return;
                }
                await Task.Delay(16);
            }
            _isHeld = false;
            Application.Current.Dispatcher.Invoke(() => Released?.Invoke(this, EventArgs.Empty));
        });
    }

    public void Dispose()
    {
        if (_registered)
        {
            ComponentDispatcher.ThreadPreprocessMessage -= OnMessage;
            UnregisterHotKey(IntPtr.Zero, HotkeyId);
        }
    }
}
