import 'package:flutter_test/flutter_test.dart';
import 'package:tvoice_flutter/src/models/models.dart';

void main() {
  test('message status is decoded from the chat API', () {
    final message = ChatMessage.fromJson({
      'id': '42',
      'conversationId': 'test',
      'body': 'Салом',
      'createdAt': '2026-08-18T09:00:00Z',
      'status': 'read',
    });

    expect(message.status, MessageStatus.read);
    expect(message.body, 'Салом');
  });

  test('call history survives JSON persistence with duration', () {
    final original = CallHistoryEntry(
      id: 'sip-1',
      number: '75566',
      direction: CallDirection.incoming,
      media: CallMedia.audio,
      result: CallResult.completed,
      startedAt: DateTime.utc(2026, 8, 19, 10),
      connectedAt: DateTime.utc(2026, 8, 19, 10, 0, 4),
      endedAt: DateTime.utc(2026, 8, 19, 10, 2, 9),
    );

    final restored = CallHistoryEntry.fromJson(original.toJson());

    expect(restored.number, '75566');
    expect(restored.direction, CallDirection.incoming);
    expect(restored.result, CallResult.completed);
    expect(restored.duration, const Duration(minutes: 2, seconds: 5));
  });
}
