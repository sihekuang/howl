using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;
using Application = System.Windows.Application;
using Howl.Audio;
using Howl.Engine;
using Howl.Hotkey;
using Howl.Injection;
using Howl.Native;
using Howl.Overlay;
using Howl.Settings;
using Howl.Sounds;
using Howl.Tray;

namespace Howl;

public partial class App : Application
{
    private static readonly string LogPath =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Desktop), "howl-error.txt");

    static App()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            File.WriteAllText(LogPath, args.ExceptionObject?.ToString() ?? "unknown");
    }

    private TrayManager?      _tray;
    private HotkeyManager?    _hotkey;
    private EnginePoller?     _poller;
    private AudioCapture?     _capture;
    private RecordingOverlay? _overlay;
    private AppSettings       _settings = new();
    private bool              _isCapturing;
    private bool              _chunksReceived;
    private bool              _needsConfigure;

    // ── Native return-code helpers ────────────────────────────────────────

    // Throws on non-zero — use for init/configure where failure is fatal.
    private static void CheckOrThrow(int rc, string op)
    {
        if (rc == 0) return;
        var msg = NativeMethods.MarshalAndFree(NativeMethods.howl_last_error()) ?? "(no detail)";
        throw new InvalidOperationException($"{op} failed rc={rc}: {msg}");
    }

    // Logs on non-zero — use for frequent/non-fatal calls (push_audio, stop, cancel).
    private void CheckOrLog(int rc, string op)
    {
        if (rc == 0) return;
        var msg = NativeMethods.MarshalAndFree(NativeMethods.howl_last_error()) ?? "(no detail)";
        File.AppendAllText(LogPath, $"\n{op} failed rc={rc}: {msg}");
    }

    // ── Startup ───────────────────────────────────────────────────────────

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnDispatcherException;
        try
        {
            File.AppendAllText(LogPath, "\nstep: SetDllImportResolver");
            NativeLibrary.SetDllImportResolver(typeof(NativeMethods).Assembly, (name, _, _) =>
            {
                var path = Path.Combine(AppContext.BaseDirectory, name + ".dll");
                return NativeLibrary.TryLoad(path, out var handle) ? handle : IntPtr.Zero;
            });

            File.AppendAllText(LogPath, "\nstep: howl_init");
            CheckOrThrow(NativeMethods.howl_init(), "howl_init");

            File.AppendAllText(LogPath, "\nstep: settings");
            _settings = AppSettings.Load();
            // Non-fatal: configure may fail if no API key is set yet (first run).
            // The user must open Settings and save; ApplySettings() will retry.
            int cfgRc = NativeMethods.howl_configure(_settings.ToConfigJson());
            if (cfgRc != 0)
            {
                var cfgErr = NativeMethods.MarshalAndFree(NativeMethods.howl_last_error()) ?? "configure failed";
                File.AppendAllText(LogPath, $"\nhowl_configure rc={cfgRc}: {cfgErr} (will retry after settings saved)");
                _needsConfigure = true;
            }

            File.AppendAllText(LogPath, "\nstep: overlay");
            _overlay = new RecordingOverlay();

            File.AppendAllText(LogPath, "\nstep: TrayManager");
            _tray = new TrayManager(openSettings: OpenSettings, quit: Quit);

            if (_needsConfigure)
                _tray.ShowInfo("Howl needs configuration — open Settings to add your API key.");

            File.AppendAllText(LogPath, "\nstep: HotkeyManager");
            _hotkey = new HotkeyManager();
            _hotkey.Pressed   += OnHotkeyPressed;
            _hotkey.Released  += OnHotkeyReleased;
            _hotkey.Cancelled += OnHotkeyCancelled;
            _hotkey.Failed    += OnHotkeyFailed;

            File.AppendAllText(LogPath, "\nstep: model check");
            _ = EnsureModelAsync();   // non-blocking; blocks dictation if model missing

            File.AppendAllText(LogPath, "\nstep: EnginePoller");
            _poller = new EnginePoller();
            _poller.Chunk   += OnChunk;
            _poller.Result  += OnResult;
            _poller.Level   += OnLevel;
            _poller.Warning += (_, msg) => File.AppendAllText(LogPath, $"\nwarn: {msg}");
            _poller.Error   += (_, msg) =>
            {
                File.AppendAllText(LogPath, $"\nerror: {msg}");
                Dispatcher.Invoke(() =>
                {
                    _overlay?.HideOverlay();
                    _tray?.ShowError(msg);
                });
            };
            _poller.Start();

            File.AppendAllText(LogPath, "\nstep: all done");
        }
        catch (Exception ex)
        {
            File.WriteAllText(LogPath, ex.ToString());
            MessageBox.Show(ex.Message, "Howl — startup error", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    // ── First-run model check ─────────────────────────────────────────────

    private async Task EnsureModelAsync()
    {
        if (File.Exists(_settings.WhisperModelPath)) return;

        var result = MessageBox.Show(
            $"Howl needs the Whisper model to transcribe speech.\n\n" +
            $"Download ggml-base.en.bin (~142 MB) now?\n\n" +
            $"Destination: {_settings.WhisperModelPath}",
            "Howl — model not found",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question);

        if (result != MessageBoxResult.Yes) return;

        _tray?.ShowInfo("Downloading Whisper model…");
        try
        {
            await ModelDownloader.DownloadAsync(
                "base",
                _settings.WhisperModelPath,
                progress => _tray?.SetTooltip($"Downloading model… {progress * 100:0}%"));

            // Re-configure so the engine picks up the now-present model
            CheckOrThrow(NativeMethods.howl_configure(_settings.ToConfigJson()), "howl_configure");
            _tray?.ShowInfo("Model downloaded. Howl is ready.");
            _tray?.SetTooltip("Howl — press Ctrl+Shift+Space to dictate");
        }
        catch (Exception ex)
        {
            File.AppendAllText(LogPath, $"\nmodel download failed: {ex}");
            _tray?.ShowError("Model download failed — open Settings to set the model path manually.");
        }
    }

    // ── Hotkey handlers ──────────────────────────────────────────────────

    private void OnHotkeyFailed(object? sender, string message)
    {
        File.AppendAllText(LogPath, $"\nhotkey registration failed: {message}");
        _tray?.ShowError($"Hotkey registration failed: {message}");
    }

    private void OnHotkeyPressed(object? sender, EventArgs e)
    {
        if (_isCapturing) return;
        if (_needsConfigure)
        {
            _tray?.ShowError("Howl is not configured. Open Settings to add your API key.");
            return;
        }
        if (!File.Exists(_settings.WhisperModelPath))
        {
            _tray?.ShowError("Whisper model not found. Open Settings to download or locate the model.");
            return;
        }

        _isCapturing    = true;
        _chunksReceived = false;

        CheckOrLog(NativeMethods.howl_start_capture(), "howl_start_capture");
        _capture = new AudioCapture(_settings.InputDeviceId);
        _capture.Start();

        SoundCue.PlayStart();
        _overlay?.SetRecording();
    }

    private void OnHotkeyReleased(object? sender, EventArgs e)
    {
        if (!_isCapturing) return;
        StopCapture();
        _overlay?.SetProcessing();
    }

    private void OnHotkeyCancelled(object? sender, EventArgs e)
    {
        if (!_isCapturing) return;
        StopCapture(cancel: true);
        _overlay?.HideOverlay();
    }

    private void StopCapture(bool cancel = false)
    {
        _capture?.Stop();
        _capture?.Dispose();
        _capture     = null;
        _isCapturing = false;

        if (cancel)
            CheckOrLog(NativeMethods.howl_cancel_capture(), "howl_cancel_capture");
        else
            CheckOrLog(NativeMethods.howl_stop_capture(), "howl_stop_capture");
    }

    // ── Engine event handlers ────────────────────────────────────────────

    private void OnChunk(object? sender, string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        _chunksReceived = true;
        TextInjector.InjectStreaming(text);
    }

    private async void OnResult(object? sender, string text)
    {
        _overlay?.HideOverlay();
        SoundCue.PlayDone();

        if (!_chunksReceived && !string.IsNullOrWhiteSpace(text))
            await TextInjector.InjectClipboardAsync(text);

        _chunksReceived = false;
    }

    private void OnLevel(object? sender, float rms) => _overlay?.UpdateLevel(rms);

    // ── Settings ─────────────────────────────────────────────────────────

    private void OpenSettings()
    {
        var win = new SettingsWindow(_settings, onSave: ApplySettings);
        win.ShowDialog();
    }

    private void ApplySettings(AppSettings settings)
    {
        _settings = settings;
        var rc = NativeMethods.howl_configure(_settings.ToConfigJson());
        if (rc == 0)
            _needsConfigure = false;
        else
            CheckOrLog(rc, "howl_configure (settings change)");
    }

    // ── Shutdown ─────────────────────────────────────────────────────────

    private void Quit()
    {
        _poller?.Stop();
        _poller?.Dispose();
        _poller = null;
        StopCapture(cancel: true);
        _hotkey?.Dispose();
        _hotkey = null;
        _tray?.Dispose();
        _tray = null;
        _overlay?.Close();
        _overlay = null;
        NativeMethods.howl_destroy();
        Shutdown();
    }

    private void OnDispatcherException(object sender, DispatcherUnhandledExceptionEventArgs ex)
    {
        File.WriteAllText(LogPath, ex.Exception.ToString());
        ex.Handled = true;
        Shutdown(1);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _hotkey?.Dispose();
        _tray?.Dispose();
        base.OnExit(e);
    }
}
