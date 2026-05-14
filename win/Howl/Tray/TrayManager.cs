using System.Drawing;
using System.Windows.Forms;

namespace Howl.Tray;

internal sealed class TrayManager : IDisposable
{
    private readonly NotifyIcon _icon;

    internal TrayManager(Action quit)
    {
        _icon = new NotifyIcon
        {
            Text = "Howl — press Ctrl+Shift+Space to dictate",
            Icon = SystemIcons.Application,
            Visible = true,
            ContextMenuStrip = BuildMenu(quit),
        };
    }

    private static ContextMenuStrip BuildMenu(Action quit)
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Quit Howl", image: null, onClick: (_, _) => quit());
        return menu;
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
