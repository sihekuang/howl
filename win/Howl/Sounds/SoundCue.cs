using System.Runtime.InteropServices;

namespace Howl.Sounds;

internal static class SoundCue
{
    [DllImport("user32.dll")] private static extern bool MessageBeep(uint type);

    private const uint MbAsterisk    = 0x00000040; // soft notification — recording start
    private const uint MbExclamation = 0x00000030; // brighter tone — result ready

    internal static void PlayStart()  => MessageBeep(MbAsterisk);
    internal static void PlayDone()   => MessageBeep(MbExclamation);
}
