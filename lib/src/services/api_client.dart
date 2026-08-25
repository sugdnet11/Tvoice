import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/app_config.dart';
import '../models/models.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class LoginResult {
  const LoginResult({required this.accessToken, required this.user});
  final String accessToken;
  final TvoiceUser user;
}

class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  String? accessToken;

  Map<String, String> _headers({required bool hasJsonBody}) => {
    'accept': 'application/json',
    if (hasJsonBody) 'content-type': 'application/json',
    if (accessToken != null) 'authorization': 'Bearer $accessToken',
  };

  Future<LoginResult> login(String sipNumber, String password) async {
    final data = await _request(
      'POST',
      '/v1/auth/login',
      body: {'sipNumber': sipNumber, 'password': password},
      authenticated: false,
    );
    final token = data['accessToken']?.toString() ?? '';
    accessToken = token;
    return LoginResult(
      accessToken: token,
      user: TvoiceUser.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  Future<TvoiceUser> me() async {
    final data = await _request('GET', '/v1/me');
    return TvoiceUser.fromJson(data['user'] as Map<String, dynamic>);
  }

  Future<List<TvoiceUser>> contacts() async {
    final data = await _request('GET', '/v1/contacts');
    return (data['contacts'] as List<dynamic>? ?? const [])
        .map((item) => TvoiceUser.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<Conversation>> conversations() async {
    final data = await _request('GET', '/v1/conversations');
    return (data['conversations'] as List<dynamic>? ?? const [])
        .map((item) => Conversation.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<Conversation> directConversation(String peerSipNumber) async {
    final data = await _request(
      'POST',
      '/v1/conversations/direct',
      body: {'peerSipNumber': peerSipNumber},
    );
    return Conversation.fromJson(data['conversation'] as Map<String, dynamic>);
  }

  Future<List<ChatMessage>> messages(String conversationId) async {
    final data = await _request(
      'GET',
      '/v1/conversations/$conversationId/messages',
      query: {'limit': '100'},
    );
    return (data['messages'] as List<dynamic>? ?? const [])
        .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<ChatMessage> sendMessage(String conversationId, String body) async {
    final data = await _request(
      'POST',
      '/v1/conversations/$conversationId/messages',
      body: {'body': body},
    );
    return ChatMessage.fromJson(data['message'] as Map<String, dynamic>);
  }

  Future<void> markRead(String conversationId) async {
    await _request('POST', '/v1/conversations/$conversationId/read');
  }

  Future<VideoCallSession> startVideoCall(String peerSipNumber) async {
    final data = await _request(
      'POST',
      '/v1/video/calls',
      body: {'peerSipNumber': peerSipNumber},
    );
    if (data['delivered'] == false) {
      final callId = data['callId']?.toString();
      if (callId != null && callId.isNotEmpty) {
        try {
          await endVideoCall(callId);
        } catch (_) {
          // The important outcome is that the caller is not left in an empty
          // room. Server cleanup can still happen by call expiry.
        }
      }
      throw const ApiException('Абонент сейчас не подключён к видеозвонкам');
    }
    return VideoCallSession.outgoing(data);
  }

  Future<VideoCallSession> answerVideoCall(VideoCallSession call) async {
    final data = await _request(
      'POST',
      '/v1/video/calls/${call.callId}/answer',
    );
    return call.answered(data);
  }

  Future<void> endVideoCall(String callId, {bool reject = false}) async {
    await _request(
      'POST',
      '/v1/video/calls/$callId/${reject ? 'reject' : 'end'}',
    );
  }

  Future<VideoCallSession> createConference({
    required TvoiceUser localUser,
    required String title,
    required bool allowGuests,
    required bool cameraEnabled,
    required bool microphoneEnabled,
  }) async {
    final data = await _request(
      'POST',
      '/v1/conferences',
      body: {
        'title': title,
        'allowGuests': allowGuests,
        'cameraEnabled': cameraEnabled,
        'microphoneEnabled': microphoneEnabled,
      },
    );
    return VideoCallSession.conference(
      data['conference'] as Map<String, dynamic>,
      localUser,
    );
  }

  Future<List<ConferenceRoom>> conferenceRooms() async {
    final data = await _request('GET', '/v1/conferences');
    return (data['conferences'] as List<dynamic>? ?? const [])
        .map((item) => ConferenceRoom.fromJson(item as Map<String, dynamic>))
        .where((room) => room.id.isNotEmpty && room.active)
        .toList();
  }

  Future<ConferenceRoom> createConferenceRoom({
    required String title,
    required bool allowGuests,
  }) async {
    final data = await _request(
      'POST',
      '/v1/conferences',
      body: {
        'title': title,
        'allowGuests': allowGuests,
        'cameraEnabled': true,
        'microphoneEnabled': true,
      },
    );
    return ConferenceRoom.fromJson(data['conference'] as Map<String, dynamic>);
  }

  Future<VideoCallSession> openConferenceRoom(
    String conferenceId,
    TvoiceUser localUser,
  ) async {
    final data = await _request(
      'POST',
      '/v1/conferences/${Uri.encodeComponent(conferenceId)}/join',
    );
    return VideoCallSession.conference(
      data['conference'] as Map<String, dynamic>,
      localUser,
    );
  }

  Future<void> revokeConferenceRoom(String conferenceId) async {
    await _request(
      'POST',
      '/v1/conferences/${Uri.encodeComponent(conferenceId)}/revoke',
    );
  }

  Future<void> endConference(String conferenceId) async {
    await _request('POST', '/v1/conferences/$conferenceId/end');
  }

  Future<VideoCallSession> joinConference(
    String inviteToken,
    TvoiceUser localUser,
  ) async {
    final data = await _request(
      'POST',
      '/v1/conferences/invitations/${Uri.encodeComponent(inviteToken)}/join',
    );
    return VideoCallSession.conference(
      data['conference'] as Map<String, dynamic>,
      localUser,
    );
  }

  Future<Map<String, dynamic>> conferenceInvitation(String inviteToken) async {
    final data = await _request(
      'GET',
      '/v1/conferences/invitations/${Uri.encodeComponent(inviteToken)}',
      authenticated: false,
    );
    return data['conference'] as Map<String, dynamic>;
  }

  Future<VideoCallSession> guestJoinConference(
    String inviteToken,
    String displayName,
  ) async {
    final data = await _request(
      'POST',
      '/v1/conferences/invitations/${Uri.encodeComponent(inviteToken)}/guest-join',
      body: {'displayName': displayName},
      authenticated: false,
    );
    return VideoCallSession.conference(
      data['conference'] as Map<String, dynamic>,
      TvoiceUser(id: 'guest', sipNumber: '', displayName: displayName),
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    bool authenticated = true,
  }) async {
    if (authenticated && accessToken == null) {
      throw const ApiException('Сеанс авторизации завершён');
    }
    final uri = AppConfig.api(path, query);
    final response = switch (method) {
      'GET' => await _client.get(uri, headers: _headers(hasJsonBody: false)),
      'POST' => await _client.post(
        uri,
        headers: _headers(hasJsonBody: body != null),
        body: body == null ? null : jsonEncode(body),
      ),
      _ => throw ApiException('Unsupported HTTP method: $method'),
    };
    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        _friendlyError(decoded['error']?.toString()),
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  String _friendlyError(String? code) => switch (code) {
    'invalid_credentials' => 'Неверный номер или пароль',
    'auth_provider_unavailable' => 'FreePBX временно недоступен',
    'contact_not_found' => 'Абонент не найден',
    'video_unavailable' => 'Сервер видеосвязи временно недоступен',
    'call_not_found' => 'Вызов уже завершён',
    'conference_not_found' => 'Комната не найдена или уже аннулирована',
    'conference_service_unavailable' =>
      'Сервер конференций временно недоступен',
    _ => 'Ошибка сервера. Попробуйте ещё раз',
  };
}
