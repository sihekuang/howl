using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Howl.Overlay;

public partial class RecordingOverlay : Window
{
    private Storyboard? _spinnerStoryboard;

    public RecordingOverlay()
    {
        InitializeComponent();
        PositionAtTopCenter();
    }

    private void PositionAtTopCenter()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - Width) / 2;
        Top  = area.Top + 80;
    }

    internal void SetRecording()
    {
        _spinnerStoryboard?.Stop();
        Spinner.Visibility   = Visibility.Collapsed;
        RecordDot.Visibility = Visibility.Visible;
        LevelBar.Width       = 0;
        LevelBar.Visibility  = Visibility.Visible;
        StatusText.Text = "Recording";
        Show();
    }

    internal void SetProcessing()
    {
        RecordDot.Visibility = Visibility.Collapsed;
        LevelBar.Visibility  = Visibility.Collapsed;
        Spinner.Visibility   = Visibility.Visible;
        StatusText.Text = "Processing…";

        _spinnerStoryboard = new Storyboard();
        var spin = new DoubleAnimation(0, 360, new Duration(TimeSpan.FromSeconds(0.8)))
            { RepeatBehavior = RepeatBehavior.Forever };
        Storyboard.SetTarget(spin, SpinnerRotate);
        Storyboard.SetTargetProperty(spin, new PropertyPath(RotateTransform.AngleProperty));
        _spinnerStoryboard.Children.Add(spin);
        _spinnerStoryboard.Begin(this);
    }

    // rms: 0.0 – 1.0 from the Go core's level events
    internal void UpdateLevel(float rms)
    {
        if (LevelBar.Visibility != Visibility.Visible) return;
        // Map rms logarithmically to bar width (0 – 100 px)
        double db = rms > 0 ? 20 * Math.Log10(rms) : -60;
        double fraction = Math.Clamp((db + 60) / 60.0, 0, 1);
        LevelBar.Width = fraction * 100;
    }

    internal void HideOverlay()
    {
        _spinnerStoryboard?.Stop();
        Hide();
    }
}
