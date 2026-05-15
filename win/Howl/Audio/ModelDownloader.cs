using System.IO;
using System.Net.Http;

namespace Howl.Audio;

internal static class ModelDownloader
{
    private static readonly HttpClient Http = new();

    // size: "tiny", "base", "small", "medium", "large"
    internal static async Task DownloadAsync(
        string size,
        string destPath,
        Action<double>? onProgress = null)
    {
        var url = $"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{size}.en.bin";
        Directory.CreateDirectory(Path.GetDirectoryName(destPath)!);

        var tmp = destPath + ".tmp";
        try
        {
            using var response = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            response.EnsureSuccessStatusCode();

            var total = response.Content.Headers.ContentLength ?? -1L;
            await using var src  = await response.Content.ReadAsStreamAsync();
            await using var dest = File.Create(tmp);

            var buf = new byte[65536];
            long done = 0;
            int read;
            while ((read = await src.ReadAsync(buf)) > 0)
            {
                await dest.WriteAsync(buf.AsMemory(0, read));
                done += read;
                if (total > 0) onProgress?.Invoke((double)done / total);
            }
        }
        catch
        {
            // Clean up partial download before re-throwing
            try { File.Delete(tmp); } catch { }
            throw;
        }

        File.Move(tmp, destPath, overwrite: true);
    }
}
