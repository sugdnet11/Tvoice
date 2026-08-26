import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/app_config.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/session_store.dart';
import '../services/sip_bridge.dart';

class AppController extends ChangeNotifier {
  AppController({
    required this.api,
    required this.sessionStore,
    required this.sip,
  }) {
    _sipSubscription = sip.events.listen(
      _handleSipEvent,
      onError: (_) {
        sipState = SipRegistrationState.unavailable;
        notifyListeners();
      },
    );
  }

  final ApiClient api;
  final SessionStore sessionStore;
  final SipBridge sip;

  TvoiceUser? user;
  List<TvoiceUser> contacts = const [];
  List<Conversation> conversations = const [];
  List<CallHistoryEntry> callHistory = const [];
  Set<String> favoriteCallNumbers = <String>{};
  final Map<String, List<ChatMessage>> messages = {};
  VideoCallSession? incomingVideoCall;
  String? lastEndedVideoCallId;
  SipRegistrationState sipState = SipRegistrationState.unavailable;
  SipCallState sipCallState = SipCallState.idle;
  String sipRemoteNumber = '';
  String sipCallMessage = '';
  DateTime? sipConnectedAt;
  bool sipMuted = false;
  bool sipSpeaker = false;
  bool sipHeld = false;
  ThemeMode themeMode = ThemeMode.system;
  bool busy = false;
  bool initialized = false;
  String? error;

  WebSocketChannel? _webSocket;
  StreamSubscription<dynamic>? _webSocketSubscription;
  late final StreamSubscription<SipEvent> _sipSubscription;
  Timer? _pingTimer;
  CallHistoryEntry? _activeSipHistory;
  CallHistoryEntry? _activeVideoHistory;

  bool get signedIn => user != null && api.accessToken != null;
  bool get hasActiveSipCall =>
      sipCallState == SipCallState.incoming ||
      sipCallState == SipCallState.outgoing ||
      sipCallState == SipCallState.ringing ||
      sipCallState == SipCallState.connected ||
      sipCallState == SipCallState.paused;

  Future<void> restoreSession() async {
    try {
      final stored = await sessionStore.read();
      if (stored == null) return;
      api.accessToken = stored.accessToken;
      user = await api.me();
      await _afterLogin(stored.sipNumber, stored.password);
    } catch (_) {
      await logout();
      error = 'Не удалось восстановить сессию. Войдите снова.';
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<bool> login(String sipNumber, String password) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final result = await api.login(sipNumber.trim(), password);
      user = result.user;
      await sessionStore.write(
        StoredSession(
          sipNumber: sipNumber.trim(),
          password: password,
          accessToken: result.accessToken,
        ),
      );
      await _afterLogin(sipNumber.trim(), password);
      return true;
    } on ApiException catch (exception) {
      error = exception.message;
      return false;
    } catch (_) {
      error = 'Нет соединения с сервером';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _afterLogin(String sipNumber, String password) async {
    sipState = SipRegistrationState.connecting;
    notifyListeners();
    try {
      await Future.wait([
        refreshContacts(),
        refreshConversations(),
        _loadCallHistory(sipNumber),
        _loadFavoriteCallNumbers(sipNumber),
      ]);
    } catch (_) {
      // The authenticated session remains valid. Realtime and manual refresh
      // can recover if one initial directory request temporarily fails.
    }
    _connectWebSocket();
    if (Platform.isAndroid) unawaited(Permission.notification.request());
    sipState = await sip.register(
      number: sipNumber,
      password: password,
      host: AppConfig.sipHost,
      port: AppConfig.sipPort,
    );
    notifyListeners();
  }

  Future<void> refreshContacts() async {
    contacts = await api.contacts();
    notifyListeners();
  }

  Future<void> refreshConversations() async {
    conversations = await api.conversations();
    notifyListeners();
  }

  Future<Conversation> openDirect(TvoiceUser peer) async {
    final conversation = await api.directConversation(peer.sipNumber);
    if (!conversations.any((item) => item.id == conversation.id)) {
      conversations = [conversation, ...conversations];
      notifyListeners();
    }
    return conversation;
  }

  Future<List<ChatMessage>> loadMessages(String conversationId) async {
    final loaded = await api.messages(conversationId);
    messages[conversationId] = loaded;
    notifyListeners();
    unawaited(api.markRead(conversationId));
    return loaded;
  }

  Future<void> sendMessage(String conversationId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final message = await api.sendMessage(conversationId, trimmed);
    _upsertMessage(message);
    await refreshConversations();
  }

  Future<VideoCallSession> startVideoCall(TvoiceUser peer) async {
    await _ensureVideoPermissions();
    final session = await api.startVideoCall(peer.sipNumber);
    _beginVideoHistory(session, CallDirection.outgoing);
    return session;
  }

  Future<VideoCallSession> createConference({
    required String title,
    required bool allowGuests,
    required bool cameraEnabled,
    required bool microphoneEnabled,
  }) async {
    await _ensureVideoPermissions();
    final current = user;
    if (current == null) throw const ApiException('Сеанс авторизации завершён');
    return api.createConference(
      localUser: current,
      title: title,
      allowGuests: allowGuests,
      cameraEnabled: cameraEnabled,
      microphoneEnabled: microphoneEnabled,
    );
  }

  Future<void> endConference(String conferenceId) =>
      api.endConference(conferenceId);

  Future<List<ConferenceRoom>> conferenceRooms() => api.conferenceRooms();

  Future<ConferenceRoom> createConferenceRoom({
    required String title,
    required bool allowGuests,
  }) => api.createConferenceRoom(title: title, allowGuests: allowGuests);

  Future<VideoCallSession> openConferenceRoom(ConferenceRoom room) async {
    await _ensureVideoPermissions();
    final current = user;
    if (current == null) throw const ApiException('Сеанс авторизации завершён');
    return api.openConferenceRoom(room.id, current);
  }

  Future<void> revokeConferenceRoom(String conferenceId) =>
      api.revokeConferenceRoom(conferenceId);

  Future<VideoCallSession> joinConference(String inviteToken) async {
    await _ensureVideoPermissions();
    final current = user;
    if (current == null) throw const ApiException('Сначала войдите в Tvoice');
    return api.joinConference(inviteToken, current);
  }

  Future<void> _ensureVideoPermissions() async {
    if (!Platform.isAndroid) return;
    final permissions = await [
      Permission.microphone,
      Permission.camera,
    ].request();
    if (permissions.values.any((status) => !status.isGranted)) {
      throw const ApiException(
        'Для видеосвязи нужен доступ к камере и микрофону',
      );
    }
  }

  Future<bool> startAudioCall(String number) async {
    if (Platform.isAndroid) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        error = 'Для звонка нужен доступ к микрофону';
        notifyListeners();
        return false;
      }
    }
    sipRemoteNumber = number;
    _beginSipHistory(number, CallDirection.outgoing);
    sipCallState = SipCallState.outgoing;
    sipCallMessage = 'Вызов…';
    notifyListeners();
    try {
      await sip.call(number);
      return true;
    } catch (_) {
      sipCallState = SipCallState.error;
      sipCallMessage = 'Не удалось начать звонок';
      _finishSipHistory(failed: true);
      notifyListeners();
      return false;
    }
  }

  Future<void> answerSipCall() async {
    if (Platform.isAndroid) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) return;
    }
    await sip.answer();
  }

  Future<void> hangupSipCall() => sip.hangup();

  Future<void> setSipMuted(bool muted) async {
    await sip.setMuted(muted);
    sipMuted = muted;
    notifyListeners();
  }

  Future<void> setSipSpeaker(bool enabled) async {
    await sip.setSpeaker(enabled);
    sipSpeaker = enabled;
    notifyListeners();
  }

  Future<void> setSipHeld(bool held) async {
    await sip.setHeld(held);
    sipHeld = held;
    notifyListeners();
  }

  Future<VideoCallSession?> answerIncomingVideo() async {
    final call = incomingVideoCall;
    if (call == null) return null;
    final answered = await api.answerVideoCall(call);
    incomingVideoCall = null;
    notifyListeners();
    return answered;
  }

  void markVideoConnected(String callId) {
    final active = _activeVideoHistory;
    if (active == null || active.id != 'video-$callId') return;
    if (active.connectedAt != null) return;
    _activeVideoHistory = active.copyWith(
      connectedAt: DateTime.now(),
      result: CallResult.completed,
    );
    _upsertHistoryEntry(_activeVideoHistory!);
  }

  Future<void> rejectIncomingVideo() async {
    final call = incomingVideoCall;
    if (call == null) return;
    incomingVideoCall = null;
    notifyListeners();
    try {
      await api.endVideoCall(call.callId, reject: true);
    } finally {
      _finishVideoHistory(call.callId);
    }
  }

  Future<void> endVideoCall(String callId) async {
    try {
      await api.endVideoCall(callId);
    } finally {
      _finishVideoHistory(callId);
    }
  }

  void setThemeMode(ThemeMode mode) {
    themeMode = mode;
    notifyListeners();
  }

  Future<void> logout() async {
    _pingTimer?.cancel();
    try {
      await sip.unregister();
    } catch (_) {
      // Local session cleanup must still finish if the SIP network is down.
    }
    await _webSocketSubscription?.cancel();
    await _webSocket?.sink.close();
    _webSocket = null;
    api.accessToken = null;
    user = null;
    contacts = const [];
    conversations = const [];
    callHistory = const [];
    favoriteCallNumbers = <String>{};
    messages.clear();
    incomingVideoCall = null;
    sipState = SipRegistrationState.unavailable;
    sipCallState = SipCallState.idle;
    sipRemoteNumber = '';
    sipCallMessage = '';
    sipConnectedAt = null;
    _activeSipHistory = null;
    _activeVideoHistory = null;
    await sessionStore.clear();
    notifyListeners();
  }

  void _connectWebSocket() {
    final token = api.accessToken;
    if (token == null) return;
    _pingTimer?.cancel();
    unawaited(_webSocketSubscription?.cancel());
    _webSocket = WebSocketChannel.connect(AppConfig.webSocket(token));
    _webSocketSubscription = _webSocket!.stream.listen(
      _handleWebSocketEvent,
      onDone: _scheduleReconnect,
      onError: (_) => _scheduleReconnect(),
    );
    _pingTimer = Timer.periodic(
      const Duration(seconds: 25),
      (_) => _webSocket?.sink.add('ping'),
    );
  }

  void _scheduleReconnect() {
    _pingTimer?.cancel();
    if (!signedIn) return;
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (signedIn) _connectWebSocket();
    });
  }

  void _handleWebSocketEvent(dynamic raw) {
    if (raw == 'pong') return;
    final event = jsonDecode(raw.toString()) as Map<String, dynamic>;
    switch (event['type']) {
      case 'message.new':
        final message = ChatMessage.fromJson(
          event['message'] as Map<String, dynamic>,
        );
        _upsertMessage(message);
        unawaited(refreshConversations());
      case 'message.delivered':
        _promoteStatus(event, MessageStatus.delivered);
      case 'message.read':
        _promoteStatus(event, MessageStatus.read);
      case 'video.call.incoming':
        incomingVideoCall = VideoCallSession.incoming(event);
        _beginVideoHistory(incomingVideoCall!, CallDirection.incoming);
        notifyListeners();
      case 'video.call.rejected':
      case 'video.call.ended':
        lastEndedVideoCallId = event['callId']?.toString();
        if (incomingVideoCall?.callId == event['callId']) {
          incomingVideoCall = null;
        }
        _finishVideoHistory(event['callId']?.toString() ?? '');
        notifyListeners();
    }
  }

  void _handleSipEvent(SipEvent event) {
    if (event.registrationState != null) {
      sipState = event.registrationState!;
    }
    if (event.callState != null) {
      final previousState = sipCallState;
      sipCallState = event.callState!;
      sipRemoteNumber = event.remoteNumber;
      sipCallMessage = event.message;
      sipConnectedAt = event.connectedAt ?? sipConnectedAt;
      if (sipCallState == SipCallState.incoming) {
        _beginSipHistory(event.remoteNumber, CallDirection.incoming);
      } else if ((sipCallState == SipCallState.outgoing ||
              sipCallState == SipCallState.ringing) &&
          _activeSipHistory == null) {
        _beginSipHistory(event.remoteNumber, CallDirection.outgoing);
      }
      if (sipCallState == SipCallState.connected ||
          sipCallState == SipCallState.paused) {
        _markSipConnected(event.connectedAt);
      }
      if (sipCallState == SipCallState.paused) sipHeld = true;
      if (sipCallState == SipCallState.connected) sipHeld = false;
      if (sipCallState == SipCallState.ended ||
          sipCallState == SipCallState.error ||
          (sipCallState == SipCallState.idle &&
              previousState != SipCallState.idle)) {
        _finishSipHistory(failed: sipCallState == SipCallState.error);
        sipConnectedAt = null;
        sipMuted = false;
        sipSpeaker = false;
        sipHeld = false;
      }
    }
    notifyListeners();
  }

  Future<void> _loadCallHistory(String sipNumber) async {
    callHistory = await sessionStore.readCallHistory(sipNumber);
    notifyListeners();
  }

  Future<void> _loadFavoriteCallNumbers(String sipNumber) async {
    favoriteCallNumbers = await sessionStore.readFavoriteCallNumbers(sipNumber);
    notifyListeners();
  }

  void toggleFavoriteCallNumber(String number) {
    if (number.isEmpty) return;
    final updated = {...favoriteCallNumbers};
    if (!updated.remove(number)) updated.add(number);
    favoriteCallNumbers = updated;
    final sipNumber = user?.sipNumber;
    if (sipNumber != null && sipNumber.isNotEmpty) {
      unawaited(
        sessionStore.writeFavoriteCallNumbers(sipNumber, favoriteCallNumbers),
      );
    }
    notifyListeners();
  }

  void _beginSipHistory(String number, CallDirection direction) {
    if (_activeSipHistory != null || number.isEmpty) return;
    final now = DateTime.now();
    _activeSipHistory = CallHistoryEntry(
      id: 'sip-${now.microsecondsSinceEpoch}',
      number: number,
      direction: direction,
      media: CallMedia.audio,
      result: direction == CallDirection.incoming
          ? CallResult.missed
          : CallResult.failed,
      startedAt: now,
    );
    _upsertHistoryEntry(_activeSipHistory!);
  }

  void _markSipConnected(DateTime? connectedAt) {
    final active = _activeSipHistory;
    if (active == null || active.connectedAt != null) return;
    _activeSipHistory = active.copyWith(
      connectedAt: connectedAt ?? DateTime.now(),
      result: CallResult.completed,
    );
    _upsertHistoryEntry(_activeSipHistory!);
  }

  void _finishSipHistory({required bool failed}) {
    final active = _activeSipHistory;
    if (active == null) return;
    _activeSipHistory = null;
    final completed = active.connectedAt != null;
    final result = completed
        ? CallResult.completed
        : active.direction == CallDirection.incoming
        ? CallResult.missed
        : CallResult.failed;
    final entry = active.copyWith(
      result: failed && !completed ? CallResult.failed : result,
      endedAt: DateTime.now(),
    );
    _upsertHistoryEntry(entry);
  }

  void _beginVideoHistory(VideoCallSession session, CallDirection direction) {
    if (_activeVideoHistory?.id == 'video-${session.callId}') return;
    final now = DateTime.now();
    _activeVideoHistory = CallHistoryEntry(
      id: 'video-${session.callId}',
      number: session.peer.sipNumber,
      direction: direction,
      media: CallMedia.video,
      result: direction == CallDirection.incoming
          ? CallResult.missed
          : CallResult.failed,
      startedAt: now,
    );
    _upsertHistoryEntry(_activeVideoHistory!);
  }

  void _finishVideoHistory(String callId) {
    final active = _activeVideoHistory;
    if (active == null || active.id != 'video-$callId') return;
    _activeVideoHistory = null;
    final completed = active.connectedAt != null;
    final result = completed
        ? CallResult.completed
        : active.direction == CallDirection.incoming
        ? CallResult.missed
        : CallResult.failed;
    _upsertHistoryEntry(
      active.copyWith(result: result, endedAt: DateTime.now()),
    );
  }

  void _upsertHistoryEntry(CallHistoryEntry entry) {
    final updated = [...callHistory];
    final index = updated.indexWhere((item) => item.id == entry.id);
    if (index >= 0) {
      updated[index] = entry;
    } else {
      updated.add(entry);
    }
    updated.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    callHistory = updated.take(250).toList(growable: false);
    final sipNumber = user?.sipNumber;
    if (sipNumber != null && sipNumber.isNotEmpty) {
      unawaited(sessionStore.writeCallHistory(sipNumber, callHistory));
    }
    notifyListeners();
  }

  void _upsertMessage(ChatMessage message) {
    final list = [
      ...(messages[message.conversationId] ?? const <ChatMessage>[]),
    ];
    final index = list.indexWhere((item) => item.id == message.id);
    if (index >= 0) {
      list[index] = message;
    } else {
      list.add(message);
    }
    messages[message.conversationId] = list;
    notifyListeners();
  }

  void _promoteStatus(Map<String, dynamic> event, MessageStatus status) {
    final id = event['conversationId']?.toString();
    final through = DateTime.tryParse(
      event['throughCreatedAt']?.toString() ?? '',
    );
    if (id == null || through == null || messages[id] == null) return;
    messages[id] = messages[id]!.map((message) {
      if (message.sentBy(user?.id ?? '') &&
          !message.createdAt.isAfter(through)) {
        return message.copyWith(status: status);
      }
      return message;
    }).toList();
    notifyListeners();
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    unawaited(_webSocketSubscription?.cancel());
    unawaited(_webSocket?.sink.close());
    unawaited(_sipSubscription.cancel());
    unawaited(sip.dispose());
    super.dispose();
  }
}
