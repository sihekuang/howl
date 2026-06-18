using System.IO;
using System.Runtime.InteropServices;
using System.Windows;

namespace Howl;

public static class Program
{
    private static readonly string LogPath =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Desktop), "howl-crash.txt");

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetDllDirectory(string lpPathName);

    [STAThread]
    public static void Main()
    {
        File.WriteAllText(LogPath, "Main() started");
        try
        {
            SetDllDirectory(AppContext.BaseDirectory);
            File.WriteAllText(LogPath, "SetDllDirectory done, starting WPF");

            var app = new App();
            File.WriteAllText(LogPath, "App created, calling InitializeComponent");
            app.InitializeComponent();
            File.WriteAllText(LogPath, "InitializeComponent done, calling Run");
            app.Run();
            File.WriteAllText(LogPath, "Run() returned normally");
        }
        catch (Exception ex)
        {
            File.WriteAllText(LogPath, "EXCEPTION:\n" + ex);
            MessageBox.Show(ex.ToString(), "Howl crash", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }
}
