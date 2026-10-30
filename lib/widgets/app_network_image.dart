import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../services/http_client.dart';
import '../theme/app_theme.dart';

/// 带磁盘/内存缓存的网络图：同一地址只拉一次，滚动/悬停复用。
class AppNetworkImage extends StatelessWidget {
  const AppNetworkImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.placeholder,
    this.error,
    this.memCacheWidth,
  });

  final String url;
  final BoxFit fit;
  final Alignment alignment;
  final Widget? placeholder;
  final Widget? error;
  final int? memCacheWidth;

  static final CacheManager cacheManager = CacheManager(
    Config(
      'yingshi_img_cache',
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: 800,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final raw = AppHttp.normalizeCover(url);
    if (raw.isEmpty) return error ?? _fallback();
    final src = AppHttp.imageUrl(raw);

    return CachedNetworkImage(
      imageUrl: src,
      cacheKey: raw, // 用原始封面地址做 key，避免代理 URL 变化导致重复下载
      cacheManager: cacheManager,
      fit: fit,
      alignment: alignment,
      fadeInDuration: const Duration(milliseconds: 180),
      fadeOutDuration: const Duration(milliseconds: 80),
      memCacheWidth: memCacheWidth,
      httpHeaders: AppHttp.doubanImageHeaders(),
      placeholder: (_, __) => placeholder ?? _loading(),
      errorWidget: (_, __, ___) => error ?? _fallback(),
    );
  }

  Widget _loading() => const ColoredBox(
        color: AppTheme.panel,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );

  Widget _fallback() => const ColoredBox(
        color: AppTheme.panel,
        child: Center(
          child: Icon(Icons.movie_outlined, color: AppTheme.textDim, size: 28),
        ),
      );
}
