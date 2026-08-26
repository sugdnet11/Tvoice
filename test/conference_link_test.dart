import 'package:flutter_test/flutter_test.dart';
import 'package:tvoice_flutter/src/services/android_platform_bridge.dart';

void main() {
  test('conference app link returns its invite token', () {
    final token = ConferenceLink.inviteToken(
      Uri.parse('tvoice://conference/join?token=abc-123'),
    );

    expect(token, 'abc-123');
  });

  test('unrelated links are ignored', () {
    expect(
      ConferenceLink.inviteToken(Uri.parse('https://example.com/abc-123')),
      isNull,
    );
    expect(
      ConferenceLink.inviteToken(Uri.parse('tvoice://conference/join')),
      isNull,
    );
  });
}
