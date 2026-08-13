using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Threading;
using Tvoice.Windows.Models;
using Tvoice.Windows.Services;
using Tvoice.Windows.Sip;

namespace Tvoice.Windows.ViewModels;

public sealed class MainViewModel : ViewModelBase, IAsyncDisposable
{
    private readonly TvoiceApiClient _api = new();
    private readonly TvoiceSipRegistration _sip = new();
    private readonly RingtonePlayer _ringtone = new();
    private readonly CallHistoryStore _historyStore = new();
    private readonly DispatcherTimer _callTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private string _sipNumber = string.Empty;
    private string _password = string.Empty;
    private string _messageText = string.Empty;
    private string _statusMessage = "Введите данные FreePBX";
    private string _displayName = string.Empty;
    private bool _isAuthenticated;
    private bool _isBusy;
    private TvoiceUser? _selectedContact;
    private Conversation? _selectedConversation;
    private int _selectedTabIndex;
    private string _chatState = "Чат отключён";
    private string _sipState = "SIP отключён";
    private string _dialNumber = string.Empty;
    private string _callPeer = string.Empty;
    private string _callStatus = string.Empty;
    private string _callDuration = "00:00";
    private bool _isCallPanelVisible;
    private bool _isIncomingCall;
    private bool _isCallConnected;
    private bool _isMuted;
    private bool _isHeld;
    private DateTimeOffset? _callConnectedAt;
    private IncomingVideoCall? _incomingVideoCall;
    private string? _activeVideoCallId;
    private bool _isIncomingVideoVisible;
    private string _incomingVideoPeer = string.Empty;
    private bool _voiceHistoryOpen;
    private bool _voiceHistoryIncoming;
    private string _voiceHistoryPeer = string.Empty;
    private DateTimeOffset _voiceHistoryStarted;
    private DateTimeOffset? _voiceHistoryConnected;
    private string _activeVideoPeer = string.Empty;
    private bool _activeVideoIncoming;
    private DateTimeOffset? _activeVideoStarted;

    public MainViewModel()
    {
        LoginCommand = new AsyncCommand(LoginAsync, CanLogin);
        StartChatCommand = new AsyncCommand(StartChatAsync, () => SelectedContact is not null && !IsBusy);
        SendMessageCommand = new AsyncCommand(SendMessageAsync, CanSendMessage);
        RefreshCommand = new AsyncCommand(LoadShellDataAsync, () => IsAuthenticated && !IsBusy);
        LogoutCommand = new AsyncCommand(LogoutAsync, () => IsAuthenticated);
        StartCallCommand = new AsyncCommand(StartCallAsync, CanStartCall);
        CallContactCommand = new AsyncCommand(CallContactAsync,
            () => SelectedContact is not null && IsAuthenticated && _sip.IsRegistered && !IsCallPanelVisible);
        AcceptCallCommand = new AsyncCommand(() => RunCallActionAsync(() => _sip.AcceptCallAsync()), () => IsIncomingCall);
        HangupCommand = new AsyncCommand(() => RunCallActionAsync(() => _sip.HangupAsync()), () => IsCallPanelVisible);
        ToggleMuteCommand = new RelayCommand(_ => _sip.SetMuted(!IsMuted), _ => IsCallConnected);
        ToggleHoldCommand = new AsyncCommand(() => RunCallActionAsync(() => _sip.SetHeldAsync(!IsHeld)), () => IsCallConnected);
        DialDigitCommand = new RelayCommand(DialDigit);
        StartVideoCallCommand = new AsyncCommand(StartVideoCallAsync, CanStartVideoCall);
        VideoCallContactCommand = new AsyncCommand(VideoCallContactAsync,
            () => SelectedContact is not null && IsAuthenticated && !IsIncomingVideoVisible && _activeVideoCallId is null);
        AnswerVideoCallCommand = new AsyncCommand(AnswerVideoCallAsync, () => IsIncomingVideoVisible);
        RejectVideoCallCommand = new AsyncCommand(RejectVideoCallAsync, () => IsIncomingVideoVisible);
        AttachFileCommand = new AsyncCommand(AttachFileAsync, () => SelectedConversation is not null && !IsBusy);
        OpenAttachmentCommand = new AsyncParameterCommand(OpenAttachmentAsync, value => value is ChatAttachment);
        _callTimer.Tick += (_, _) => UpdateCallDuration();
        foreach (var entry in _historyStore.Load()) CallHistory.Add(entry);
        _api.RealtimeEvent += OnRealtimeEvent;
        _api.ConnectionStateChanged += (_, state) => Dispatch(() =>
        {
            _chatState = state;
            UpdateConnectionStatus();
        });
        _sip.StateChanged += (_, state) => Dispatch(() =>
        {
            _sipState = state.Message;
            UpdateConnectionStatus();
            RefreshCallCommands();
        });
        _sip.CallChanged += OnCallChanged;
    }

    public ObservableCollection<TvoiceUser> Contacts { get; } = [];
    public ObservableCollection<Conversation> Conversations { get; } = [];
    public ObservableCollection<ChatMessage> Messages { get; } = [];
    public ObservableCollection<CallHistoryEntry> CallHistory { get; } = [];

    public AsyncCommand LoginCommand { get; }
    public AsyncCommand StartChatCommand { get; }
    public AsyncCommand SendMessageCommand { get; }
    public AsyncCommand RefreshCommand { get; }
    public AsyncCommand LogoutCommand { get; }
    public AsyncCommand StartCallCommand { get; }
    public AsyncCommand CallContactCommand { get; }
    public AsyncCommand AcceptCallCommand { get; }
    public AsyncCommand HangupCommand { get; }
    public RelayCommand ToggleMuteCommand { get; }
    public AsyncCommand ToggleHoldCommand { get; }
    public RelayCommand DialDigitCommand { get; }
    public AsyncCommand StartVideoCallCommand { get; }
    public AsyncCommand VideoCallContactCommand { get; }
    public AsyncCommand AnswerVideoCallCommand { get; }
    public AsyncCommand RejectVideoCallCommand { get; }
    public AsyncCommand AttachFileCommand { get; }
    public AsyncParameterCommand OpenAttachmentCommand { get; }

    public event EventHandler<VideoCallCredentials>? VideoSessionReady;
    public event EventHandler<string>? VideoCallClosed;

    public string SipNumber
    {
        get => _sipNumber;
        set
        {
            if (Set(ref _sipNumber, value)) LoginCommand.Refresh();
        }
    }

    public string Password
    {
        get => _password;
        set
        {
            if (Set(ref _password, value)) LoginCommand.Refresh();
        }
    }

    public string MessageText
    {
        get => _messageText;
        set
        {
            if (Set(ref _messageText, value)) SendMessageCommand.Refresh();
        }
    }

    public string StatusMessage
    {
        get => _statusMessage;
        set => Set(ref _statusMessage, value);
    }

    public string DialNumber
    {
        get => _dialNumber;
        set
        {
            if (Set(ref _dialNumber, value)) StartCallCommand.Refresh();
        }
    }

    public string CallPeer
    {
        get => _callPeer;
        private set => Set(ref _callPeer, value);
    }

    public string CallStatus
    {
        get => _callStatus;
        private set => Set(ref _callStatus, value);
    }

    public string CallDuration
    {
        get => _callDuration;
        private set => Set(ref _callDuration, value);
    }

    public bool IsCallPanelVisible
    {
        get => _isCallPanelVisible;
        private set
        {
            if (!Set(ref _isCallPanelVisible, value)) return;
            Raise(nameof(IsDialerVisible));
            RefreshCallCommands();
        }
    }

    public bool IsDialerVisible => !IsCallPanelVisible;

    public bool IsIncomingCall
    {
        get => _isIncomingCall;
        private set
        {
            if (Set(ref _isIncomingCall, value)) RefreshCallCommands();
        }
    }

    public bool IsCallConnected
    {
        get => _isCallConnected;
        private set
        {
            if (Set(ref _isCallConnected, value)) RefreshCallCommands();
        }
    }

    public bool IsMuted
    {
        get => _isMuted;
        private set
        {
            if (Set(ref _isMuted, value)) Raise(nameof(MuteButtonText));
        }
    }

    public bool IsHeld
    {
        get => _isHeld;
        private set
        {
            if (Set(ref _isHeld, value)) Raise(nameof(HoldButtonText));
        }
    }

    public string MuteButtonText => IsMuted ? "Включить микрофон" : "Микрофон";
    public string HoldButtonText => IsHeld ? "Продолжить" : "Удержание";

    public bool IsIncomingVideoVisible
    {
        get => _isIncomingVideoVisible;
        private set
        {
            if (!Set(ref _isIncomingVideoVisible, value)) return;
            AnswerVideoCallCommand.Refresh();
            RejectVideoCallCommand.Refresh();
            RefreshCallCommands();
        }
    }

    public string IncomingVideoPeer
    {
        get => _incomingVideoPeer;
        private set => Set(ref _incomingVideoPeer, value);
    }

    public string DisplayName
    {
        get => _displayName;
        set => Set(ref _displayName, value);
    }

    public bool IsAuthenticated
    {
        get => _isAuthenticated;
        set
        {
            if (!Set(ref _isAuthenticated, value)) return;
            Raise(nameof(IsLoginVisible));
            Raise(nameof(IsShellVisible));
            RefreshCommands();
        }
    }

    public bool IsLoginVisible => !IsAuthenticated;
    public bool IsShellVisible => IsAuthenticated;

    public bool IsBusy
    {
        get => _isBusy;
        set
        {
            if (!Set(ref _isBusy, value)) return;
            RefreshCommands();
        }
    }

    public TvoiceUser? SelectedContact
    {
        get => _selectedContact;
        set
        {
            if (Set(ref _selectedContact, value))
            {
                StartChatCommand.Refresh();
                CallContactCommand.Refresh();
                VideoCallContactCommand.Refresh();
            }
        }
    }

    public Conversation? SelectedConversation
    {
        get => _selectedConversation;
        set
        {
            if (!Set(ref _selectedConversation, value)) return;
            Raise(nameof(ActivePeerName));
            AttachFileCommand.Refresh();
            if (value is null)
            {
                Messages.Clear();
                return;
            }
            _ = LoadMessagesAsync(value);
        }
    }

    public int SelectedTabIndex
    {
        get => _selectedTabIndex;
        set => Set(ref _selectedTabIndex, value);
    }

    public string ActivePeerName => SelectedConversation?.Peer.DisplayName ?? "Выберите чат";

    public async ValueTask DisposeAsync()
    {
        _callTimer.Stop();
        _ringtone.Dispose();
        _api.RealtimeEvent -= OnRealtimeEvent;
        _sip.CallChanged -= OnCallChanged;
        await _sip.DisposeAsync();
        await _api.DisposeAsync();
    }

    private bool CanLogin() =>
        !IsBusy && !string.IsNullOrWhiteSpace(SipNumber) && !string.IsNullOrEmpty(Password);

    private bool CanSendMessage() =>
        !IsBusy && SelectedConversation is not null && !string.IsNullOrWhiteSpace(MessageText);

    private bool CanStartCall() =>
        !IsBusy && IsAuthenticated && _sip.IsRegistered && !IsCallPanelVisible && !string.IsNullOrWhiteSpace(DialNumber);

    private bool CanStartVideoCall() =>
        !IsBusy && IsAuthenticated && _activeVideoCallId is null && !IsIncomingVideoVisible && !string.IsNullOrWhiteSpace(DialNumber);

    private async Task StartCallAsync()
    {
        await RunCallActionAsync(() => _sip.CallAsync(DialNumber));
    }

    private async Task StartVideoCallAsync()
    {
        await RunCallActionAsync(async () =>
        {
            var credentials = await _api.StartVideoCallAsync(DialNumber.Trim());
            _activeVideoCallId = credentials.CallId;
            _activeVideoPeer = credentials.Peer.SipNumber;
            _activeVideoIncoming = false;
            _activeVideoStarted = DateTimeOffset.Now;
            VideoSessionReady?.Invoke(this, credentials);
        });
    }

    private async Task VideoCallContactAsync()
    {
        if (SelectedContact is null) return;
        DialNumber = SelectedContact.SipNumber;
        await RunCallActionAsync(async () =>
        {
            var credentials = await _api.StartVideoCallAsync(SelectedContact.SipNumber);
            _activeVideoCallId = credentials.CallId;
            _activeVideoPeer = credentials.Peer.SipNumber;
            _activeVideoIncoming = false;
            _activeVideoStarted = DateTimeOffset.Now;
            VideoSessionReady?.Invoke(this, credentials);
        });
    }

    private async Task AnswerVideoCallAsync()
    {
        var invite = _incomingVideoCall;
        if (invite is null) return;
        _ringtone.Stop();
        await RunCallActionAsync(async () =>
        {
            var credentials = await _api.AnswerVideoCallAsync(invite.CallId);
            _activeVideoCallId = credentials.CallId;
            _activeVideoPeer = credentials.Peer.SipNumber;
            _activeVideoIncoming = true;
            _activeVideoStarted = DateTimeOffset.Now;
            _incomingVideoCall = null;
            IsIncomingVideoVisible = false;
            VideoSessionReady?.Invoke(this, credentials);
        });
    }

    private async Task RejectVideoCallAsync()
    {
        var invite = _incomingVideoCall;
        if (invite is null) return;
        _ringtone.Stop();
        await RunCallActionAsync(async () =>
        {
            await _api.RejectVideoCallAsync(invite.CallId);
            _incomingVideoCall = null;
            IsIncomingVideoVisible = false;
        });
    }

    public async Task EndVideoCallAsync(string callId)
    {
        if (_activeVideoCallId != callId) return;
        _activeVideoCallId = null;
        try { await _api.EndVideoCallAsync(callId); }
        catch (Exception exception) { StatusMessage = exception.Message; }
        CompleteVideoHistory("Завершён");
        VideoCallClosed?.Invoke(this, callId);
        RefreshCallCommands();
    }

    private async Task CallContactAsync()
    {
        if (SelectedContact is null) return;
        DialNumber = SelectedContact.SipNumber;
        SelectedTabIndex = 1;
        await RunCallActionAsync(() => _sip.CallAsync(DialNumber));
    }

    private void DialDigit(object? parameter)
    {
        var text = parameter?.ToString();
        if (string.IsNullOrEmpty(text)) return;
        var digit = text[0];
        if (IsCallConnected) _ = RunCallActionAsync(() => _sip.SendDtmfAsync(digit));
        else DialNumber += digit;
    }

    private async Task LoginAsync()
    {
        await GuardAsync(async () =>
        {
            StatusMessage = "Подключение к Tvoice…";
            var login = await _api.LoginAsync(SipNumber, Password);
            var sipPassword = Password;
            DisplayName = string.IsNullOrWhiteSpace(login.User.DisplayName)
                ? login.User.SipNumber
                : login.User.DisplayName;
            IsAuthenticated = true;
            await LoadShellDataCoreAsync();
            try { await _api.ConnectRealtimeAsync(); }
            catch (Exception exception) { _chatState = $"Чат: {exception.Message}"; }
            await _sip.RegisterAsync(login.User.SipNumber, sipPassword);
            Password = string.Empty;
            UpdateConnectionStatus();
        });
    }

    private Task LoadShellDataAsync() => GuardAsync(LoadShellDataCoreAsync);

    private async Task LoadShellDataCoreAsync()
    {
        var contactsTask = _api.GetContactsAsync();
        var conversationsTask = _api.GetConversationsAsync();
        await Task.WhenAll(contactsTask, conversationsTask);

        Replace(Contacts, contactsTask.Result.Contacts);
        var selectedId = SelectedConversation?.Id;
        Replace(Conversations, conversationsTask.Result.Conversations);
        SelectedConversation = selectedId is null
            ? null
            : Conversations.FirstOrDefault(item => item.Id == selectedId);
        StatusMessage = "Подключено";
        _chatState = "Чат подключён";
        UpdateConnectionStatus();
    }

    private async Task StartChatAsync()
    {
        if (SelectedContact is null) return;
        await GuardAsync(async () =>
        {
            var conversation = await _api.OpenDirectConversationAsync(SelectedContact.SipNumber);
            var existing = Conversations.FirstOrDefault(item => item.Id == conversation.Id);
            if (existing is null)
            {
                Conversations.Insert(0, conversation);
                existing = conversation;
            }
            SelectedConversation = existing;
            SelectedTabIndex = 2;
            await LoadMessagesCoreAsync(existing);
        });
    }

    private Task LoadMessagesAsync(Conversation conversation) =>
        GuardAsync(() => LoadMessagesCoreAsync(conversation));

    private async Task LoadMessagesCoreAsync(Conversation conversation)
    {
        var response = await _api.GetMessagesAsync(conversation.Id);
        if (SelectedConversation?.Id != conversation.Id) return;
        Replace(Messages, response.Messages);
        await _api.MarkReadAsync(conversation.Id);
    }

    private async Task SendMessageAsync()
    {
        var conversation = SelectedConversation;
        var body = MessageText.Trim();
        if (conversation is null || body.Length == 0) return;
        MessageText = string.Empty;
        await GuardAsync(async () =>
        {
            var sent = await _api.SendMessageAsync(conversation.Id, body);
            if (Messages.All(message => message.Id != sent.Id)) Messages.Add(sent);
            await RefreshConversationsAsync(conversation.Id);
        });
    }

    private async Task AttachFileAsync()
    {
        var conversation = SelectedConversation;
        if (conversation is null) return;
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "Выберите фото или файл",
            CheckFileExists = true,
            Multiselect = false,
        };
        if (dialog.ShowDialog() != true) return;
        await GuardAsync(async () =>
        {
            var sent = await _api.UploadAttachmentAsync(conversation.Id, dialog.FileName);
            if (Messages.All(message => message.Id != sent.Id)) Messages.Add(sent);
            await RefreshConversationsAsync(conversation.Id);
        });
    }

    private async Task OpenAttachmentAsync(object? parameter)
    {
        if (parameter is not ChatAttachment attachment) return;
        try
        {
            var file = await _api.DownloadAttachmentAsync(attachment);
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(file) { UseShellExecute = true });
        }
        catch (Exception exception) { StatusMessage = exception.Message; }
    }

    private async Task RefreshConversationsAsync(string? keepSelectedId = null)
    {
        var response = await _api.GetConversationsAsync();
        Replace(Conversations, response.Conversations);
        SelectedConversation = Conversations.FirstOrDefault(item => item.Id == keepSelectedId)
            ?? SelectedConversation;
    }

    private async Task LogoutAsync()
    {
        _ringtone.Stop();
        _callTimer.Stop();
        await _api.LogoutAsync();
        await _sip.DisconnectAsync();
        Contacts.Clear();
        Conversations.Clear();
        Messages.Clear();
        SelectedContact = null;
        SelectedConversation = null;
        DisplayName = string.Empty;
        IsAuthenticated = false;
        StatusMessage = "Введите данные FreePBX";
        _chatState = "Чат отключён";
        _sipState = "SIP отключён";
        _activeVideoCallId = null;
        _incomingVideoCall = null;
        IsIncomingVideoVisible = false;
        ResetCallUi();
    }

    private void OnRealtimeEvent(object? sender, ChatRealtimeEvent realtimeEvent)
    {
        Dispatch(async () =>
        {
            if (realtimeEvent.Type == "message.new" && realtimeEvent.Message is not null)
            {
                var active = SelectedConversation;
                if (active is not null &&
                    active.Id == realtimeEvent.Message.ConversationId &&
                    Messages.All(item => item.Id != realtimeEvent.Message.Id))
                {
                    Messages.Add(realtimeEvent.Message);
                    await _api.MarkReadAsync(active.Id);
                }
                await RefreshConversationsAsync(active?.Id);
            }
            else if (realtimeEvent.Type is "message.delivered" or "message.read")
            {
                var active = SelectedConversation;
                if (active is not null && active.Id == realtimeEvent.ConversationId)
                    await LoadMessagesAsync(active);
            }
            else if (realtimeEvent.Type == "video.call.incoming" && realtimeEvent.CallId is not null && realtimeEvent.From is not null)
            {
                if (_activeVideoCallId is not null || IsIncomingVideoVisible)
                {
                    await _api.RejectVideoCallAsync(realtimeEvent.CallId);
                    return;
                }
                _incomingVideoCall = new IncomingVideoCall(realtimeEvent.CallId, realtimeEvent.From, realtimeEvent.ExpiresAt);
                IncomingVideoPeer = string.IsNullOrWhiteSpace(realtimeEvent.From.DisplayName)
                    ? realtimeEvent.From.SipNumber
                    : realtimeEvent.From.DisplayName;
                IsIncomingVideoVisible = true;
                _ringtone.Start();
            }
            else if (realtimeEvent.Type is "video.call.rejected" or "video.call.ended" && realtimeEvent.CallId is not null)
            {
                if (_incomingVideoCall?.CallId == realtimeEvent.CallId)
                {
                    _ringtone.Stop();
                    _incomingVideoCall = null;
                    IsIncomingVideoVisible = false;
                }
                if (_activeVideoCallId == realtimeEvent.CallId)
                {
                    _activeVideoCallId = null;
                    CompleteVideoHistory(realtimeEvent.Type == "video.call.rejected" ? "Отклонён" : "Завершён");
                    VideoCallClosed?.Invoke(this, realtimeEvent.CallId);
                }
            }
        });
    }

    private void OnCallChanged(object? sender, SipCallChanged call)
    {
        Dispatch(() =>
        {
            if (!_voiceHistoryOpen && call.State is not (SipCallState.Ended or SipCallState.Failed))
            {
                _voiceHistoryOpen = true;
                _voiceHistoryIncoming = call.IsIncoming;
                _voiceHistoryPeer = call.PeerNumber;
                _voiceHistoryStarted = DateTimeOffset.Now;
            }
            if (call.ConnectedAt is not null) _voiceHistoryConnected = call.ConnectedAt;
            CallPeer = call.PeerNumber;
            CallStatus = call.Message;
            IsIncomingCall = call.State == SipCallState.Incoming;
            IsCallConnected = call.State is SipCallState.Connected or SipCallState.Held;
            IsMuted = call.IsMuted;
            IsHeld = call.IsHeld;
            _callConnectedAt = call.ConnectedAt;
            if (call.State == SipCallState.Incoming) _ringtone.Start();
            else _ringtone.Stop();

            if (call.State is SipCallState.Ended or SipCallState.Failed)
            {
                CompleteVoiceHistory(call.Message);
                IsCallPanelVisible = false;
                _callTimer.Stop();
                CallDuration = "00:00";
                StatusMessage = call.Message;
            }
            else
            {
                IsCallPanelVisible = true;
                if (_callConnectedAt is not null)
                {
                    UpdateCallDuration();
                    _callTimer.Start();
                }
            }
            RefreshCallCommands();
        });
    }

    private void UpdateCallDuration()
    {
        if (_callConnectedAt is null) return;
        var elapsed = DateTimeOffset.Now - _callConnectedAt.Value;
        CallDuration = elapsed.TotalHours >= 1
            ? $"{(int)elapsed.TotalHours:00}:{elapsed.Minutes:00}:{elapsed.Seconds:00}"
            : $"{elapsed.Minutes:00}:{elapsed.Seconds:00}";
    }

    private void ResetCallUi()
    {
        IsCallPanelVisible = false;
        IsIncomingCall = false;
        IsCallConnected = false;
        IsMuted = false;
        IsHeld = false;
        CallPeer = string.Empty;
        CallStatus = string.Empty;
        CallDuration = "00:00";
        _callConnectedAt = null;
    }

    private void CompleteVoiceHistory(string result)
    {
        if (!_voiceHistoryOpen) return;
        var duration = _voiceHistoryConnected is null
            ? 0
            : Math.Max(0, (int)(DateTimeOffset.Now - _voiceHistoryConnected.Value).TotalSeconds);
        AddHistory(new CallHistoryEntry(_voiceHistoryPeer, _voiceHistoryIncoming, false,
            _voiceHistoryStarted, duration, result));
        _voiceHistoryOpen = false;
        _voiceHistoryConnected = null;
    }

    private void CompleteVideoHistory(string result)
    {
        if (_activeVideoStarted is null) return;
        var duration = Math.Max(0, (int)(DateTimeOffset.Now - _activeVideoStarted.Value).TotalSeconds);
        AddHistory(new CallHistoryEntry(_activeVideoPeer, _activeVideoIncoming, true,
            _activeVideoStarted.Value, duration, result));
        _activeVideoStarted = null;
        _activeVideoPeer = string.Empty;
    }

    private void AddHistory(CallHistoryEntry entry)
    {
        CallHistory.Insert(0, entry);
        while (CallHistory.Count > 200) CallHistory.RemoveAt(CallHistory.Count - 1);
        _historyStore.Save(CallHistory);
    }

    private async Task GuardAsync(Func<Task> action)
    {
        if (IsBusy) return;
        IsBusy = true;
        try
        {
            await action();
        }
        catch (Exception exception)
        {
            StatusMessage = exception.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task RunCallActionAsync(Func<Task> action)
    {
        try { await action(); }
        catch (Exception exception) { StatusMessage = exception.Message; }
        finally { RefreshCallCommands(); }
    }

    private static void Replace<T>(ObservableCollection<T> target, IEnumerable<T> values)
    {
        target.Clear();
        foreach (var value in values) target.Add(value);
    }

    private static void Dispatch(Action action)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess()) action();
        else dispatcher.Invoke(action);
    }

    private static void Dispatch(Func<Task> action)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess()) _ = action();
        else _ = dispatcher.InvokeAsync(action);
    }

    private void RefreshCommands()
    {
        LoginCommand.Refresh();
        StartChatCommand.Refresh();
        SendMessageCommand.Refresh();
        RefreshCommand.Refresh();
        LogoutCommand.Refresh();
        AttachFileCommand.Refresh();
        RefreshCallCommands();
    }

    private void RefreshCallCommands()
    {
        StartCallCommand.Refresh();
        CallContactCommand.Refresh();
        AcceptCallCommand.Refresh();
        HangupCommand.Refresh();
        ToggleMuteCommand.Refresh();
        ToggleHoldCommand.Refresh();
        StartVideoCallCommand.Refresh();
        VideoCallContactCommand.Refresh();
    }

    private void UpdateConnectionStatus()
    {
        if (!IsAuthenticated) return;
        StatusMessage = $"{_chatState} · {_sipState}";
    }
}
