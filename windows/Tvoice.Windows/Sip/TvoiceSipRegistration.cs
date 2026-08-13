using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace Tvoice.Windows.Sip;

public enum SipRegistrationState
{
    None,
    Connecting,
    Connected,
    Failed,
    Disconnected,
}

public enum SipCallState
{
    Idle,
    Incoming,
    Calling,
    Ringing,
    Connected,
    Held,
    Ended,
    Failed,
}

public sealed record SipRegistrationChanged(SipRegistrationState State, string Message);
public sealed record SipCallChanged(
    SipCallState State,
    string PeerNumber,
    string Message,
    bool IsIncoming,
    bool IsMuted,
    bool IsHeld,
    DateTimeOffset? ConnectedAt);

public sealed class TvoiceSipRegistration : IAsyncDisposable
{
    private const string Domain = "185.177.2.115";
    private const int Port = 5060;
    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private readonly SemaphoreSlim _callLock = new(1, 1);
    private readonly object _stateLock = new();
    private UdpClient? _socket;
    private CancellationTokenSource? _lifetime;
    private Task? _receiveTask;
    private Task? _keepAliveTask;
    private IPEndPoint? _server;
    private IPAddress? _localAddress;
    private string _username = string.Empty;
    private string _password = string.Empty;
    private string _registrationCallId = string.Empty;
    private string _registrationTag = string.Empty;
    private int _registrationCseq;
    private int _pendingRegistrationCseq;
    private int _registrationAuthAttempts;
    private int _registrationNonceCount;
    private DigestChallenge? _registrationChallenge;
    private string _registrationAuthorizationHeader = "Authorization";
    private ViaMapping? _mappedContact;
    private volatile bool _registered;
    private SipDialog? _dialog;

    public event EventHandler<SipRegistrationChanged>? StateChanged;
    public event EventHandler<SipCallChanged>? CallChanged;

    public bool IsRegistered => _registered;
    public SipCallState CallState => _dialog?.State ?? SipCallState.Idle;

    public async Task RegisterAsync(string username, string password, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(username)) throw new ArgumentException("SIP number is required.", nameof(username));
        if (string.IsNullOrWhiteSpace(password)) throw new ArgumentException("SIP password is required.", nameof(password));
        await DisconnectAsync();

        var serverAddress = (await Dns.GetHostAddressesAsync(Domain, cancellationToken))
            .First(address => address.AddressFamily == AddressFamily.InterNetwork);
        _server = new IPEndPoint(serverAddress, Port);
        _localAddress = ResolveLocalAddress(_server);
        _socket = new UdpClient(new IPEndPoint(IPAddress.Any, 0));
        _socket.Connect(_server);
        _lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        lock (_stateLock)
        {
            _username = username.Trim();
            _password = password;
            _registrationCallId = $"{SipValues.RandomHex(12)}@{_localAddress}";
            _registrationTag = SipValues.RandomHex(8);
            _registrationCseq = 0;
            _pendingRegistrationCseq = 0;
            _registrationAuthAttempts = 0;
            _registrationNonceCount = 0;
            _registrationChallenge = null;
            _mappedContact = null;
            _registered = false;
        }

        PublishRegistration(SipRegistrationState.Connecting, $"SIP {Domain}: подключение…");
        _receiveTask = ReceiveLoopAsync(_socket, _lifetime.Token);
        _keepAliveTask = KeepAliveLoopAsync(_lifetime.Token);
        await SendRegisterAsync(300, _lifetime.Token);
    }

    public async Task CallAsync(string peerNumber, CancellationToken cancellationToken = default)
    {
        var peer = NormalizeNumber(peerNumber);
        if (!_registered) throw new InvalidOperationException("SIP ещё не подключён.");
        await _callLock.WaitAsync(cancellationToken);
        try
        {
            if (_dialog is not null) throw new InvalidOperationException("Другой звонок уже активен.");
            var dialog = new SipDialog
            {
                PeerNumber = peer,
                IsIncoming = false,
                State = SipCallState.Calling,
                CallId = $"{SipValues.RandomHex(12)}@{_localAddress}",
                LocalTag = SipValues.RandomHex(8),
                RequestUri = $"sip:{peer}@{Domain}",
                RemoteTarget = $"sip:{peer}@{Domain}",
                LocalCseq = 1,
                InviteBranch = SipValues.NewBranch(),
                Rtp = new RtpAudioSession(),
            };
            _dialog = dialog;
            PublishCall(dialog, SipCallState.Calling, $"Вызов {peer}…");
            await SendInviteAsync(dialog, false, cancellationToken);
            _ = OutgoingTimeoutAsync(dialog, _lifetime?.Token ?? cancellationToken);
        }
        finally
        {
            _callLock.Release();
        }
    }

    public async Task AcceptCallAsync(CancellationToken cancellationToken = default)
    {
        await _callLock.WaitAsync(cancellationToken);
        try
        {
            var dialog = _dialog;
            if (dialog is null || !dialog.IsIncoming || dialog.State != SipCallState.Incoming || dialog.IncomingInvite is null)
                return;
            dialog.Accepted = true;
            await SendResponseAsync(dialog.IncomingInvite, 200, "OK", dialog.LocalTag, LocalSdp(dialog, false), cancellationToken);
            PublishCall(dialog, SipCallState.Connected, "Соединение…");
        }
        finally
        {
            _callLock.Release();
        }
    }

    public async Task HangupAsync(CancellationToken cancellationToken = default)
    {
        await _callLock.WaitAsync(cancellationToken);
        try
        {
            var dialog = _dialog;
            if (dialog is null) return;
            if (dialog.IsIncoming && !dialog.Accepted && dialog.IncomingInvite is not null)
                await SendResponseAsync(dialog.IncomingInvite, 486, "Busy Here", dialog.LocalTag, string.Empty, cancellationToken);
            else if (!dialog.IsIncoming && dialog.State is SipCallState.Calling or SipCallState.Ringing)
                await SendCancelAsync(dialog, cancellationToken);
            else
                await SendByeAsync(dialog, cancellationToken);
            await FinishCallAsync(dialog, SipCallState.Ended, "Звонок завершён");
        }
        finally
        {
            _callLock.Release();
        }
    }

    public void SetMuted(bool muted)
    {
        var dialog = _dialog;
        if (dialog is null) return;
        dialog.Muted = muted;
        dialog.Rtp.SetMuted(muted);
        PublishCall(dialog, dialog.State, muted ? "Микрофон выключен" : "Микрофон включён");
    }

    public async Task SetHeldAsync(bool held, CancellationToken cancellationToken = default)
    {
        await _callLock.WaitAsync(cancellationToken);
        try
        {
            var dialog = _dialog;
            if (dialog is null || dialog.State is not (SipCallState.Connected or SipCallState.Held)) return;
            dialog.PendingHold = held;
            dialog.LocalCseq++;
            dialog.InviteBranch = SipValues.NewBranch();
            await SendInviteAsync(dialog, true, cancellationToken);
        }
        finally
        {
            _callLock.Release();
        }
    }

    public async Task SendDtmfAsync(char digit, CancellationToken cancellationToken = default)
    {
        var dialog = _dialog;
        if (dialog is null || dialog.State is not (SipCallState.Connected or SipCallState.Held)) return;
        if (dialog.RemoteMedia?.TelephoneEventPayload is not null)
        {
            await dialog.Rtp.SendDtmfAsync(digit, cancellationToken);
            return;
        }
        dialog.LocalCseq++;
        var body = $"Signal={digit}\r\nDuration=160\r\n";
        await SendDialogRequestAsync(dialog, "INFO", dialog.LocalCseq, SipValues.NewBranch(), body,
            "application/dtmf-relay", cancellationToken);
    }

    public async Task DisconnectAsync()
    {
        var dialog = _dialog;
        if (dialog is not null)
        {
            try { await HangupAsync(); } catch { }
        }
        var lifetime = _lifetime;
        var socket = _socket;
        if (socket is not null && _registered && lifetime is not null && !lifetime.IsCancellationRequested)
        {
            try { await SendRegisterAsync(0, CancellationToken.None); } catch { }
        }

        _registered = false;
        _socket = null;
        _lifetime = null;
        lifetime?.Cancel();
        socket?.Dispose();
        if (_receiveTask is not null)
            try { await _receiveTask; } catch { }
        if (_keepAliveTask is not null)
            try { await _keepAliveTask; } catch { }
        lifetime?.Dispose();
        _receiveTask = null;
        _keepAliveTask = null;
        if (!string.IsNullOrEmpty(_password)) _password = string.Empty;
        PublishRegistration(SipRegistrationState.Disconnected, "SIP отключён");
    }

    public async ValueTask DisposeAsync()
    {
        await DisconnectAsync();
        _sendLock.Dispose();
        _callLock.Dispose();
    }

    private async Task SendRegisterAsync(int expires, CancellationToken cancellationToken)
    {
        var socket = _socket ?? throw new InvalidOperationException("SIP socket is not open.");
        string request;
        int sentCseq;
        lock (_stateLock)
        {
            sentCseq = ++_registrationCseq;
            _pendingRegistrationCseq = sentCseq;
            var requestUri = $"sip:{Domain}:{Port}";
            var headers = BaseHeaders(SipValues.NewBranch(), _registrationTag, null, _registrationCallId, sentCseq, "REGISTER");
            headers.Add($"Contact: <{LocalContactUri()}>;ob;expires={expires}");
            headers.Add($"Expires: {expires}");
            headers.Add("Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE");
            headers.Add("Supported: path, gruu, outbound");
            if (_registrationChallenge is not null)
            {
                _registrationNonceCount++;
                headers.Add($"{_registrationAuthorizationHeader}: {DigestAuthorization.Create(_registrationChallenge, _username, _password, "REGISTER", requestUri, _registrationNonceCount)}");
            }
            request = BuildMessage($"REGISTER {requestUri} SIP/2.0", headers, string.Empty);
        }
        await SendTextAsync(request, cancellationToken);
        if (expires > 0) _ = RegistrationTimeoutAsync(sentCseq, cancellationToken);
    }

    private async Task RegistrationTimeoutAsync(int cseq, CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(12), cancellationToken);
            if (_pendingRegistrationCseq == cseq && !_registered)
                PublishRegistration(SipRegistrationState.Failed, "SIP-сервер не ответил");
        }
        catch (OperationCanceledException) { }
    }

    private async Task ReceiveLoopAsync(UdpClient socket, CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var result = await socket.ReceiveAsync(cancellationToken);
                if (_server is null || !result.RemoteEndPoint.Address.Equals(_server.Address)) continue;
                var message = SipMessage.Parse(result.Buffer);
                if (message is null) continue;
                if (message.StatusCode is int status)
                    await HandleResponseAsync(message, status, cancellationToken);
                else
                    await HandleRequestAsync(message, cancellationToken);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (ObjectDisposedException) { }
        catch (Exception exception)
        {
            _registered = false;
            PublishRegistration(SipRegistrationState.Failed, $"SIP отключён: {exception.Message}");
        }
    }

    private Task HandleResponseAsync(SipMessage message, int status, CancellationToken cancellationToken) =>
        message.CSeqMethod switch
        {
            "REGISTER" => HandleRegisterResponseAsync(message, status, cancellationToken),
            "INVITE" => HandleInviteResponseAsync(message, status, cancellationToken),
            _ => Task.CompletedTask,
        };

    private async Task HandleRegisterResponseAsync(SipMessage message, int status, CancellationToken cancellationToken)
    {
        var retryAuthenticated = false;
        var repeatMapped = false;
        lock (_stateLock)
        {
            if (message.Header("Call-ID") != _registrationCallId || message.CSeqNumber != _registrationCseq) return;
            _pendingRegistrationCseq = 0;
            var discovered = ViaMapping.Parse(message.Header("Via"));
            if (discovered is not null && discovered != _mappedContact)
            {
                _mappedContact = discovered;
                repeatMapped = status == 200;
            }
            switch (status)
            {
                case 200:
                    _registrationAuthAttempts = 0;
                    _registered = true;
                    break;
                case 401:
                case 407:
                    if (_registrationAuthAttempts >= 2) break;
                    var challengeHeader = status == 407 ? "Proxy-Authenticate" : "WWW-Authenticate";
                    var challenge = DigestChallenge.Parse(message.Header(challengeHeader));
                    if (challenge is null) break;
                    _registrationChallenge = challenge;
                    _registrationAuthorizationHeader = status == 407 ? "Proxy-Authorization" : "Authorization";
                    _registrationAuthAttempts++;
                    retryAuthenticated = true;
                    break;
            }
        }

        if (status == 200)
        {
            PublishRegistration(SipRegistrationState.Connected, "SIP подключён");
            if (repeatMapped)
            {
                await Task.Delay(250, cancellationToken);
                if (_registered) await SendRegisterAsync(300, cancellationToken);
            }
        }
        else if (retryAuthenticated) await SendRegisterAsync(300, cancellationToken);
        else if (status is 401 or 403 or 407)
        {
            _registered = false;
            PublishRegistration(SipRegistrationState.Failed, "FreePBX отклонил SIP-логин или пароль");
        }
        else if (status >= 300)
        {
            _registered = false;
            PublishRegistration(SipRegistrationState.Failed, $"Ошибка SIP {status}");
        }
    }

    private async Task HandleInviteResponseAsync(SipMessage message, int status, CancellationToken cancellationToken)
    {
        var dialog = _dialog;
        if (dialog is null || message.Header("Call-ID") != dialog.CallId || message.CSeqNumber != dialog.LocalCseq) return;
        if (status is >= 100 and < 200)
        {
            if (status is 180 or 183) PublishCall(dialog, SipCallState.Ringing, "Идёт вызов…");
            return;
        }

        if (status is 401 or 407 && !dialog.InviteAuthenticated)
        {
            await SendAckAsync(dialog, message, false, cancellationToken);
            var challenge = DigestChallenge.Parse(message.Header(status == 407 ? "Proxy-Authenticate" : "WWW-Authenticate"));
            if (challenge is null)
            {
                await FinishCallAsync(dialog, SipCallState.Failed, "Сервер не передал параметры авторизации");
                return;
            }
            dialog.InviteAuthenticated = true;
            dialog.InviteChallenge = challenge;
            dialog.InviteAuthorizationHeader = status == 407 ? "Proxy-Authorization" : "Authorization";
            dialog.LocalCseq++;
            dialog.InviteBranch = SipValues.NewBranch();
            await SendInviteAsync(dialog, dialog.State is SipCallState.Connected or SipCallState.Held, cancellationToken);
            return;
        }

        if (status is >= 200 and < 300)
        {
            dialog.RemoteTag = HeaderTag(message.Header("To"));
            dialog.RemoteTarget = HeaderUri(message.Header("Contact")) ?? dialog.RemoteTarget;
            await SendAckAsync(dialog, message, true, cancellationToken);
            if (!string.IsNullOrWhiteSpace(message.Body) && _server is not null)
            {
                var media = RemoteAudioMedia.FromSdp(message.Body, _server.Address);
                if (media is null)
                {
                    await FinishCallAsync(dialog, SipCallState.Failed, "Собеседник не поддерживает G.711 аудио");
                    return;
                }
                dialog.RemoteMedia = media;
                dialog.Rtp.Configure(media);
            }
            if (dialog.PendingHold is bool held)
            {
                dialog.PendingHold = null;
                dialog.Held = held;
                dialog.Rtp.SetHeld(held);
                PublishCall(dialog, held ? SipCallState.Held : SipCallState.Connected, held ? "На удержании" : "Соединено");
            }
            else
            {
                if (dialog.RemoteMedia is null)
                {
                    await FinishCallAsync(dialog, SipCallState.Failed, "Ответ не содержит аудио SDP");
                    return;
                }
                try { dialog.Rtp.Start(); }
                catch (Exception exception)
                {
                    await FinishCallAsync(dialog, SipCallState.Failed, $"Не удалось открыть аудиоустройство: {exception.Message}");
                    return;
                }
                dialog.ConnectedAt ??= DateTimeOffset.Now;
                PublishCall(dialog, SipCallState.Connected, "Соединено");
            }
            return;
        }

        await SendAckAsync(dialog, message, false, cancellationToken);
        await FinishCallAsync(dialog, SipCallState.Failed, $"Вызов отклонён: SIP {status}");
    }

    private async Task HandleRequestAsync(SipMessage request, CancellationToken cancellationToken)
    {
        switch (request.Method)
        {
            case "INVITE":
                await HandleIncomingInviteAsync(request, cancellationToken);
                break;
            case "ACK":
                await HandleAckAsync(request);
                break;
            case "BYE":
                await SendResponseAsync(request, 200, "OK", _dialog?.LocalTag, string.Empty, cancellationToken);
                if (_dialog is { } byeDialog && request.Header("Call-ID") == byeDialog.CallId)
                    await FinishCallAsync(byeDialog, SipCallState.Ended, "Собеседник завершил звонок");
                break;
            case "CANCEL":
                await SendResponseAsync(request, 200, "OK", _dialog?.LocalTag, string.Empty, cancellationToken);
                if (_dialog is { } cancelDialog && request.Header("Call-ID") == cancelDialog.CallId)
                {
                    if (cancelDialog.IncomingInvite is not null)
                        await SendResponseAsync(cancelDialog.IncomingInvite, 487, "Request Terminated", cancelDialog.LocalTag, string.Empty, cancellationToken);
                    await FinishCallAsync(cancelDialog, SipCallState.Ended, "Вызов отменён");
                }
                break;
            case "OPTIONS":
            case "INFO":
            case "NOTIFY":
            case "UPDATE":
                await SendResponseAsync(request, 200, "OK", _dialog?.LocalTag, string.Empty, cancellationToken);
                break;
            default:
                await SendResponseAsync(request, 501, "Not Implemented", _dialog?.LocalTag, string.Empty, cancellationToken);
                break;
        }
    }

    private async Task HandleIncomingInviteAsync(SipMessage request, CancellationToken cancellationToken)
    {
        var existing = _dialog;
        if (existing is not null && request.Header("Call-ID") == existing.CallId)
        {
            if (_server is null) return;
            var media = RemoteAudioMedia.FromSdp(request.Body, _server.Address);
            if (media is not null)
            {
                existing.RemoteMedia = media;
                existing.Rtp.Configure(media);
            }
            await SendResponseAsync(request, 200, "OK", existing.LocalTag, LocalSdp(existing, existing.Held), cancellationToken);
            return;
        }
        if (existing is not null)
        {
            await SendResponseAsync(request, 486, "Busy Here", null, string.Empty, cancellationToken);
            return;
        }
        if (_server is null)
        {
            await SendResponseAsync(request, 500, "Server Internal Error", null, string.Empty, cancellationToken);
            return;
        }
        var remoteMedia = RemoteAudioMedia.FromSdp(request.Body, _server.Address);
        if (remoteMedia is null)
        {
            await SendResponseAsync(request, 488, "Not Acceptable Here", null, string.Empty, cancellationToken);
            return;
        }
        var peer = HeaderUser(request.Header("From")) ?? "Неизвестный";
        var dialog = new SipDialog
        {
            PeerNumber = peer,
            IsIncoming = true,
            State = SipCallState.Incoming,
            CallId = request.Header("Call-ID") ?? SipValues.RandomHex(12),
            LocalTag = SipValues.RandomHex(8),
            RemoteTag = HeaderTag(request.Header("From")),
            RequestUri = $"sip:{_username}@{Domain}",
            RemoteTarget = HeaderUri(request.Header("Contact")) ?? $"sip:{peer}@{Domain}",
            LocalCseq = 1,
            InviteBranch = SipValues.NewBranch(),
            Rtp = new RtpAudioSession(),
            IncomingInvite = request,
            RemoteMedia = remoteMedia,
        };
        dialog.Rtp.Configure(remoteMedia);
        _dialog = dialog;
        await SendResponseAsync(request, 100, "Trying", dialog.LocalTag, string.Empty, cancellationToken);
        await SendResponseAsync(request, 180, "Ringing", dialog.LocalTag, string.Empty, cancellationToken);
        PublishCall(dialog, SipCallState.Incoming, $"Входящий звонок: {peer}");
    }

    private async Task HandleAckAsync(SipMessage request)
    {
        var dialog = _dialog;
        if (dialog is null || request.Header("Call-ID") != dialog.CallId || !dialog.IsIncoming || !dialog.Accepted) return;
        if (!dialog.RtpStarted)
        {
            try
            {
                dialog.Rtp.Start();
                dialog.RtpStarted = true;
                dialog.ConnectedAt = DateTimeOffset.Now;
                PublishCall(dialog, SipCallState.Connected, "Соединено");
            }
            catch (Exception exception)
            {
                await FinishCallAsync(dialog, SipCallState.Failed, $"Не удалось открыть аудиоустройство: {exception.Message}");
            }
        }
    }

    private async Task SendInviteAsync(SipDialog dialog, bool reinvite, CancellationToken cancellationToken)
    {
        var target = reinvite ? dialog.RemoteTarget : dialog.RequestUri;
        var headers = BaseHeaders(dialog.InviteBranch, dialog.LocalTag, dialog.RemoteTag, dialog.CallId,
            dialog.LocalCseq, "INVITE", dialog.PeerNumber);
        headers.Add($"Contact: <{LocalContactUri()}>");
        headers.Add("Allow: INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE");
        headers.Add("Supported: replaces, timer");
        headers.Add("Content-Type: application/sdp");
        if (dialog.InviteChallenge is not null)
        {
            dialog.InviteNonceCount++;
            headers.Add($"{dialog.InviteAuthorizationHeader}: {DigestAuthorization.Create(dialog.InviteChallenge, _username, _password, "INVITE", target, dialog.InviteNonceCount)}");
        }
        await SendTextAsync(BuildMessage($"INVITE {target} SIP/2.0", headers,
            LocalSdp(dialog, reinvite && dialog.PendingHold == true)), cancellationToken);
    }

    private Task SendCancelAsync(SipDialog dialog, CancellationToken cancellationToken)
    {
        var headers = BaseHeaders(dialog.InviteBranch, dialog.LocalTag, dialog.RemoteTag, dialog.CallId,
            dialog.LocalCseq, "CANCEL", dialog.PeerNumber);
        return SendTextAsync(BuildMessage($"CANCEL {dialog.RequestUri} SIP/2.0", headers, string.Empty), cancellationToken);
    }

    private Task SendByeAsync(SipDialog dialog, CancellationToken cancellationToken)
    {
        dialog.LocalCseq++;
        return SendDialogRequestAsync(dialog, "BYE", dialog.LocalCseq, SipValues.NewBranch(), string.Empty, null, cancellationToken);
    }

    private Task SendDialogRequestAsync(SipDialog dialog, string method, int cseq, string branch, string body,
        string? contentType, CancellationToken cancellationToken)
    {
        var headers = BaseHeaders(branch, dialog.LocalTag, dialog.RemoteTag, dialog.CallId, cseq, method, dialog.PeerNumber);
        headers.Add($"Contact: <{LocalContactUri()}>");
        if (contentType is not null) headers.Add($"Content-Type: {contentType}");
        return SendTextAsync(BuildMessage($"{method} {dialog.RemoteTarget} SIP/2.0", headers, body), cancellationToken);
    }

    private Task SendAckAsync(SipDialog dialog, SipMessage response, bool successful, CancellationToken cancellationToken)
    {
        var branch = successful ? SipValues.NewBranch() : dialog.InviteBranch;
        var target = successful ? dialog.RemoteTarget : dialog.RequestUri;
        var remoteTag = HeaderTag(response.Header("To")) ?? dialog.RemoteTag;
        var headers = BaseHeaders(branch, dialog.LocalTag, remoteTag, dialog.CallId, dialog.LocalCseq, "ACK", dialog.PeerNumber);
        return SendTextAsync(BuildMessage($"ACK {target} SIP/2.0", headers, string.Empty), cancellationToken);
    }

    private Task SendResponseAsync(SipMessage request, int status, string reason, string? localTag, string body,
        CancellationToken cancellationToken)
    {
        var headers = request.HeaderValues("Via").Select(value => $"Via: {value}").ToList();
        var from = request.Header("From");
        var to = request.Header("To");
        if (from is not null) headers.Add($"From: {from}");
        if (to is not null)
        {
            if (localTag is not null && HeaderTag(to) is null) to += $";tag={localTag}";
            headers.Add($"To: {to}");
        }
        if (request.Header("Call-ID") is { } callId) headers.Add($"Call-ID: {callId}");
        if (request.Header("CSeq") is { } cseq) headers.Add($"CSeq: {cseq}");
        if (status == 200 && request.Method == "INVITE") headers.Add($"Contact: <{LocalContactUri()}>");
        headers.Add("User-Agent: Tvoice-Windows/1.1.0 TvoiceSipCore/1.8");
        if (body.Length > 0) headers.Add("Content-Type: application/sdp");
        return SendTextAsync(BuildMessage($"SIP/2.0 {status} {reason}", headers, body), cancellationToken);
    }

    private List<string> BaseHeaders(string branch, string localTag, string? remoteTag, string callId, int cseq,
        string method, string? peer = null)
    {
        var localPort = ((IPEndPoint)(_socket?.Client.LocalEndPoint ?? throw new InvalidOperationException("SIP socket is not open."))).Port;
        var toUser = peer ?? _username;
        var to = $"<sip:{toUser}@{Domain}>" + (remoteTag is null ? string.Empty : $";tag={remoteTag}");
        return
        [
            $"Via: SIP/2.0/UDP {_localAddress}:{localPort};rport;branch={branch}",
            "Max-Forwards: 70",
            $"From: <sip:{_username}@{Domain}>;tag={localTag}",
            $"To: {to}",
            $"Call-ID: {callId}",
            $"CSeq: {cseq} {method}",
            "User-Agent: Tvoice-Windows/1.1.0 TvoiceSipCore/1.8",
        ];
    }

    private string LocalContactUri()
    {
        var socket = _socket ?? throw new InvalidOperationException("SIP socket is not open.");
        var localPort = ((IPEndPoint)socket.Client.LocalEndPoint!).Port;
        return _mappedContact is null
            ? $"sip:{_username}@{_localAddress}:{localPort};transport=udp"
            : $"sip:{_username}@{_mappedContact.Address}:{_mappedContact.Port};transport=udp";
    }

    private string LocalSdp(SipDialog dialog, bool held)
    {
        var address = _localAddress ?? IPAddress.Loopback;
        var sessionId = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        return "v=0\r\n" +
               $"o=Tvoice {sessionId} 1 IN IP4 {address}\r\n" +
               "s=Tvoice\r\n" +
               $"c=IN IP4 {address}\r\n" +
               "t=0 0\r\n" +
               $"m=audio {dialog.Rtp.LocalPort} RTP/AVP 8 0 101\r\n" +
               "a=rtpmap:8 PCMA/8000\r\n" +
               "a=rtpmap:0 PCMU/8000\r\n" +
               "a=rtpmap:101 telephone-event/8000\r\n" +
               "a=fmtp:101 0-16\r\n" +
               "a=ptime:20\r\n" +
               (held ? "a=sendonly\r\n" : "a=sendrecv\r\n");
    }

    private async Task SendTextAsync(string text, CancellationToken cancellationToken)
    {
        var socket = _socket ?? throw new InvalidOperationException("SIP socket is not open.");
        await _sendLock.WaitAsync(cancellationToken);
        try { await socket.SendAsync(Encoding.UTF8.GetBytes(text), cancellationToken); }
        finally { _sendLock.Release(); }
    }

    private async Task OutgoingTimeoutAsync(SipDialog dialog, CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(45), cancellationToken);
            if (ReferenceEquals(_dialog, dialog) && dialog.State is SipCallState.Calling or SipCallState.Ringing)
            {
                try { await SendCancelAsync(dialog, cancellationToken); } catch { }
                await FinishCallAsync(dialog, SipCallState.Failed, "Абонент не ответил");
            }
        }
        catch (OperationCanceledException) { }
    }

    private async Task FinishCallAsync(SipDialog dialog, SipCallState finalState, string message)
    {
        if (!ReferenceEquals(_dialog, dialog)) return;
        _dialog = null;
        PublishCall(dialog, finalState, message);
        await dialog.Rtp.DisposeAsync();
    }

    private async Task KeepAliveLoopAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(25));
        try
        {
            while (await timer.WaitForNextTickAsync(cancellationToken))
                if (_registered) await SendRegisterAsync(300, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
    }

    private void PublishRegistration(SipRegistrationState state, string message) =>
        StateChanged?.Invoke(this, new SipRegistrationChanged(state, message));

    private void PublishCall(SipDialog dialog, SipCallState state, string message)
    {
        dialog.State = state;
        CallChanged?.Invoke(this, new SipCallChanged(state, dialog.PeerNumber, message, dialog.IsIncoming,
            dialog.Muted, dialog.Held, dialog.ConnectedAt));
    }

    private static string BuildMessage(string startLine, IEnumerable<string> headers, string body) =>
        $"{startLine}\r\n{string.Join("\r\n", headers)}\r\nContent-Length: {Encoding.UTF8.GetByteCount(body)}\r\n\r\n{body}";

    private static string NormalizeNumber(string value)
    {
        var result = new string(value.Where(character => char.IsDigit(character) || character is '*' or '#').ToArray());
        if (result.Length is < 2 or > 32) throw new ArgumentException("Введите корректный SIP-номер.");
        return result;
    }

    private static string? HeaderTag(string? value) => value is null
        ? null
        : Regex.Match(value, "(?:^|;)\\s*tag=([^;>\\s]+)", RegexOptions.IgnoreCase) is { Success: true } match
            ? match.Groups[1].Value
            : null;

    private static string? HeaderUri(string? value) => value is null
        ? null
        : Regex.Match(value, "<?(sip:[^>;\\s]+)", RegexOptions.IgnoreCase) is { Success: true } match
            ? match.Groups[1].Value
            : null;

    private static string? HeaderUser(string? value) => value is null
        ? null
        : Regex.Match(value, "sip:([^@;>]+)", RegexOptions.IgnoreCase) is { Success: true } match
            ? match.Groups[1].Value
            : null;

    private static IPAddress ResolveLocalAddress(IPEndPoint server)
    {
        using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        socket.Connect(server);
        return ((IPEndPoint)socket.LocalEndPoint!).Address;
    }

    private sealed class SipDialog
    {
        public required string PeerNumber { get; init; }
        public required bool IsIncoming { get; init; }
        public required string CallId { get; init; }
        public required string LocalTag { get; init; }
        public required string RequestUri { get; init; }
        public required string RemoteTarget { get; set; }
        public required string InviteBranch { get; set; }
        public required RtpAudioSession Rtp { get; init; }
        public SipCallState State { get; set; }
        public string? RemoteTag { get; set; }
        public int LocalCseq { get; set; }
        public bool InviteAuthenticated { get; set; }
        public DigestChallenge? InviteChallenge { get; set; }
        public string InviteAuthorizationHeader { get; set; } = "Authorization";
        public int InviteNonceCount { get; set; }
        public bool Accepted { get; set; }
        public bool RtpStarted { get; set; }
        public bool Muted { get; set; }
        public bool Held { get; set; }
        public bool? PendingHold { get; set; }
        public DateTimeOffset? ConnectedAt { get; set; }
        public SipMessage? IncomingInvite { get; set; }
        public RemoteAudioMedia? RemoteMedia { get; set; }
    }
}
