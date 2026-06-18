using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Threading;
using Howl.Native;

namespace Howl.Engine;

internal sealed class EnginePoller : IDisposable
{
    private readonly DispatcherTimer _timer;

    internal event EventHandler<string>? Result;
    internal event EventHandler<string>? Chunk;
    internal event EventHandler<float>?  Level;
    internal event EventHandler<string>? Warning;
    internal event EventHandler<string>? Error;

    internal EnginePoller()
    {
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(30) };
        _timer.Tick += Poll;
    }

    internal void Start() => _timer.Start();
    internal void Stop()  => _timer.Stop();

    private void Poll(object? sender, EventArgs e)
    {
        while (true)
        {
            var json = NativeMethods.MarshalAndFree(NativeMethods.howl_poll_event());
            if (json is null) break;

            var ev = JsonSerializer.Deserialize<EngineEvent>(json);
            if (ev is null) continue;

            switch (ev.Kind)
            {
                case "result":  Result?.Invoke(this, ev.Text ?? "");  break;
                case "chunk":   Chunk?.Invoke(this, ev.Text ?? "");   break;
                case "level":   Level?.Invoke(this, ev.Rms);          break;
                case "warning": Warning?.Invoke(this, ev.Msg ?? "");  break;
                case "error":   Error?.Invoke(this, ev.Msg ?? "");    break;
            }
        }
    }

    public void Dispose() => _timer.Stop();

    private sealed record EngineEvent(
        [property: JsonPropertyName("kind")] string Kind,
        [property: JsonPropertyName("text")] string? Text,
        [property: JsonPropertyName("msg")]  string? Msg,
        [property: JsonPropertyName("rms")]  float Rms
    );
}
