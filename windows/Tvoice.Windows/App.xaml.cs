using System.Windows;
using Tvoice.Windows.Services;

namespace Tvoice.Windows;

public partial class App : System.Windows.Application
{
    protected override async void OnStartup(StartupEventArgs e)
    {
        ThemeService.ApplySystemTheme(Resources);
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        base.OnStartup(e);

        var splash = new SplashWindow();
        splash.Show();
        await Task.Delay(TimeSpan.FromSeconds(2));

        var mainWindow = new MainWindow();
        MainWindow = mainWindow;
        mainWindow.Show();
        splash.Close();
        ShutdownMode = ShutdownMode.OnMainWindowClose;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Microsoft.Win32.SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        base.OnExit(e);
    }

    private void OnUserPreferenceChanged(object sender, Microsoft.Win32.UserPreferenceChangedEventArgs e) =>
        Dispatcher.Invoke(() => ThemeService.ApplySystemTheme(Resources));
}
