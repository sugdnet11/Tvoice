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
}
