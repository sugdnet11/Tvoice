# Выпуск Windows

1. Обновить `VERSION`, `pubspec.yaml`, `CHANGELOG.md` и версию в installer.
2. Выполнить clean build и тесты на Windows x64.
3. Проверить установку поверх предыдущей версии и обработку `tvoice://`.
4. Создать неизменяемый tag `windows-v0.17.10`.
5. Workflow опубликует Setup x64 и SHA-256 в GitHub Releases.

Текущий установщик не имеет цифровой подписи. В Release и README необходимо
оставлять маркировку `Unsigned build`, пока не настроен Windows Code Signing.

