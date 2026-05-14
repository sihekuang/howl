using System.Windows;
using Howl.Native;

namespace Howl;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        int rc = NativeMethods.howl_init();
        if (rc != 0)
        {
            StatusText.Text = $"howl_init failed (rc={rc})";
            return;
        }
        string? version = NativeMethods.MarshalAndFree(NativeMethods.howl_abi_version());
        StatusText.Text = $"libhowl ABI {version} — engine ready";
    }
}
