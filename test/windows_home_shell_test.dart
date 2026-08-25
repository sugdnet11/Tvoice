import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvoice_flutter/src/controllers/app_controller.dart';
import 'package:tvoice_flutter/src/models/models.dart';
import 'package:tvoice_flutter/src/screens/windows_home_shell.dart';
import 'package:tvoice_flutter/src/services/api_client.dart';
import 'package:tvoice_flutter/src/services/session_store.dart';
import 'package:tvoice_flutter/src/services/sip_bridge.dart';

void main() {
  testWidgets('desktop shell has split navigation and working call filters', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1180, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/messages')) {
          return http.Response(jsonEncode({'messages': <dynamic>[]}), 200);
        }
        return http.Response('{}', 200);
      }),
    )..accessToken = 'test-token';
    final controller =
        AppController(api: api, sessionStore: SessionStore(), sip: SipBridge())
          ..user = const TvoiceUser(
            id: 'me',
            sipNumber: '73302',
            displayName: '73302',
          )
          ..contacts = const [
            TvoiceUser(
              id: 'contact-1',
              sipNumber: '75566',
              displayName: 'Абонент 75566',
            ),
          ]
          ..conversations = const [
            Conversation(
              id: 'conversation-1',
              peer: TvoiceUser(
                id: 'contact-1',
                sipNumber: '75566',
                displayName: 'Абонент 75566',
              ),
            ),
          ]
          ..callHistory = [
            CallHistoryEntry(
              id: 'completed',
              number: '75566',
              direction: CallDirection.outgoing,
              media: CallMedia.audio,
              result: CallResult.completed,
              startedAt: DateTime(2026, 8, 20, 10),
              connectedAt: DateTime(2026, 8, 20, 10),
              endedAt: DateTime(2026, 8, 20, 10, 1),
            ),
            CallHistoryEntry(
              id: 'missed',
              number: '78088',
              direction: CallDirection.incoming,
              media: CallMedia.audio,
              result: CallResult.missed,
              startedAt: DateTime(2026, 8, 20, 11),
            ),
          ]
          ..favoriteCallNumbers = {'75566'};
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WindowsHomeShell(controller: controller)),
    );

    expect(find.byType(WindowsHomeShell), findsOneWidget);
    expect(find.byTooltip('Главная'), findsNothing);
    expect(find.byTooltip('Контакты'), findsOneWidget);
    expect(find.byTooltip('Конференции'), findsOneWidget);
    expect(find.byTooltip('Настройки'), findsNothing);
    expect(find.byTooltip('Помощь'), findsNothing);
    expect(find.byTooltip('Свернуть меню'), findsNothing);
    expect(
      find.byKey(const ValueKey('desktop-account-button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('desktop-account-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-account-menu')), findsOneWidget);
    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('Добавить аккаунт'), findsOneWidget);
    expect(find.text('Выйти'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-account-menu')), findsNothing);

    await tester.tap(find.byTooltip('Контакты'));
    await tester.pumpAndSettle();
    expect(find.text('Абонент 75566'), findsWidgets);

    await tester.tap(find.byTooltip('Звонки'));
    await tester.pumpAndSettle();
    expect(find.text('Все'), findsOneWidget);
    expect(find.text('Пропущенные'), findsOneWidget);
    expect(find.text('Избранные'), findsOneWidget);

    await tester.tap(find.text('Пропущенные'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('call-row-missed')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-row-completed')), findsNothing);

    await tester.tap(find.text('Избранные'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('call-row-completed')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-row-missed')), findsNothing);

    await tester.tap(find.byTooltip('Чаты'));
    await tester.pumpAndSettle();
    expect(find.text('Поиск чатов'), findsOneWidget);
    expect(find.text('Сообщение'), findsOneWidget);
  });
}
