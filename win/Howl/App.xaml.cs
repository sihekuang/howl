using System.Windows;
using Application = System.Windows.Application;
using Howl.Hotkey;
using Howl.Native;
using Howl.Tray;

namespace Howl;

public partial class App : Application
{
    private TrayManager? _tray;
    private HotkeyManager? _hotkey;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, ex) =>
        {
            var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "howl-error.txt");
            System.IO.File.WriteAllText(path, ex.Exception.ToString());
            ex.Handled = true;
            Shutdown(1);
        };
        NativeMethods.howl_init();
        _tray = new TrayManager(quit: Quit);
        _hotkey = new HotkeyManager();
        _hotkey.Pressed += OnHotkeyPressed;
    }

    private void OnHotkeyPressed(object? sender, EventArgs e)
    {
        // Step 5: wire howl_start_capture / howl_stop_capture here
    }

    private void Quit()
    {
        _hotkey?.Dispose();
        _hotkey = null;
        _tray?.Dispose();
        _tray = null;
        NativeMethods.howl_destroy();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _hotkey?.Dispose();
        _tray?.Dispose();
        base.OnExit(e);
    }
}
