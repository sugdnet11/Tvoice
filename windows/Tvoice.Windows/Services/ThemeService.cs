using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace Tvoice.Windows.Services;

internal static class ThemeService
{
    public static void ApplySystemTheme(ResourceDictionary resources)
    {
        var useLight = true;
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            useLight = Convert.ToInt32(key?.GetValue("AppsUseLightTheme", 1)) != 0;
        }
        catch
        {
            // Windows theme lookup is best effort; light is the safe fallback.
        }

        Set(resources, "WindowBrush", useLight ? "#F7F7F5" : "#171717");
        Set(resources, "SurfaceBrush", useLight ? "#FFFFFFFF" : "#202020");
        Set(resources, "SurfaceAltBrush", useLight ? "#F1F1EF" : "#2C2C2C");
        Set(resources, "SidebarBrush", useLight ? "#FBFBFA" : "#1B1B1B");
        Set(resources, "AccentSoftBrush", useLight ? "#EAF4FF" : "#19334D");
        Set(resources, "SuccessSoftBrush", useLight ? "#EAF8EE" : "#193522");
        Set(resources, "DangerSoftBrush", useLight ? "#FFF0EF" : "#42211F");
        Set(resources, "TextBrush", useLight ? "#37352F" : "#F7F6F3");
        Set(resources, "MutedTextBrush", useLight ? "#787774" : "#A9A9A6");
        Set(resources, "SubtleTextBrush", useLight ? "#9B9A97" : "#7D7D79");
        Set(resources, "BorderBrush", useLight ? "#E6E6E3" : "#373737");
        Set(resources, "StrongBorderBrush", useLight ? "#D8D8D4" : "#4A4A4A");
    }

    private static void Set(ResourceDictionary resources, string key, string color) =>
        resources[key] = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(color));
}
