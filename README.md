# Tvoice for Windows

**Версия:** 0.17.10+32

**Статус:** Beta — проверенная Release-сборка без цифровой подписи

**Последняя проверенная сборка:** 25 августа 2026 года

**Скачать последнюю версию:** [Tvoice Windows 0.17.10](https://github.com/sugdnet11/Tvoice/releases/tag/windows-v0.17.10)

Desktop-клиент Tvoice с отдельным интерфейсом Windows, SIP-аудиозвонками,
чатом, видеозвонками и постоянными комнатами конференций.

## Основные функции

- авторизация и контакты FreePBX;
- SIP/UDP и RTP/G.711-аудиозвонки;
- чат, вложения и статусы сообщений;
- видеозвонки и LiveKit-конференции;
- постоянные комнаты, гостевые ссылки и аннулирование приглашений;
- адаптивная видеосетка, индикация активного говорящего и демонстрация экрана;
- обработка ссылок `tvoice://`;
- светлая, тёмная и системная темы.

## Требования

- Windows 10/11 x64;
- для сборки: Flutter 3.47.0, Visual Studio 2022 Desktop C++, .NET 8 SDK;
- для сервера и гостевой web-страницы: Node.js 22 и pnpm 11.

Инструкции: [BUILD.md](BUILD.md), [RELEASE.md](RELEASE.md) и
[DOWNLOADS.md](DOWNLOADS.md).

Другие платформы: [Android](https://github.com/sugdnet11/Tvoice/tree/android) ·
[iOS](https://github.com/sugdnet11/Tvoice/tree/ios) ·
[GitHub Releases](https://github.com/sugdnet11/Tvoice/releases).

> **Unsigned build:** установщик пока не подписан сертификатом Windows Code
> Signing, поэтому SmartScreen может показать предупреждение.

## Платформы

| Платформа | Ветка | Последняя версия | Скачать | Статус |
| --- | --- | --- | --- | --- |
| Android | `android` | 0.17.10+32 | — | Release blocked: wrong signing key |
| iOS | `ios` | — | — | Ожидается загрузка с MacBook |
| Windows | `windows` | 0.17.10+32 | [Setup x64](https://github.com/sugdnet11/Tvoice/releases/tag/windows-v0.17.10) | Beta / Unsigned |
