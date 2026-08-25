import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

enum SipRegistrationState { unavailable, connecting, registered, failed }

enum SipCallState {
  idle,
  incoming,
  outgoing,
  ringing,
  connected,
  paused,
  ended,
  error,
}

class SipEvent {
  const SipEvent({
    required this.type,
    this.registrationState,
    this.callState,
    this.remoteNumber = '',
    this.message = '',
    this.connectedAt,
  });

  final String type;
  final SipRegistrationState? registrationState;
  final SipCallState? callState;
  final String remoteNumber;
  final String message;
  final DateTime? connectedAt;
}

/// One Dart contract for the platform-native SIP engines.
class SipBridge {
  static const MethodChannel _channel = MethodChannel('tj.tvoice/sip');
  static const EventChannel _events = EventChannel('tj.tvoice/sip_events');

  final StreamController<SipEvent> _windowsEvents =
      StreamController<SipEvent>.broadcast();
  final Map<int, Completer<dynamic>> _windowsRequests = {};
  Process? _windowsProcess;
  StreamSubscription<String>? _windowsOutput;
  int _nextRequestId = 0;

  Stream<SipEvent> get events => Platform.isWindows
      ? _windowsEvents.stream
      : _events.receiveBroadcastStream().map((raw) {
          final event = Map<String, dynamic>.from(raw as Map);
          if (event['type'] == 'snapshot') {
            final value = Map<String, dynamic>.from(event['value'] as Map);
            return _callEvent(value, type: 'snapshot');
          }
          return _parseEvent(event);
        });

  Future<SipRegistrationState> register({
    required String number,
    required String password,
    required String host,
    required int port,
  }) async {
    if (Platform.isWindows) {
      try {
        final ok = await _invokeWindows('register', {
          'number': number,
          'password': password,
          'host': host,
          'port': port,
          'transport': 'udp',
        });
        return ok == true
            ? SipRegistrationState.connecting
            : SipRegistrationState.failed;
      } catch (_) {
        return SipRegistrationState.failed;
      }
    }
    try {
      final ok = await _channel.invokeMethod<bool>('register', {
        'number': number,
        'password': password,
        'host': host,
        'port': port,
        'transport': 'udp',
      });
      return ok == true
          ? SipRegistrationState.registered
          : SipRegistrationState.failed;
    } on MissingPluginException {
      return SipRegistrationState.unavailable;
    } on PlatformException {
      return SipRegistrationState.failed;
    }
  }

  Future<void> call(String number) => _invoke('call', {'number': number});
  Future<void> answer() => _invoke('answer');
  Future<void> reject() => _invoke('reject');
  Future<void> hangup() => _invoke('hangup');
  Future<void> unregister() => _invoke('unregister');
  Future<void> setMuted(bool muted) => _invoke('setMuted', {'muted': muted});
  Future<void> setSpeaker(bool enabled) =>
      _invoke('setSpeaker', {'enabled': enabled});
  Future<void> setHeld(bool held) => _invoke('setHeld', {'held': held});

  Future<void> _invoke(String method, [Map<String, dynamic>? arguments]) async {
    if (Platform.isWindows) {
      await _invokeWindows(method, arguments);
      return;
    }
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // The shared UI remains usable while the platform SIP module is being
      // migrated. Registration state already exposes this as unavailable.
    }
  }

  Future<dynamic> _invokeWindows(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    await _ensureWindowsProcess();
    final process = _windowsProcess;
    if (process == null) throw StateError('Windows SIP bridge is unavailable');
    final id = ++_nextRequestId;
    final completer = Completer<dynamic>();
    _windowsRequests[id] = completer;
    process.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'arguments': arguments ?? {}}),
    );
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _windowsRequests.remove(id);
        throw TimeoutException('Windows SIP bridge did not respond');
      },
    );
  }

  Future<void> _ensureWindowsProcess() async {
    if (_windowsProcess != null) return;
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final path =
        '$executableDirectory${Platform.pathSeparator}'
        'sip_bridge${Platform.pathSeparator}tvoice_sip_bridge.exe';
    final process = await Process.start(path, const [], runInShell: false);
    _windowsProcess = process;
    _windowsOutput = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleWindowsLine);
    unawaited(
      process.exitCode.then((_) {
        _windowsProcess = null;
        for (final request in _windowsRequests.values) {
          if (!request.isCompleted) {
            request.completeError(StateError('Windows SIP bridge stopped'));
          }
        }
        _windowsRequests.clear();
        if (!_windowsEvents.isClosed) {
          _windowsEvents.add(
            const SipEvent(
              type: 'registration',
              registrationState: SipRegistrationState.unavailable,
              message: 'Модуль SIP Windows остановлен',
            ),
          );
        }
      }),
    );
  }

  void _handleWindowsLine(String line) {
    try {
      final value = Map<String, dynamic>.from(jsonDecode(line) as Map);
      final id = value['id'];
      if (id is num) {
        final request = _windowsRequests.remove(id.toInt());
        if (request == null) return;
        if (value['ok'] == true) {
          request.complete(value['result']);
        } else {
          request.completeError(
            StateError(value['error']?.toString() ?? 'SIP error'),
          );
        }
        return;
      }
      _windowsEvents.add(_parseEvent(value));
    } catch (_) {
      // Ignore malformed helper output and keep the SIP process alive.
    }
  }

  Future<void> dispose() async {
    if (Platform.isWindows && _windowsProcess != null) {
      try {
        await _invokeWindows('shutdown').timeout(const Duration(seconds: 2));
      } catch (_) {
        _windowsProcess?.kill();
      }
    }
    await _windowsOutput?.cancel();
    await _windowsEvents.close();
  }

  static SipEvent _parseEvent(Map<String, dynamic> event) {
    if (event['type'] == 'registration') {
      return SipEvent(
        type: 'registration',
        registrationState: _registrationState(event['state']),
        message: event['message']?.toString() ?? '',
      );
    }
    return _callEvent(event);
  }

  static SipEvent _callEvent(
    Map<String, dynamic> event, {
    String type = 'call',
  }) {
    final millis = event['connectedAtMillis'];
    return SipEvent(
      type: type,
      registrationState: event['registrationState'] == null
          ? null
          : _registrationState(event['registrationState']),
      callState: _callState(event['callState'] ?? event['state']),
      remoteNumber: event['remoteNumber']?.toString() ?? '',
      message: (event['callMessage'] ?? event['message'])?.toString() ?? '',
      connectedAt: millis is num
          ? DateTime.fromMillisecondsSinceEpoch(millis.toInt())
          : null,
    );
  }

  static SipRegistrationState _registrationState(dynamic raw) =>
      switch (raw?.toString()) {
        'Progress' => SipRegistrationState.connecting,
        'Ok' => SipRegistrationState.registered,
        'Failed' => SipRegistrationState.failed,
        _ => SipRegistrationState.unavailable,
      };

  static SipCallState _callState(dynamic raw) => switch (raw?.toString()) {
    'IncomingReceived' => SipCallState.incoming,
    'OutgoingInit' || 'OutgoingProgress' => SipCallState.outgoing,
    'OutgoingRinging' => SipCallState.ringing,
    'Connected' || 'StreamsRunning' => SipCallState.connected,
    'Paused' => SipCallState.paused,
    'End' || 'Released' => SipCallState.ended,
    'Error' => SipCallState.error,
    _ => SipCallState.idle,
  };
}
