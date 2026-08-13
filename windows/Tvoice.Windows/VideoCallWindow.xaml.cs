using System.ComponentModel;
using System.IO;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Tvoice.Windows.Models;

namespace Tvoice.Windows;

public partial class VideoCallWindow : System.Windows.Window
{
    private readonly VideoCallCredentials _credentials;
    private bool _remoteClose;

    public VideoCallWindow(VideoCallCredentials credentials)
    {
        _credentials = credentials;
        InitializeComponent();
        Title = $"Видеозвонок — {credentials.Peer.DisplayName}";
        Loaded += OnLoaded;
    }

    public event EventHandler? HangupRequested;
    public string CallId => _credentials.CallId;

    public void CloseFromRemote()
    {
        _remoteClose = true;
        Close();
    }

    private async void OnLoaded(object sender, System.Windows.RoutedEventArgs e)
    {
        try
        {
            await VideoWebView.EnsureCoreWebView2Async();
            VideoWebView.CoreWebView2.PermissionRequested += (_, permission) =>
            {
                if (permission.PermissionKind is CoreWebView2PermissionKind.Camera or CoreWebView2PermissionKind.Microphone)
                    permission.State = CoreWebView2PermissionState.Allow;
            };
            VideoWebView.CoreWebView2.WebMessageReceived += (_, message) =>
            {
                try
                {
                    using var document = JsonDocument.Parse(message.WebMessageAsJson);
                    var type = document.RootElement.GetProperty("type").GetString();
                    if (type is "hangup" or "disconnected") HangupRequested?.Invoke(this, EventArgs.Empty);
                }
                catch { }
            };
            var webFolder = Path.Combine(AppContext.BaseDirectory, "Web");
            VideoWebView.CoreWebView2.SetVirtualHostNameToFolderMapping(
                "app.tvoice.local", webFolder, CoreWebView2HostResourceAccessKind.DenyCors);
            VideoWebView.NavigationCompleted += StartRoom;
            VideoWebView.Source = new Uri("https://app.tvoice.local/video.html");
        }
        catch (Exception exception)
        {
            System.Windows.MessageBox.Show(this, $"Не удалось запустить видеозвонок: {exception.Message}", "Tvoice",
                System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Error);
            HangupRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private async void StartRoom(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        VideoWebView.NavigationCompleted -= StartRoom;
        if (!e.IsSuccess)
        {
            HangupRequested?.Invoke(this, EventArgs.Empty);
            return;
        }
        var config = JsonSerializer.Serialize(new
        {
            url = _credentials.Url,
            token = _credentials.Token,
            peer = string.IsNullOrWhiteSpace(_credentials.Peer.DisplayName)
                ? _credentials.Peer.SipNumber
                : _credentials.Peer.DisplayName,
        });
        await VideoWebView.ExecuteScriptAsync($"window.tvoiceStart({config})");
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_remoteClose) HangupRequested?.Invoke(this, EventArgs.Empty);
        VideoWebView.Dispose();
        base.OnClosing(e);
    }
}
