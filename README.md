# Tvoice for Android

**Версия:** 0.17.11+33

**Статус:** Production release — подписывается исходным ключом Tvoice.

**Последняя проверенная сборка:** 26 августа 2026 года

**Скачать последнюю версию:** [GitHub Releases](https://github.com/sugdnet11/Tvoice/releases).

Android-клиент Tvoice для SIP-аудиозвонков, видеосвязи, конференций, контактов,
истории вызовов и чата. `applicationId`: `tj.tvoice.app`.

## Основные функции

- единый вход в FreePBX и чат;
- входящие и исходящие SIP/UDP-звонки с RTP/G.711;
- чат, история сообщений и статусы доставки/прочтения;
- контакты и история звонков;
- видеозвонки и постоянные LiveKit-комнаты конференций со ссылками-приглашениями;
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

## Подпись Release

CI проверяет сертификат до публикации. Ожидаемый SHA-256 сертификата предыдущей
устанавливаемой APK:
`5c7f64ece62ec08aa11cabf2ce51ce0482ef4747d56f4f6193ad62233748b745`.

Production APK проверяется в CI до публикации. Сборка с другим сертификатом
автоматически отклоняется и не попадает в GitHub Releases.
