using System.Runtime.InteropServices;

namespace Howl.Native;

internal static class NativeMethods
{
    private const string Dll = "libhowl";

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int howl_init();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int howl_configure([MarshalAs(UnmanagedType.LPUTF8Str)] string json);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int howl_start_capture();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int howl_push_audio(float[] samples, int count);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int howl_stop_capture();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int howl_cancel_capture();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr howl_poll_event();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr howl_last_error();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void howl_free_string(IntPtr s);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void howl_destroy();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr howl_abi_version();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr howl_list_presets();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr howl_get_preset([MarshalAs(UnmanagedType.LPUTF8Str)] string name);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int howl_save_preset(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string description,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string body);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int howl_delete_preset([MarshalAs(UnmanagedType.LPUTF8Str)] string name);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr howl_list_sessions();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr howl_get_session([MarshalAs(UnmanagedType.LPUTF8Str)] string id);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int howl_delete_session([MarshalAs(UnmanagedType.LPUTF8Str)] string id);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int howl_clear_sessions();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int howl_enroll_compute(
        float[] samples, int count, int sampleRate,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string profileDir);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr howl_replay(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string sourceId,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string presetsCsv);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int howl_tse_extract_file(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string inputPath,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string outputPath,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string modelsDir,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string voiceDir,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string onnxLibPath);

    internal static string? MarshalAndFree(IntPtr ptr)
    {
        if (ptr == IntPtr.Zero) return null;
        string result = Marshal.PtrToStringUTF8(ptr) ?? string.Empty;
        howl_free_string(ptr);
        return result;
    }
}
