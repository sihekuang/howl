using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Howl.Native;

namespace Howl.Audio;

internal sealed class AudioCapture : IDisposable
{
    private readonly string? _deviceId;
    private WasapiCapture?          _capture;
    private BufferedWaveProvider?   _rawBuffer;
    private ISampleProvider?        _pipeline;

    internal AudioCapture(string? deviceId = null) => _deviceId = deviceId;

    internal void Start()
    {
        var enumerator = new MMDeviceEnumerator();
        MMDevice device;
        if (!string.IsNullOrEmpty(_deviceId))
        {
            try   { device = enumerator.GetDevice(_deviceId); }
            catch { device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia); }
        }
        else
        {
            device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia);
        }

        _capture = new WasapiCapture(device)
        {
            ShareMode = AudioClientShareMode.Shared,
        };

        _rawBuffer = new BufferedWaveProvider(_capture.WaveFormat)
        {
            DiscardOnBufferOverflow = true,
            BufferDuration = TimeSpan.FromSeconds(10),
        };

        // Build conversion pipeline: device format → float32 → mono → 48000 Hz
        ISampleProvider pipeline = _rawBuffer.ToSampleProvider();

        if (_capture.WaveFormat.Channels == 2)
            pipeline = new StereoToMonoSampleProvider(pipeline);
        else if (_capture.WaveFormat.Channels > 2)
            pipeline = new MultiChannelToMonoSampleProvider(pipeline, _capture.WaveFormat.Channels);

        if (_capture.WaveFormat.SampleRate != 48000)
            pipeline = new WdlResamplingSampleProvider(pipeline, 48000);

        _pipeline = pipeline;
        _capture.DataAvailable += OnData;
        _capture.StartRecording();
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        _rawBuffer!.AddSamples(e.Buffer, 0, e.BytesRecorded);

        var chunk = new float[4096];
        int read = _pipeline!.Read(chunk, 0, chunk.Length);
        if (read > 0)
            NativeMethods.howl_push_audio(chunk, read);
    }

    internal void Stop() => _capture?.StopRecording();

    public void Dispose()
    {
        _capture?.Dispose();
        _capture = null;
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    internal static IReadOnlyList<(string Id, string Name)> ListInputDevices()
    {
        var result = new List<(string, string)> { ("", "System default") };
        try
        {
            var enumerator = new MMDeviceEnumerator();
            foreach (var dev in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
                result.Add((dev.ID, dev.FriendlyName));
        }
        catch { /* return just the default entry */ }
        return result;
    }

    // Simple N-channel → mono: averages all channels per frame.
    private sealed class MultiChannelToMonoSampleProvider : ISampleProvider
    {
        private readonly ISampleProvider _source;
        private readonly int _channels;
        private float[] _interleaved = [];

        public WaveFormat WaveFormat { get; }

        internal MultiChannelToMonoSampleProvider(ISampleProvider source, int channels)
        {
            _source   = source;
            _channels = channels;
            WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);
        }

        public int Read(float[] buffer, int offset, int count)
        {
            int needed = count * _channels;
            if (_interleaved.Length < needed) _interleaved = new float[needed];
            int read = _source.Read(_interleaved, 0, needed);
            int frames = read / _channels;
            for (int i = 0; i < frames; i++)
            {
                float sum = 0;
                for (int c = 0; c < _channels; c++) sum += _interleaved[i * _channels + c];
                buffer[offset + i] = sum / _channels;
            }
            return frames;
        }
    }
}
