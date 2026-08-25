# Сборка Android

## Требования

- Flutter 3.47.0;
- Dart 3.13.0;
- JDK 17;
- Android SDK с Build Tools 36.0.0.

## Проверка

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Production APK/AAB собираются только с тем же keystore, которым подписана
предыдущая устанавливаемая версия. Конфигурация Gradle получает путь, alias и
пароли исключительно из переменных `TVOICE_SIGNING_*`.

