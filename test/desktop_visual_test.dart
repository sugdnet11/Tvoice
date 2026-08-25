import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvoice_flutter/src/controllers/app_controller.dart';
import 'package:tvoice_flutter/src/app.dart';
import 'package:tvoice_flutter/src/models/models.dart';
import 'package:tvoice_flutter/src/screens/login_screen.dart';
import 'package:tvoice_flutter/src/screens/windows_home_shell.dart';
import 'package:tvoice_flutter/src/services/api_client.dart';
import 'package:tvoice_flutter/src/services/session_store.dart';
import 'package:tvoice_flutter/src/services/sip_bridge.dart';
import 'package:tvoice_flutter/src/theme/desktop_design.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('desktop splash reference screenshot', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await _loadGoldenFonts();
    await tester.binding.setSurfaceSize(const Size(560, 340));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: tvoiceDesktopTheme(Brightness.light),
        home: const DesktopSplashScreen(),
      ),
    );
    debugDefaultTargetPlatformOverride = null;
    await expectLater(
      find.byType(DesktopSplashScreen),
      matchesGoldenFile('goldens/tvoice-desktop-splash.png'),
    );
  });

  testWidgets('desktop login reference screenshot', (tester) async {
    await _loadGoldenFonts();
    await tester.binding.setSurfaceSize(const Size(520, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _controller()..user = null;
    controller.api.accessToken = null;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: tvoiceDesktopTheme(Brightness.light),
        home: LoginScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(LoginScreen),
      matchesGoldenFile('goldens/tvoice-desktop-login.png'),
    );
  });

  testWidgets('desktop account menu reference screenshot', (tester) async {
    await _loadGoldenFonts();
    await tester.binding.setSurfaceSize(const Size(1120, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: tvoiceDesktopTheme(Brightness.light),
        home: WindowsHomeShell(controller: controller),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('desktop-account-button')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(WindowsHomeShell),
      matchesGoldenFile('goldens/tvoice-desktop-account-menu.png'),
    );
  });

  testWidgets('desktop calls reference screenshot', (tester) async {
    await _loadGoldenFonts();
    await tester.binding.setSurfaceSize(const Size(1120, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: tvoiceDesktopTheme(Brightness.light),
        home: WindowsHomeShell(controller: controller),
      ),
    );
    await tester.tap(find.byTooltip('Звонки'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(WindowsHomeShell),
      matchesGoldenFile('goldens/tvoice-desktop-calls.png'),
    );
  });

  testWidgets('desktop chat reference screenshot', (tester) async {
    await _loadGoldenFonts();
    await tester.binding.setSurfaceSize(const Size(1120, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: tvoiceDesktopTheme(Brightness.light),
        home: WindowsHomeShell(controller: controller),
      ),
    );
    await tester.tap(find.byTooltip('Чаты'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(WindowsHomeShell),
      matchesGoldenFile('goldens/tvoice-desktop-chat.png'),
    );
  });

  testWidgets('desktop dialer reference screenshot', (tester) async {
    await _loadGoldenFonts();
    await tester.binding.setSurfaceSize(const Size(1120, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: tvoiceDesktopTheme(Brightness.light),
        home: WindowsHomeShell(controller: controller),
      ),
    );
    await tester.tap(find.byTooltip('Набор номера'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(WindowsHomeShell),
      matchesGoldenFile('goldens/tvoice-desktop-dialer.png'),
    );
  });

  testWidgets('desktop contacts reference screenshot', (tester) async {
    await _loadGoldenFonts();
    await tester.binding.setSurfaceSize(const Size(1120, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: tvoiceDesktopTheme(Brightness.light),
        home: WindowsHomeShell(controller: controller),
      ),
    );
    await tester.tap(find.byTooltip('Контакты'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(WindowsHomeShell),
      matchesGoldenFile('goldens/tvoice-desktop-contacts.png'),
    );
  });

  testWidgets('desktop conferences reference screenshot', (tester) async {
    await _loadGoldenFonts();
    await tester.binding.setSurfaceSize(const Size(1120, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: tvoiceDesktopTheme(Brightness.light),
        home: WindowsHomeShell(controller: controller),
      ),
    );
    await tester.tap(find.byTooltip('Конференции'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(WindowsHomeShell),
      matchesGoldenFile('goldens/tvoice-desktop-conferences.png'),
    );
  });
}

Future<void> _loadGoldenFonts() async {
  final inter = FontLoader('Inter')
    ..addFont(rootBundle.load('assets/fonts/Inter-Variable.ttf'));
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
  await Future.wait([inter.load(), icons.load()]);
}

AppController _controller() {
  final peer = const TvoiceUser(
    id: 'peer-70007',
    sipNumber: '70007',
    displayName: 'Абдулло',
  );
  // Golden fixtures must not depend on the calendar day of the test runner.
  final now = DateTime(2026, 8, 24, 11, 39);
  final api = ApiClient(
    client: MockClient((request) async {
      if (request.method == 'GET' &&
          request.url.path.endsWith('/conferences')) {
        return http.Response(
          jsonEncode({
            'conferences': [
              {
                'id': '11111111-1111-4111-8111-111111111111',
                'title': 'Еженедельное совещание',
                'inviteUrl': 'https://web-pwa.sugdnet11.chatgpt.site/conference/join/demo',
                'createdAt': now
                    .subtract(const Duration(days: 1))
                    .toIso8601String(),
                'allowGuests': true,
                'active': true,
              },
              {
                'id': '22222222-2222-4222-8222-222222222222',
                'title': 'Переговорная отдела продаж',
                'inviteUrl': 'https://web-pwa.sugdnet11.chatgpt.site/conference/join/team',
                'createdAt': now
                    .subtract(const Duration(days: 3))
                    .toIso8601String(),
                'allowGuests': true,
                'active': true,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path.endsWith('/messages')) {
        return http.Response(
          jsonEncode({
            'messages': [
              {
                'id': 'm1',
                'conversationId': 'conversation-1',
                'sender': {
                  'id': peer.id,
                  'sipNumber': peer.sipNumber,
                  'displayName': peer.displayName,
                },
                'body': 'Добрый день!',
                'createdAt': now
                    .subtract(const Duration(minutes: 4))
                    .toIso8601String(),
                'status': 'received',
              },
              {
                'id': 'm2',
                'conversationId': 'conversation-1',
                'sender': {
                  'id': 'me',
                  'sipNumber': '73302',
                  'displayName': '73302',
                },
                'body': 'Напоминаю, созвон в 15:00',
                'createdAt': now.toIso8601String(),
                'status': 'read',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    }),
  )..accessToken = 'visual-test';
  return AppController(api: api, sessionStore: SessionStore(), sip: SipBridge())
    ..user = const TvoiceUser(
      id: 'me',
      sipNumber: '73302',
      displayName: '73302',
    )
    ..contacts = [
      peer,
      const TvoiceUser(
        id: 'peer-70012',
        sipNumber: '70012',
        displayName: 'Мадина',
      ),
      const TvoiceUser(
        id: 'peer-70023',
        sipNumber: '70023',
        displayName: 'Нозим',
      ),
      const TvoiceUser(
        id: 'peer-70008',
        sipNumber: '70008',
        displayName: 'Анвар',
      ),
    ]
    ..conversations = [
      Conversation(
        id: 'conversation-1',
        peer: peer,
        lastMessage: ChatMessage(
          id: 'preview-1',
          conversationId: 'conversation-1',
          body: 'Напоминаю, созвон в 15:00',
          createdAt: now,
          sender: peer,
        ),
      ),
      const Conversation(
        id: 'conversation-2',
        peer: TvoiceUser(
          id: 'peer-70012',
          sipNumber: '70012',
          displayName: 'Мадина',
        ),
      ),
      const Conversation(
        id: 'conversation-3',
        peer: TvoiceUser(
          id: 'peer-70023',
          sipNumber: '70023',
          displayName: 'Нозим',
        ),
      ),
    ]
    ..callHistory = [
      _call(
        'call-1',
        '70007',
        now.subtract(const Duration(minutes: 6)),
        const Duration(minutes: 5, seconds: 12),
      ),
      _call(
        'call-2',
        '70012',
        now.subtract(const Duration(hours: 1)),
        const Duration(minutes: 2, seconds: 48),
      ),
      _call(
        'call-3',
        '70023',
        now.subtract(const Duration(hours: 2)),
        Duration.zero,
        missed: true,
      ),
      _call(
        'call-4',
        '70008',
        now.subtract(const Duration(days: 1)),
        const Duration(minutes: 3, seconds: 21),
      ),
    ]
    ..favoriteCallNumbers = {'70007'};
}

CallHistoryEntry _call(
  String id,
  String number,
  DateTime started,
  Duration duration, {
  bool missed = false,
}) => CallHistoryEntry(
  id: id,
  number: number,
  direction: missed ? CallDirection.incoming : CallDirection.outgoing,
  media: CallMedia.video,
  result: missed ? CallResult.missed : CallResult.completed,
  startedAt: started,
  connectedAt: missed ? null : started,
  endedAt: missed ? started : started.add(duration),
);
