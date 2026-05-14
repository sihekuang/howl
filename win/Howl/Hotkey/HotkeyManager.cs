using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace Howl.Hotkey;

internal sealed class HotkeyManager : IDisposable
{
    private const int WmHotkey = 0x0312;
    private const int HotkeyId = 9000;
    private const uint ModCtrl = 0x0002;
    private const uint ModShift = 0x0004;
    private const uint VkSpace = 0x20;

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    internal event EventHandler? Pressed;

    internal HotkeyManager()
    {
        RegisterHotKey(IntPtr.Zero, HotkeyId, ModCtrl | ModShift, VkSpace);
        ComponentDispatcher.ThreadPreprocessMessage += OnMessage;
    }

    private void OnMessage(ref MSG msg, ref bool handled)
    {
        if (msg.message != WmHotkey || msg.wParam.ToInt32() != HotkeyId)
            return;
        Pressed?.Invoke(this, EventArgs.Empty);
        handled = true;
    }

    public void Dispose()
    {
        ComponentDispatcher.ThreadPreprocessMessage -= OnMessage;
        UnregisterHotKey(IntPtr.Zero, HotkeyId);
    }
}
