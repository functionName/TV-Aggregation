class ScanHit {
  const ScanHit({required this.ok, this.text, required this.message});
  final bool ok;
  final String? text;
  final String message;
}

Future<ScanHit> scanUsbConfig() async =>
    const ScanHit(ok: false, message: '当前平台不支持扫描 U 盘');

Future<String> readFile(String path) async =>
    throw UnsupportedError('Web 无法按路径读文件');
