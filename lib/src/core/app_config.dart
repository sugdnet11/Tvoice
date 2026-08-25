abstract final class AppConfig {
  static const appName = 'Tvoice';
  static const version = '0.17.9';
  static const apiBaseUrl = 'https://chat.185-177-2-115.sslip.io';
  static const sipHost = '185.177.2.115';
  static const sipPort = 5060;

  static Uri api(String path, [Map<String, String>? query]) =>
      Uri.parse('$apiBaseUrl$path').replace(queryParameters: query);

  static Uri webSocket(String token) =>
      Uri.parse(apiBaseUrl.replaceFirst('https://', 'wss://'))
          .replace(path: '/v1/ws', queryParameters: {'token': token});
}
