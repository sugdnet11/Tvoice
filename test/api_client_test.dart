import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tvoice_flutter/src/models/models.dart';
import 'package:tvoice_flutter/src/services/api_client.dart';

void main() {
  test('video call fails clearly when invite was not delivered', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/v1/video/calls') {
          return http.Response(
            jsonEncode({'callId': 'call-1', 'delivered': false}),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/v1/video/calls/call-1/end') {
          return http.Response('', 204);
        }
        return http.Response(jsonEncode({'error': 'not_found'}), 404);
      }),
    )..accessToken = 'test-token';

    await expectLater(
      api.startVideoCall('77770'),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          'Абонент сейчас не подключён к видеозвонкам',
        ),
      ),
    );

    expect(requests.map((request) => request.url.path), [
      '/v1/video/calls',
      '/v1/video/calls/call-1/end',
    ]);
    expect(requests.last.headers.containsKey('content-type'), isFalse);
    expect(requests.last.body, isEmpty);
  });

  test('answer request has no JSON content type when body is empty', () async {
    late http.Request answerRequest;
    final api = ApiClient(
      client: MockClient((request) async {
        answerRequest = request;
        return http.Response(
          jsonEncode({'url': 'wss://video.example.test', 'token': 'token'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..accessToken = 'test-token';
    final call = VideoCallSession(
      callId: 'call-2',
      peer: const TvoiceUser(
        id: 'peer-id',
        sipNumber: '73302',
        displayName: '73302',
      ),
      incoming: true,
    );

    final answered = await api.answerVideoCall(call);

    expect(answered.isReady, isTrue);
    expect(answerRequest.url.path, '/v1/video/calls/call-2/answer');
    expect(answerRequest.headers.containsKey('content-type'), isFalse);
    expect(answerRequest.body, isEmpty);
  });

  test('persistent conference room is created without auto-joining', () async {
    late http.Request createRequest;
    final api = ApiClient(
      client: MockClient((request) async {
        createRequest = request;
        return http.Response(
          jsonEncode({
            'conference': {
              'id': 'room-1',
              'title': 'Команда',
              'inviteUrl': 'https://chat.example/conference/join/token-1',
              'createdAt': '2026-08-26T08:00:00Z',
              'allowGuests': true,
              'active': true,
            },
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..accessToken = 'test-token';

    final room = await api.createConferenceRoom(
      title: 'Команда',
      allowGuests: true,
    );

    expect(createRequest.method, 'POST');
    expect(createRequest.url.path, '/v1/conferences');
    expect(jsonDecode(createRequest.body), {
      'title': 'Команда',
      'allowGuests': true,
      'cameraEnabled': true,
      'microphoneEnabled': true,
    });
    expect(room.id, 'room-1');
    expect(room.inviteUrl, endsWith('/token-1'));
  });

  test('saved conference room can be joined and revoked', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/v1/conferences/room-1/join') {
          return http.Response(
            jsonEncode({
              'conference': {
                'id': 'room-1',
                'title': 'Команда',
                'role': 'organizer',
                'url': 'wss://video.example',
                'token': 'livekit-token',
                'inviteUrl': 'https://chat.example/conference/join/token-1',
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 204);
      }),
    )..accessToken = 'test-token';
    const user = TvoiceUser(
      id: 'user-1',
      sipNumber: '73302',
      displayName: '73302',
    );

    final session = await api.openConferenceRoom('room-1', user);
    await api.revokeConferenceRoom('room-1');

    expect(session.isConferenceRoom, isTrue);
    expect(session.isReady, isTrue);
    expect(session.role, 'organizer');
    expect(requests.map((request) => request.url.path), [
      '/v1/conferences/room-1/join',
      '/v1/conferences/room-1/revoke',
    ]);
  });
}
