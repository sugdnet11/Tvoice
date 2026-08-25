// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import 'src/app.dart';
import 'src/controllers/app_controller.dart';
import 'src/services/api_client.dart';
import 'src/services/session_store.dart';
import 'src/services/sip_bridge.dart';
import 'src/services/desktop_window_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    DesktopWindowController.initializeDeepLinks(Platform.executableArguments);
  }
  // LiveKit marks explicit session policy as experimental, but applying the
  // communication profile before WebRTC starts is required for Android audio.
  await LiveKitClient.initialize(
    initialAudioSessionOptions: const AudioSessionOptions.communication(),
  );
  final controller = AppController(
    api: ApiClient(),
    sessionStore: SessionStore(),
    sip: SipBridge(),
  );
  unawaited(controller.restoreSession());
  runApp(TvoiceApp(controller: controller));
}
