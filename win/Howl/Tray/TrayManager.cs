using System.Drawing;
using System.IO;
using System.Windows.Controls;
using H.NotifyIcon;
using H.NotifyIcon.Core;

namespace Howl.Tray;

internal sealed class TrayManager : IDisposable
{
    private readonly TaskbarIcon _icon;

    internal TrayManager(Action openSettings, Action quit)
    {
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "howl.ico");
        var icon = File.Exists(iconPath) ? new Icon(iconPath, 32, 32) : SystemIcons.Application;

        _icon = new TaskbarIcon
        {
            ToolTipText = "Howl — press Ctrl+Shift+Space to dictate",
            Icon = icon,
            ContextMenu = BuildMenu(openSettings, quit),
        };
        _icon.ForceCreate();
        _icon.ShowNotification("Howl", "Howl is running — right-click this icon for options.");
    }

    internal void ShowError(string message) =>
        _icon.ShowNotification("Howl", message, NotificationIcon.Error);

    internal void ShowInfo(string message) =>
        _icon.ShowNotification("Howl", message, NotificationIcon.Info);

    internal void SetTooltip(string tip) =>
        _icon.ToolTipText = tip;

    private static ContextMenu BuildMenu(Action openSettings, Action quit)
    {
        var menu = new ContextMenu();

        var settingsItem = new MenuItem { Header = "Settings…" };
        settingsItem.Click += (_, _) => openSettings();
        menu.Items.Add(settingsItem);

        menu.Items.Add(new Separator());

        var quitItem = new MenuItem { Header = "Quit Howl" };
        quitItem.Click += (_, _) => quit();
        menu.Items.Add(quitItem);

        return menu;
    }

    public void Dispose() => _icon.Dispose();
}
