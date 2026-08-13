using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.WebSockets;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Diagnostics;
using Tvoice.Windows.Models;

namespace Tvoice.Windows.Services;

public sealed class TvoiceApiClient : IAsyncDisposable
{
    private static readonly Uri DefaultBaseUri = new("https://chat.185-177-2-115.sslip.io/");
    private readonly HttpClient _httpClient;
    private readonly JsonSerializerOptions _json = new(JsonSerializerDefaults.Web);
    private ClientWebSocket? _socket;
    private CancellationTokenSource? _socketLifetime;
    private readonly SemaphoreSlim _reconnectLock = new(1, 1);
    private string _accessToken = string.Empty;

    public TvoiceApiClient(Uri? baseUri = null)
    {
        _httpClient = new HttpClient
        {
            BaseAddress = baseUri ?? DefaultBaseUri,
            Timeout = TimeSpan.FromSeconds(25),
        };
    }

    public event EventHandler<ChatRealtimeEvent>? RealtimeEvent;
    public event EventHandler<string>? ConnectionStateChanged;

    public async Task<LoginResponse> LoginAsync(
        string sipNumber,
        string password,
        CancellationToken cancellationToken = default)
    {
        using var response = await _httpClient.PostAsJsonAsync(
            "v1/auth/login",
            new { sipNumber = sipNumber.Trim(), password },
            _json,
            cancellationToken);
        var result = await ReadAsync<LoginResponse>(response, cancellationToken);
        _accessToken = result.AccessToken;
        _httpClient.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", result.AccessToken);
        return result;
    }

    public Task<ContactsResponse> GetContactsAsync(CancellationToken cancellationToken = default) =>
        GetAsync<ContactsResponse>("v1/contacts", cancellationToken);

    public Task<ConversationsResponse> GetConversationsAsync(CancellationToken cancellationToken = default) =>
        GetAsync<ConversationsResponse>("v1/conversations", cancellationToken);

    public async Task<Conversation> OpenDirectConversationAsync(
        string peerSipNumber,
        CancellationToken cancellationToken = default)
    {
        using var response = await _httpClient.PostAsJsonAsync(
            "v1/conversations/direct",
            new { peerSipNumber },
            _json,
            cancellationToken);
        return (await ReadAsync<DirectConversationResponse>(response, cancellationToken)).Conversation;
    }

    public Task<MessagesResponse> GetMessagesAsync(
        string conversationId,
        CancellationToken cancellationToken = default) =>
        GetAsync<MessagesResponse>(
            $"v1/conversations/{Uri.EscapeDataString(conversationId)}/messages?limit=100",
            cancellationToken);

    public async Task<ChatMessage> SendMessageAsync(
        string conversationId,
        string body,
        CancellationToken cancellationToken = default)
    {
        using var response = await _httpClient.PostAsJsonAsync(
            $"v1/conversations/{Uri.EscapeDataString(conversationId)}/messages",
            new { body },
            _json,
            cancellationToken);
        return (await ReadAsync<SendMessageResponse>(response, cancellationToken)).Message;
    }

    public async Task<ChatMessage> UploadAttachmentAsync(
        string conversationId,
        string filePath,
        CancellationToken cancellationToken = default)
    {
        var info = new FileInfo(filePath);
        if (!info.Exists) throw new FileNotFoundException("Файл не найден.", filePath);
        if (info.Length > 20 * 1024 * 1024) throw new InvalidOperationException("Файл больше 20 МБ.");
        await using var stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read,
            81920, FileOptions.Asynchronous | FileOptions.SequentialScan);
        using var content = new MultipartFormDataContent();
        using var fileContent = new StreamContent(stream);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        content.Add(fileContent, "file", info.Name.Replace('"', '_'));
        using var response = await _httpClient.PostAsync(
            $"v1/conversations/{Uri.EscapeDataString(conversationId)}/attachments",
            content,
            cancellationToken);
        return (await ReadAsync<SendMessageResponse>(response, cancellationToken)).Message;
    }

    public async Task<string> DownloadAttachmentAsync(
        ChatAttachment attachment,
        CancellationToken cancellationToken = default)
    {
        using var response = await _httpClient.GetAsync(
            $"v1/attachments/{Uri.EscapeDataString(attachment.Id)}",
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken);
        await EnsureSuccessAsync(response, cancellationToken);
        var safeName = string.Concat(attachment.Name.Select(character =>
            Path.GetInvalidFileNameChars().Contains(character) ? '_' : character));
        if (string.IsNullOrWhiteSpace(safeName)) safeName = "attachment";
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Tvoice", "Attachments");
        Directory.CreateDirectory(directory);
        var target = Path.Combine(directory, $"{attachment.Id}_{safeName}");
        await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
        await using var destination = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None,
            81920, FileOptions.Asynchronous);
        await source.CopyToAsync(destination, cancellationToken);
        return target;
    }

    public async Task MarkReadAsync(
        string conversationId,
        CancellationToken cancellationToken = default)
    {
        using var response = await _httpClient.PostAsync(
            $"v1/conversations/{Uri.EscapeDataString(conversationId)}/read",
            content: null,
            cancellationToken);
        await EnsureSuccessAsync(response, cancellationToken);
    }

    public async Task<VideoCallCredentials> StartVideoCallAsync(
        string peerSipNumber,
        CancellationToken cancellationToken = default)
    {
        using var response = await _httpClient.PostAsJsonAsync(
            "v1/video/calls", new { peerSipNumber }, _json, cancellationToken);
        var result = await ReadAsync<VideoCallCredentials>(response, cancellationToken);
        if (result.Delivered == false)
            throw new InvalidOperationException("Абонент сейчас не подключён к видеозвонкам.");
        return result;
    }

    public async Task<VideoCallCredentials> AnswerVideoCallAsync(
        string callId,
        CancellationToken cancellationToken = default)
    {
        using var response = await _httpClient.PostAsJsonAsync(
            $"v1/video/calls/{Uri.EscapeDataString(callId)}/answer", new { }, _json, cancellationToken);
        return await ReadAsync<VideoCallCredentials>(response, cancellationToken);
    }

    public Task RejectVideoCallAsync(string callId, CancellationToken cancellationToken = default) =>
        FinishVideoCallAsync(callId, "reject", cancellationToken);

    public Task EndVideoCallAsync(string callId, CancellationToken cancellationToken = default) =>
        FinishVideoCallAsync(callId, "end", cancellationToken);

    public async Task ConnectRealtimeAsync(CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(_accessToken))
            throw new InvalidOperationException("Login is required before WebSocket connection.");

        await StopRealtimeAsync();
        _socketLifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _socket = new ClientWebSocket();
        var socketUri = new UriBuilder(_httpClient.BaseAddress!)
        {
            Scheme = _httpClient.BaseAddress!.Scheme == "https" ? "wss" : "ws",
            Path = "/v1/ws",
            Query = $"token={Uri.EscapeDataString(_accessToken)}",
        }.Uri;

        try
        {
            await _socket.ConnectAsync(socketUri, _socketLifetime.Token);
            ConnectionStateChanged?.Invoke(this, "Чат подключён");
            _ = ReceiveLoopAsync(_socket, _socketLifetime.Token);
        }
        catch (Exception exception) when (!_socketLifetime.IsCancellationRequested)
        {
            _socket.Dispose();
            _socket = null;
            ConnectionStateChanged?.Invoke(this, $"Чат: повторное подключение — {exception.Message}");
            _ = ReconnectLoopAsync(_socketLifetime.Token);
        }
    }

    public async Task StopRealtimeAsync()
    {
        var socket = _socket;
        _socket = null;
        _socketLifetime?.Cancel();
        _socketLifetime?.Dispose();
        _socketLifetime = null;
        if (socket is null) return;
        if (socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
        {
            try
            {
                await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "logout", CancellationToken.None);
            }
            catch
            {
                // Connection may already be gone.
            }
        }
        socket.Dispose();
    }

    public async Task LogoutAsync()
    {
        await StopRealtimeAsync();
        _accessToken = string.Empty;
        _httpClient.DefaultRequestHeaders.Authorization = null;
    }

    public async ValueTask DisposeAsync()
    {
        await LogoutAsync();
        _httpClient.Dispose();
    }

    private async Task<T> GetAsync<T>(string path, CancellationToken cancellationToken)
    {
        using var response = await _httpClient.GetAsync(path, cancellationToken);
        return await ReadAsync<T>(response, cancellationToken);
    }

    private async Task FinishVideoCallAsync(string callId, string action, CancellationToken cancellationToken)
    {
        using var response = await _httpClient.PostAsync(
            $"v1/video/calls/{Uri.EscapeDataString(callId)}/{action}", null, cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound) return;
        await EnsureSuccessAsync(response, cancellationToken);
    }

    private async Task<T> ReadAsync<T>(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        await EnsureSuccessAsync(response, cancellationToken);
        return await response.Content.ReadFromJsonAsync<T>(_json, cancellationToken)
            ?? throw new InvalidOperationException("Сервер вернул пустой ответ.");
    }

    private static async Task EnsureSuccessAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        if (response.IsSuccessStatusCode) return;
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        var message = response.StatusCode switch
        {
            HttpStatusCode.Unauthorized => "Неверный номер или пароль.",
            HttpStatusCode.ServiceUnavailable => "Сервер авторизации временно недоступен.",
            HttpStatusCode.NotFound => "Запрошенные данные не найдены.",
            _ => $"Ошибка сервера {(int)response.StatusCode}: {body}",
        };
        throw new HttpRequestException(message, null, response.StatusCode);
    }

    private async Task ReceiveLoopAsync(ClientWebSocket socket, CancellationToken cancellationToken)
    {
        var buffer = new byte[32 * 1024];
        var message = new MemoryStream();
        try
        {
            while (socket.State == WebSocketState.Open && !cancellationToken.IsCancellationRequested)
            {
                var result = await socket.ReceiveAsync(buffer, cancellationToken);
                if (result.MessageType == WebSocketMessageType.Close) break;
                if (result.MessageType != WebSocketMessageType.Text) continue;
                message.Write(buffer, 0, result.Count);
                if (!result.EndOfMessage) continue;

                var text = Encoding.UTF8.GetString(message.GetBuffer(), 0, checked((int)message.Length));
                message.SetLength(0);
                ParseRealtimeEvent(text);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            ConnectionStateChanged?.Invoke(this, $"Чат отключён: {exception.Message}");
        }
        finally
        {
            message.Dispose();
            if (!cancellationToken.IsCancellationRequested)
            {
                ConnectionStateChanged?.Invoke(this, "Чат отключён");
                _ = ReconnectLoopAsync(cancellationToken);
            }
        }
    }

    private async Task ReconnectLoopAsync(CancellationToken cancellationToken)
    {
        if (!await _reconnectLock.WaitAsync(0, cancellationToken)) return;
        try
        {
            var delay = TimeSpan.FromSeconds(2);
            while (!cancellationToken.IsCancellationRequested && !string.IsNullOrWhiteSpace(_accessToken))
            {
                try
                {
                    await Task.Delay(delay, cancellationToken);
                    var socket = new ClientWebSocket();
                    var socketUri = new UriBuilder(_httpClient.BaseAddress!)
                    {
                        Scheme = _httpClient.BaseAddress!.Scheme == "https" ? "wss" : "ws",
                        Path = "/v1/ws",
                        Query = $"token={Uri.EscapeDataString(_accessToken)}",
                    }.Uri;
                    await socket.ConnectAsync(socketUri, cancellationToken);
                    _socket?.Dispose();
                    _socket = socket;
                    ConnectionStateChanged?.Invoke(this, "Чат подключён");
                    delay = TimeSpan.FromSeconds(2);
                    await ReceiveLoopAsync(socket, cancellationToken);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
                catch (Exception exception)
                {
                    ConnectionStateChanged?.Invoke(this, $"Чат: повторное подключение — {exception.Message}");
                    delay = TimeSpan.FromSeconds(Math.Min(30, delay.TotalSeconds * 2));
                }
            }
        }
        finally { _reconnectLock.Release(); }
    }

    private void ParseRealtimeEvent(string text)
    {
        if (text == "pong") return;
        using var document = JsonDocument.Parse(text);
        var root = document.RootElement;
        if (!root.TryGetProperty("type", out var typeNode)) return;
        var type = typeNode.GetString() ?? string.Empty;
        ChatMessage? chatMessage = null;
        string? conversationId = null;
        DateTimeOffset? throughCreatedAt = null;
        string? callId = null;
        TvoiceUser? from = null;
        string? reason = null;
        DateTimeOffset? expiresAt = null;

        if (root.TryGetProperty("message", out var messageNode))
        {
            chatMessage = messageNode.Deserialize<ChatMessage>(_json);
            conversationId = chatMessage?.ConversationId;
        }
        if (root.TryGetProperty("conversationId", out var conversationNode))
            conversationId = conversationNode.GetString();
        if (root.TryGetProperty("throughCreatedAt", out var throughNode) &&
            DateTimeOffset.TryParse(throughNode.GetString(), out var parsed))
            throughCreatedAt = parsed;
        if (root.TryGetProperty("callId", out var callNode)) callId = callNode.GetString();
        if (root.TryGetProperty("from", out var fromNode)) from = fromNode.Deserialize<TvoiceUser>(_json);
        if (root.TryGetProperty("reason", out var reasonNode)) reason = reasonNode.GetString();
        if (root.TryGetProperty("expiresAt", out var expiresNode) &&
            DateTimeOffset.TryParse(expiresNode.GetString(), out var parsedExpiry))
            expiresAt = parsedExpiry;

        RealtimeEvent?.Invoke(
            this,
            new ChatRealtimeEvent(type, chatMessage, conversationId, throughCreatedAt, callId, from, reason, expiresAt));
    }
}
