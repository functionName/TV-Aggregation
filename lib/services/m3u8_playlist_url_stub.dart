/// 非 Web：不支持 blob，由调用方改走本地 HTTP。
String? createM3u8BlobUrl(String content) => null;

void revokeM3u8BlobUrl(String? url) {}
