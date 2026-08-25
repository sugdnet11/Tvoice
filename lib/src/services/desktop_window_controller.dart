import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum DesktopWindowMode { splash, login, main }

abstract final class DesktopWindowController {
  static const MethodChannel _channel = MethodChannel('tvoice/window');
  static final StreamController<Uri> _links = StreamController<Uri>.broadcast();
  static Uri? _pendingLink;

  static DesktopWindowMode? _lastMode;

  static Stream<Uri> get links => _links.stream;

  static void initializeDeepLinks(List<String> arguments) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onDeepLink' && call.arguments is String) {
        _acceptLink(call.arguments as String);
      }
    });
    for (final value in arguments) {
      if (value.startsWith('tvoice://')) _acceptLink(value);
    }
  }

  static Uri? takePendingLink() {
    final value = _pendingLink;
    _pendingLink = null;
    return value;
  }

  static void keepPendingLink(Uri uri) {
    if (uri.scheme == 'tvoice') _pendingLink = uri;
  }

  static void _acceptLink(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'tvoice') return;
    _pendingLink = uri;
    _links.add(uri);
  }

  static Future<void> show(DesktopWindowMode mode) async {
    if (defaultTargetPlatform != TargetPlatform.windows || _lastMode == mode) {
      return;
    }
    _lastMode = mode;
    await _channel.invokeMethod<void>('setWindowMode', mode.name);
  }

  static Future<void> setFullscreen(bool enabled) async {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await _channel.invokeMethod<void>('setFullscreen', enabled);
    }
  }
}
