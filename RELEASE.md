# Выпуск Android

1. Убедиться, что версия в `VERSION` и `pubspec.yaml` совпадает, а build number увеличен.
2. Настроить GitHub Secrets: `TVOICE_KEYSTORE_BASE64` и
   `TVOICE_KEYSTORE_PASSWORD`. Alias production-ключа: `tvoice`.
3. Сравнить SHA-256 сертификата новой APK с предыдущей production APK.
4. Создать неизменяемый tag `android-v0.17.11`.
5. Workflow опубликует подписанные APK/AAB и файл SHA-256 в GitHub Releases.

Если сертификаты не совпадают, Release необходимо остановить: такая APK не
может обновить установленное приложение поверх старой версии.

