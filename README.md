# Tvoice for Android

**Версия:** 0.17.10+32  
**Статус:** Release Candidate — исходники и тестовая сборка проверяются; production Release публикуется только после подтверждения сертификата подписи.  
**Последняя проверка:** 25 августа 2026 года  
**Скачать последнюю версию:** публикация APK/AAB ожидает настройку production signing в GitHub Secrets.

Android-клиент Tvoice для SIP-аудиозвонков, видеосвязи, конференций, контактов,
истории вызовов и чата. `applicationId`: `tj.tvoice.app`.

## Основные функции

- единый вход в FreePBX и чат;
- входящие и исходящие SIP/UDP-звонки с RTP/G.711;
- чат, история сообщений и статусы доставки/прочтения;
- контакты и история звонков;
- видеозвонки и LiveKit-конференции;
- адаптивная сетка участников и индикация говорящего;
- Android foreground service и управление системными разрешениями;
- светлая, тёмная и системная темы.

## Требования

- Android 7.0 (API 24) или новее;
- JDK 17 и Flutter 3.47.0 для сборки;
- production keystore предыдущей устанавливаемой версии для обновления без потери данных.

Инструкции: [BUILD.md](BUILD.md) и [RELEASE.md](RELEASE.md).

Другие платформы: [Windows](https://github.com/sugdnet11/Tvoice/tree/windows) ·
[iOS](https://github.com/sugdnet11/Tvoice/tree/ios)  
Канонические server/web-исходники находятся в ветке
[`windows`](https://github.com/sugdnet11/Tvoice/tree/windows).

Все постоянные установщики публикуются на странице
[GitHub Releases](https://github.com/sugdnet11/Tvoice/releases).

