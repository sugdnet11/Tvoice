import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

class StoredSession {
  const StoredSession({
    required this.sipNumber,
    required this.password,
    required this.accessToken,
  });

  final String sipNumber;
  final String password;
  final String accessToken;
}

class SessionStore {
  static const _sipKey = 'session.sipNumber';
  static const _passwordKey = 'session.password';
  static const _tokenKey = 'session.accessToken';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  String _historyKey(String sipNumber) => 'calls.history.$sipNumber';
  String _favoriteCallsKey(String sipNumber) =>
      'calls.favoriteNumbers.$sipNumber';
  String _desktopSectionKey(String sipNumber) =>
      'desktop.lastSection.$sipNumber';

  Future<StoredSession?> read() async {
    final values = await _storage.readAll();
    final sip = values[_sipKey];
    final password = values[_passwordKey];
    final token = values[_tokenKey];
    if (sip == null || password == null || token == null) return null;
    return StoredSession(
      sipNumber: sip,
      password: password,
      accessToken: token,
    );
  }

  Future<void> write(StoredSession session) async {
    await Future.wait([
      _storage.write(key: _sipKey, value: session.sipNumber),
      _storage.write(key: _passwordKey, value: session.password),
      _storage.write(key: _tokenKey, value: session.accessToken),
    ]);
  }

  Future<void> clear() => _storage.deleteAll();

  Future<List<CallHistoryEntry>> readCallHistory(String sipNumber) async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_historyKey(sipNumber));
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(CallHistoryEntry.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> writeCallHistory(
    String sipNumber,
    List<CallHistoryEntry> entries,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _historyKey(sipNumber),
      jsonEncode(entries.take(250).map((entry) => entry.toJson()).toList()),
    );
  }

  Future<Set<String>> readFavoriteCallNumbers(String sipNumber) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getStringList(_favoriteCallsKey(sipNumber))?.toSet() ??
        <String>{};
  }

  Future<void> writeFavoriteCallNumbers(
    String sipNumber,
    Set<String> numbers,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final sorted = numbers.toList()..sort();
    await preferences.setStringList(_favoriteCallsKey(sipNumber), sorted);
  }

  Future<String?> readDesktopSection(String sipNumber) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_desktopSectionKey(sipNumber));
  }

  Future<void> writeDesktopSection(String sipNumber, String section) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_desktopSectionKey(sipNumber), section);
  }
}
