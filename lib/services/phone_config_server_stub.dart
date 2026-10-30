/// Web stub：无局域网服务能力
class PhoneConfigServer {
  PhoneConfigServer._();
  static const port = 8765;
  static bool get isRunning => false;
  static bool get supported => false;

  static Future<List<String>> start({
    required String Function() getConfig,
    required Future<void> Function(String body) applyConfig,
  }) async {
    throw UnsupportedError('Web 端无法在本机开局域网服务，请用电视 APK');
  }

  static Future<void> stop() async {}

  static Future<List<String>> lanUrls() async => const [];
}
