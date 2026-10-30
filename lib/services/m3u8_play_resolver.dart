import 'package:flutter/foundation.dart';

import 'http_client.dart';
import 'm3u8_ad_filter.dart';
import 'm3u8_playlist_server.dart';

/// 播放前：拉取 m3u8 → 去广告 → 可播地址
/// - Web：走本地代理 `/m3u8/`（改写列表，分片仍直连 CDN，避免 blob 播不了 HLS）
/// - Android：本机环回只托管改写后的播放列表
class M3u8PlayResolver {
  M3u8PlayResolver._();

  /// 若不是 m3u8 或关闭过滤，原样返回 [url]。
  static Future<String> resolveForPlay(
    String url, {
    required bool adFilterEnabled,
  }) async {
    final low = url.toLowerCase();
    final looksM3u8 = low.contains('.m3u8');
    if (!looksM3u8 || !adFilterEnabled) return url;

    // Web：用查询参数挂过滤列表（避免 path 里 %2F 被中间层拆坏）；分片仍直连 CDN
    if (kIsWeb) {
      return filteredPlaylistUrl(url);
    }

    try {
      var playUrl = url;
      var text = await AppHttp.getText(
        playUrl,
        headers: const {'Accept': '*/*'},
        timeout: const Duration(seconds: 20),
      );

      final variant = M3u8AdFilter.pickBestVariant(text, playUrl);
      if (variant != null) {
        playUrl = variant;
        text = await AppHttp.getText(
          playUrl,
          headers: const {'Accept': '*/*'},
          timeout: const Duration(seconds: 20),
        );
      }

      if (!text.contains('#EXTINF')) return url;

      final filtered = M3u8AdFilter.filter(text, baseUrl: playUrl);
      // 无广告被删：不必换基址，直连原 URL 更稳
      if (identical(filtered, text) || filtered == text) return url;

      final absolute = M3u8AdFilter.absolutize(filtered, playUrl);
      return await M3u8PlaylistServer.register(absolute);
    } catch (e) {
      // ignore: avoid_print
      print('m3u8 去广告失败，回退原址: $e');
      return url;
    }
  }

  /// Web 去广告播放列表地址（本机代理）。
  /// 路径必须带 `.m3u8`，否则浏览器/video_player 会报 MEDIA_ERR_SRC_NOT_SUPPORTED。
  static String filteredPlaylistUrl(String sourceM3u8Url) =>
      '${AppHttp.webProxyOrigin}/pl.m3u8?u=${Uri.encodeQueryComponent(sourceM3u8Url)}';

  static bool isFilteredPlaylistUrl(String url) =>
      url.contains('/pl.m3u8?') || url.contains('/m3u8?') || url.contains('/m3u8/');

  static void revokeLast() {
    // Web 无 blob；Android 环回列表由下次 register 覆盖，无需显式 revoke
  }
}
