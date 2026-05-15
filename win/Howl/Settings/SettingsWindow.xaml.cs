using System.IO;
using System.Windows;
using Howl.Audio;
using Howl.Native;
using Microsoft.Win32;

namespace Howl.Settings;

public partial class SettingsWindow : Window
{
    private readonly AppSettings _settings;
    private readonly Action<AppSettings> _onSave;

    private static readonly (string Id, string Label)[] Languages =
    [
        ("en",   "English"),
        ("auto", "Auto-detect"),
        ("es",   "Spanish"),
        ("fr",   "French"),
        ("de",   "German"),
        ("it",   "Italian"),
        ("pt",   "Portuguese"),
        ("ja",   "Japanese"),
        ("ko",   "Korean"),
        ("zh",   "Chinese"),
    ];

    private static readonly (string Id, string Label, string Hint)[] Providers =
    [
        ("anthropic", "Anthropic — cloud",  "sk-ant-…"),
        ("openai",    "OpenAI — cloud",     "sk-…"),
        ("ollama",    "Ollama — local",     "no key needed"),
        ("lmstudio",  "LM Studio — local",  "no key needed"),
    ];

    private IReadOnlyList<(string Id, string Name)> _devices = [];
    private List<(string Name, string Description)> _presets = [];

    public SettingsWindow(AppSettings settings, Action<AppSettings> onSave)
    {
        _settings = settings;
        _onSave   = onSave;
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        PopulateGeneral();
        PopulateLlm();
        PopulateDict();
        PopulatePresets();
    }

    // ── General tab ───────────────────────────────────────────────────────

    private void PopulateGeneral()
    {
        ModelPathBox.Text = _settings.WhisperModelPath;
        UpdateModelStatus();

        LanguageBox.ItemsSource    = Languages.Select(l => l.Label).ToArray();
        LanguageBox.SelectedIndex  = Math.Max(0, Array.FindIndex(Languages, l => l.Id == _settings.Language));

        _devices = AudioCapture.ListInputDevices();
        MicBox.ItemsSource    = _devices.Select(d => d.Name).ToArray();
        MicBox.SelectedIndex  = Math.Max(0, _devices.ToList().FindIndex(d => d.Id == _settings.InputDeviceId));

        TimeoutBox.Text         = _settings.PipelineTimeout.ToString();
        LaunchAtLoginBox.IsChecked = _settings.LaunchAtLogin;
    }

    private void UpdateModelStatus()
    {
        var path = ModelPathBox.Text.Trim();
        ModelStatusText.Text = File.Exists(path)
            ? $"✓ Found ({new FileInfo(path).Length / 1_048_576} MB)"
            : "⚠ File not found — click Download to fetch it automatically.";
    }

    private void BrowseModel_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Title            = "Select Whisper model file",
            Filter           = "GGML model (*.bin)|*.bin|All files (*.*)|*.*",
            InitialDirectory = Path.GetDirectoryName(ModelPathBox.Text) ?? "",
        };
        if (dlg.ShowDialog(this) == true)
        {
            ModelPathBox.Text = dlg.FileName;
            UpdateModelStatus();
        }
    }

    private async void DownloadModel_Click(object sender, RoutedEventArgs e)
    {
        var destPath = ModelPathBox.Text.Trim();
        if (string.IsNullOrEmpty(destPath)) destPath = AppSettings.DefaultModelPath;

        ModelStatusText.Text = "Downloading… 0%";
        IsEnabled = false;

        try
        {
            await ModelDownloader.DownloadAsync("base", destPath,
                p => Dispatcher.Invoke(() => ModelStatusText.Text = $"Downloading… {p * 100:0}%"));

            ModelPathBox.Text = destPath;
            UpdateModelStatus();
        }
        catch (Exception ex)
        {
            ModelStatusText.Text = $"Download failed: {ex.Message}";
        }
        finally
        {
            IsEnabled = true;
        }
    }

    // ── LLM tab ───────────────────────────────────────────────────────────

    private void PopulateLlm()
    {
        ProviderBox.ItemsSource   = Providers.Select(p => p.Label).ToArray();
        ProviderBox.SelectedIndex = Math.Max(0, Array.FindIndex(Providers, p => p.Id == _settings.LlmProvider));
        ApiKeyBox.Password        = _settings.LlmApiKey;
        UpdateApiKeyVisibility();
    }

    private void Provider_Changed(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
        => UpdateApiKeyVisibility();

    private void UpdateApiKeyVisibility()
    {
        int idx     = ProviderBox.SelectedIndex;
        bool needs  = idx == 0 || idx == 1;
        ApiKeyRow.Visibility  = needs ? Visibility.Visible : Visibility.Collapsed;
        ApiKeyHint.Visibility = needs ? Visibility.Visible : Visibility.Collapsed;
        if (needs && idx < Providers.Length)
            ApiKeyHint.Text = $"Format: {Providers[idx].Hint}";
    }

    // ── Dictionary tab ────────────────────────────────────────────────────

    private void PopulateDict()
    {
        DictBox.Text = string.Join(Environment.NewLine, _settings.CustomDict);
    }

    // ── Presets tab ───────────────────────────────────────────────────────

    private void PopulatePresets()
    {
        try
        {
            var json = NativeMethods.MarshalAndFree(NativeMethods.howl_list_presets());
            if (!string.IsNullOrEmpty(json))
            {
                var list = System.Text.Json.JsonSerializer.Deserialize<List<PresetEntry>>(json);
                if (list != null)
                {
                    _presets = list.Select(p => (p.Name ?? "", p.Description ?? "")).ToList();
                }
            }
        }
        catch { }

        PresetBox.ItemsSource  = _presets.Count > 0
            ? _presets.Select(p => p.Name).ToArray()
            : new[] { "(no presets available)" };

        int idx = _presets.FindIndex(p => p.Name == _settings.SelectedPreset);
        PresetBox.SelectedIndex = Math.Max(0, idx);
        PresetBox.SelectionChanged += (_, _) => UpdatePresetDesc();
        UpdatePresetDesc();
    }

    private void UpdatePresetDesc()
    {
        int idx = PresetBox.SelectedIndex;
        PresetDescText.Text = (idx >= 0 && idx < _presets.Count)
            ? _presets[idx].Description
            : "";
    }

    private sealed record PresetEntry(
        [property: System.Text.Json.Serialization.JsonPropertyName("name")]        string? Name,
        [property: System.Text.Json.Serialization.JsonPropertyName("description")] string? Description
    );

    // ── Save / Cancel ─────────────────────────────────────────────────────

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        _settings.WhisperModelPath = ModelPathBox.Text.Trim();
        _settings.Language         = Languages[Math.Max(0, LanguageBox.SelectedIndex)].Id;

        int micIdx = MicBox.SelectedIndex;
        _settings.InputDeviceId = (micIdx >= 0 && micIdx < _devices.Count)
            ? _devices[micIdx].Id
            : "";

        _settings.LlmProvider   = Providers[Math.Max(0, ProviderBox.SelectedIndex)].Id;
        _settings.LlmApiKey     = ApiKeyBox.Password;
        _settings.LaunchAtLogin = LaunchAtLoginBox.IsChecked == true;

        if (int.TryParse(TimeoutBox.Text, out int t) && t >= 0)
            _settings.PipelineTimeout = t;

        _settings.CustomDict = DictBox.Text
            .Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .ToList();

        int presetIdx = PresetBox.SelectedIndex;
        _settings.SelectedPreset = (presetIdx >= 0 && presetIdx < _presets.Count)
            ? _presets[presetIdx].Name
            : "";

        _settings.Save();
        _onSave(_settings);
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => Close();
}
