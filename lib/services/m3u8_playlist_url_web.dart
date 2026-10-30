// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

String? createM3u8BlobUrl(String content) {
  final blob = html.Blob([content], 'application/vnd.apple.mpegurl');
  return html.Url.createObjectUrlFromBlob(blob);
}

void revokeM3u8BlobUrl(String? url) {
  if (url == null || url.isEmpty) return;
  html.Url.revokeObjectUrl(url);
}
