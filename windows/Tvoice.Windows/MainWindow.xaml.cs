using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using Tvoice.Windows.ViewModels;

namespace Tvoice.Windows;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel = new();
    private readonly System.Windows.Forms.NotifyIcon _trayIcon;
    private bool _closing;
    private VideoCallWindow? _videoWindow;
    private bool _endingVideo;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = _viewModel;
        _viewModel.PropertyChanged += ViewModel_OnPropertyChanged;
        _viewModel.VideoSessionReady += ViewModel_OnVideoSessionReady;
        _viewModel.VideoCallClosed += ViewModel_OnVideoCallClosed;
        _trayIcon = new System.Windows.Forms.NotifyIcon
        {
            Text = "Tvoice",
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? System.Drawing.SystemIcons.Application,
            Visible = true,
            ContextMenuStrip = new System.Windows.Forms.ContextMenuStrip(),
        };
        _trayIcon.ContextMenuStrip.Items.Add("Открыть Tvoice", null, (_, _) => RestoreWindow());
        _trayIcon.ContextMenuStrip.Items.Add("Выход", null, (_, _) =>
        {
            _closing = true;
            Dispatcher.Invoke(Close);
        });
        _trayIcon.DoubleClick += (_, _) => RestoreWindow();
        StateChanged += (_, _) =>
        {
            if (WindowState == WindowState.Minimized) Hide();
        };
    }

    private void PasswordBox_OnPasswordChanged(object sender, RoutedEventArgs e)
    {
        if (sender is PasswordBox passwordBox) _viewModel.Password = passwordBox.Password;
    }

    protected override async void OnClosing(CancelEventArgs e)
    {
        _closing = true;
        _viewModel.PropertyChanged -= ViewModel_OnPropertyChanged;
        _viewModel.VideoSessionReady -= ViewModel_OnVideoSessionReady;
        _viewModel.VideoCallClosed -= ViewModel_OnVideoCallClosed;
        if (_videoWindow is not null)
        {
            _videoWindow.CloseFromRemote();
            _videoWindow = null;
        }
        _trayIcon.Visible = false;
        _trayIcon.Dispose();
        await _viewModel.DisposeAsync();
        base.OnClosing(e);
    }

    private void ViewModel_OnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        var voice = e.PropertyName == nameof(MainViewModel.IsIncomingCall) && _viewModel.IsIncomingCall;
        var video = e.PropertyName == nameof(MainViewModel.IsIncomingVideoVisible) && _viewModel.IsIncomingVideoVisible;
        if (!voice && !video) return;
        Dispatcher.Invoke(() =>
        {
            _trayIcon.BalloonTipTitle = video ? "Входящий видеозвонок Tvoice" : "Входящий звонок Tvoice";
            _trayIcon.BalloonTipText = video ? $"Звонит {_viewModel.IncomingVideoPeer}" : $"Звонит {_viewModel.CallPeer}";
            _trayIcon.ShowBalloonTip(5000);
            RestoreWindow();
        });
    }

    private void ViewModel_OnVideoSessionReady(object? sender, Models.VideoCallCredentials credentials)
    {
        Dispatcher.Invoke(() =>
        {
            if (_videoWindow is not null)
            {
                _videoWindow.CloseFromRemote();
                _videoWindow = null;
            }
            var window = new VideoCallWindow(credentials) { Owner = this };
            _videoWindow = window;
            window.HangupRequested += async (_, _) =>
            {
                if (_endingVideo) return;
                _endingVideo = true;
                try
                {
                    await _viewModel.EndVideoCallAsync(credentials.CallId);
                    if (_videoWindow == window)
                    {
                        window.CloseFromRemote();
                        _videoWindow = null;
                    }
                }
                finally { _endingVideo = false; }
            };
            window.Closed += (_, _) =>
            {
                if (_videoWindow == window) _videoWindow = null;
            };
            window.Show();
        });
    }

    private void ViewModel_OnVideoCallClosed(object? sender, string callId)
    {
        Dispatcher.Invoke(() =>
        {
            if (_videoWindow?.CallId != callId) return;
            _videoWindow.CloseFromRemote();
            _videoWindow = null;
        });
    }

    private void RestoreWindow()
    {
        if (_closing) return;
        Dispatcher.Invoke(() =>
        {
            Show();
            WindowState = WindowState.Normal;
            Activate();
            Topmost = true;
            Topmost = false;
            Focus();
        });
    }
}
