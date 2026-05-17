using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace Howl.Settings;

public sealed class AppSettings
{
    private static readonly string Dir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Howl");

    internal static readonly string DefaultModelPath =
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Howl", "models", "ggml-base.en.bin");

    private static readonly string SettingsPath = Path.Combine(Dir, "settings.json");
    private static readonly JsonSerializerOptions Opts = new() { WriteIndented = true };

    // ── Persisted fields ──────────────────────────────────────────────────

    [JsonPropertyName("whisper_model_path")] public string WhisperModelPath { get; set; } = DefaultModelPath;
    [JsonPropertyName("language")]           public string Language          { get; set; } = "en";
    [JsonPropertyName("llm_provider")]       public string LlmProvider       { get; set; } = "anthropic";
    [JsonPropertyName("llm_model")]          public string LlmModel          { get; set; } = "claude-sonnet-4-6";
    [JsonPropertyName("llm_key_dpapi")]      public string LlmKeyDpapi       { get; set; } = ""; // base64 DPAPI blob
    [JsonPropertyName("input_device_id")]    public string InputDeviceId     { get; set; } = "";
    [JsonPropertyName("custom_dict")]        public List<string> CustomDict   { get; set; } = [];
    [JsonPropertyName("launch_at_login")]    public bool LaunchAtLogin        { get; set; } = false;
    [JsonPropertyName("pipeline_timeout_sec")] public int PipelineTimeout    { get; set; } = 30;
    [JsonPropertyName("selected_preset")]    public string SelectedPreset     { get; set; } = "";

    // ── In-memory only (decrypted) ────────────────────────────────────────

    [JsonIgnore] public string LlmApiKey { get; set; } = "";

    // ── DPAPI helpers ─────────────────────────────────────────────────────

    internal void EncryptApiKey()
    {
        if (string.IsNullOrEmpty(LlmApiKey))
        {
            LlmKeyDpapi = "";
            return;
        }
        try
        {
            var bytes     = Encoding.UTF8.GetBytes(LlmApiKey);
            var encrypted = ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser);
            LlmKeyDpapi   = Convert.ToBase64String(encrypted);
        }
        catch
        {
            // Fall back to storing in plaintext if DPAPI fails (e.g., headless CI)
            LlmKeyDpapi = Convert.ToBase64String(Encoding.UTF8.GetBytes("plain:" + LlmApiKey));
        }
    }

    private void DecryptApiKey()
    {
        if (string.IsNullOrEmpty(LlmKeyDpapi)) return;
        try
        {
            var blob = Convert.FromBase64String(LlmKeyDpapi);
            var plain = Encoding.UTF8.GetString(blob);
            if (plain.StartsWith("plain:"))          // plaintext fallback
            {
                LlmApiKey = plain["plain:".Length..];
                return;
            }
            var decrypted = ProtectedData.Unprotect(blob, null, DataProtectionScope.CurrentUser);
            LlmApiKey = Encoding.UTF8.GetString(decrypted);
        }
        catch { /* key not decryptable on this machine — leave empty */ }
    }

    // ── Config JSON for howl_configure ───────────────────────────────────

    internal string ToConfigJson()
    {
        var obj = new Dictionary<string, object?>
        {
            ["whisper_model_path"]        = WhisperModelPath,
            ["language"]                  = Language,
            ["llm_provider"]              = LlmProvider,
            ["llm_api_key"]               = LlmApiKey,
            ["llm_model"]                 = LlmModel,
            ["custom_dict"]               = CustomDict,
            ["disable_noise_suppression"] = true,        // no DeepFilter on Windows yet
            ["pipeline_timeout_sec"]      = PipelineTimeout,
        };
        return JsonSerializer.Serialize(obj);
    }

    // ── Persistence ───────────────────────────────────────────────────────

    internal static AppSettings Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                var s = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath)) ?? new();
                s.DecryptApiKey();
                return s;
            }
        }
        catch { /* use defaults */ }
        return new();
    }

    internal void Save()
    {
        EncryptApiKey();
        Directory.CreateDirectory(Dir);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(this, Opts));
        ApplyLaunchAtLogin();
    }

    private void ApplyLaunchAtLogin()
    {
        const string key  = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
        const string name = "Howl";
        using var reg = Registry.CurrentUser.OpenSubKey(key, writable: true);
        if (reg is null) return;
        if (LaunchAtLogin)
        {
            var exe = Environment.ProcessPath ?? "";
            if (!string.IsNullOrEmpty(exe)) reg.SetValue(name, $"\"{exe}\"");
        }
        else
        {
            reg.DeleteValue(name, throwOnMissingValue: false);
        }
    }
}
