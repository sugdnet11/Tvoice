import 'package:flutter/services.dart';

abstract final class AndroidPlatformBridge {
  static const _channel = MethodChannel('tj.tvoice.app/platform');
  static Future<void> Function(Uri uri)? _linkHandler;

  static Future<void> initialize({
    required Future<void> Function(Uri uri) onLink,
  }) async {
    _linkHandler = onLink;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'link') return;
      final raw = call.arguments?.toString();
      final uri = raw == null ? null : Uri.tryParse(raw);
      if (uri != null) await _linkHandler?.call(uri);
    });
    try {
      final raw = await _channel.invokeMethod<String>('initialLink');
      final uri = raw == null ? null : Uri.tryParse(raw);
      if (uri != null) await _linkHandler?.call(uri);
    } on MissingPluginException {
      // The bridge is Android-only. Tests and other platforms have no plugin.
    }
  }

  static void dispose() {
    _linkHandler = null;
    _channel.setMethodCallHandler(null);
  }

  static Future<bool> shareText({
    required String text,
    String title = 'Поделиться через',
  }) async {
    try {
      return await _channel.invokeMethod<bool>('shareText', {
            'text': text,
            'title': title,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}

abstract final class ConferenceLink {
  static String? inviteToken(Uri uri) {
    if (uri.scheme != 'tvoice' ||
        uri.host != 'conference' ||
        uri.path != '/join') {
      return null;
    }
    final token = uri.queryParameters['token']?.trim();
    return token == null || token.isEmpty ? null : token;
  }
}
