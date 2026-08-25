# Выпуск Android

1. Убедиться, что версия в `VERSION` и `pubspec.yaml` совпадает, а build number увеличен.
2. Настроить GitHub Secrets: `ANDROID_KEYSTORE_BASE64`,
   `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
3. Сравнить SHA-256 сертификата новой APK с предыдущей production APK.
4. Создать неизменяемый tag `android-v0.17.10`.
5. Workflow опубликует подписанные APK/AAB и файл SHA-256 в GitHub Releases.

Если сертификаты не совпадают, Release необходимо остановить: такая APK не
может обновить установленное приложение поверх старой версии.

