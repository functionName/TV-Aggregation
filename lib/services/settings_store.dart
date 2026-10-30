import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

class SourceMeta {
  final String name;
  final String url;
  const SourceMeta(this.name, this.url);
}

class SettingsStore extends ChangeNotifier {
  static const _kCustom = 'customAPIs';
  static const _kSelected = 'selectedAPIs';
  static const _kYellow = 'yellowFilterEnabled';
  static const _kAdFilter = 'adFilteringEnabled';
  static const _kDouban = 'doubanEnabled';
  static const _kFeedMode = 'homeFeedMode';
  static const _kFeedSource = 'homeFeedSource';
  static const _kHistory = 'viewingHistory';
  static const _kFavorites = 'favorites';
  static const _kSearchHistory = 'videoSearchHistory';
  static const _kEpReversed = 'episodesReversed';
  static const _kKbPinyin = 'kbPinyin';

  /// 首页/发现推荐数据：豆瓣 或 单个采集源（不支持多源混排）
  static const feedDouban = 'douban';
  static const feedSource = 'source';
  /// 旧版「全部源」，加载时迁移掉
  static const feedAllLegacy = 'all';

  SharedPreferences? _prefs;
  Future<void>? _loading;

  List<CustomApi> customApis = [];
  List<String> selectedApis = [];
  bool yellowFilterEnabled = true;
  /// m3u8 片中插播广告过滤（对齐 Veliora / TVBox 思路）
  bool adFilteringEnabled = true;
  /// 兼容旧逻辑：与 [feedMode]==douban 同步
  bool doubanEnabled = true;
  /// douban | source
  String feedMode = feedDouban;
  /// [feedMode]==source 时使用的源 code（如 custom_0）
  String feedSourceCode = '';
  bool episodesReversed = false;

  /// 搜索软键盘：true=拼音选字，false=字母/简称联想
  bool kbPinyin = false;

  bool get useDoubanFeed => feedMode == feedDouban;

  /// 推荐用的有效单源；豆瓣模式或无效时为空
  String? get effectiveFeedSourceCode {
    if (feedMode != feedSource) return null;
    if (feedSourceCode.isEmpty || resolveSource(feedSourceCode) == null) {
      return null;
    }
    return feedSourceCode;
  }

  String get feedModeLabel {
    if (feedMode == feedSource) {
      final name = resolveSource(feedSourceCode)?.name;
      return name == null || name.isEmpty ? '指定采集源' : name;
    }
    return '豆瓣';
  }
  List<HistoryItem> viewingHistory = [];
  List<FavoriteItem> favorites = [];
  List<String> searchHistory = [];

  bool get isReady => _prefs != null;

  /// 幂等：UI 可先启动，任意读写前先 await 本方法
  Future<void> ensureReady() => _loading ??= _doLoad();

  Future<void> load() => ensureReady();

  Future<void> _doLoad() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final p = _prefs!;
      yellowFilterEnabled = p.getString(_kYellow) != 'false';
      adFilteringEnabled = p.getString(_kAdFilter) != 'false';
      final legacyDouban = p.getString(_kDouban) != 'false';
      final rawMode = p.getString(_kFeedMode);
      feedSourceCode = p.getString(_kFeedSource) ?? '';
      // 先记下，等采集源列表加载完再规范化（去掉旧「全部源」）
      feedMode = (rawMode == feedSource || rawMode == feedDouban)
          ? rawMode!
          : (rawMode == feedAllLegacy
              ? feedAllLegacy
              : (legacyDouban ? feedDouban : feedSource));
      episodesReversed = p.getString(_kEpReversed) == 'true';
      kbPinyin = p.getString(_kKbPinyin) == 'true';

      try {
        final raw = p.getString(_kCustom);
        if (raw != null) {
          final list = jsonDecode(raw) as List;
          customApis = list
              .whereType<Map>()
              .map((e) => CustomApi.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
      } catch (_) {}

      try {
        final raw = p.getString(_kSelected);
        if (raw != null) {
          selectedApis = (jsonDecode(raw) as List).map((e) => '$e').toList();
        }
      } catch (_) {}

      if (selectedApis.isEmpty && customApis.isNotEmpty) {
        selectedApis = [
          for (var i = 0; i < customApis.length; i++) 'custom_$i',
        ];
      }

      _normalizeFeedMode();
      doubanEnabled = feedMode == feedDouban;

      try {
        final raw = p.getString(_kHistory);
        if (raw != null) {
          viewingHistory = (jsonDecode(raw) as List)
              .whereType<Map>()
              .map((e) => HistoryItem.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
      } catch (_) {}

      try {
        final raw = p.getString(_kFavorites);
        if (raw != null) {
          favorites = (jsonDecode(raw) as List)
              .whereType<Map>()
              .map((e) => FavoriteItem.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
      } catch (_) {}

      try {
        final raw = p.getString(_kSearchHistory);
        if (raw != null) {
          final list = jsonDecode(raw) as List;
          searchHistory = list.map((e) {
            if (e is String) return e;
            if (e is Map) return '${e['text'] ?? ''}';
            return '';
          }).where((e) => e.isNotEmpty).toList();
        }
      } catch (_) {}
    } catch (e, st) {
      debugPrint('SettingsStore load failed: $e\n$st');
      // 再给一次机会：下次 ensureReady 会重试
      _loading = null;
      rethrow;
    }
    notifyListeners();
  }

  Future<SharedPreferences> _prefsReady() async {
    await ensureReady();
    final p = _prefs;
    if (p == null) {
      throw StateError('SharedPreferences 初始化失败');
    }
    return p;
  }

  List<String> get enabledSources {
    final out = <String>[];
    for (final s in selectedApis) {
      if (s.startsWith('custom_')) {
        final i = int.tryParse(s.substring(7));
        if (i != null && i >= 0 && i < customApis.length) out.add(s);
      }
    }
    if (out.isEmpty && customApis.isNotEmpty) {
      return [for (var i = 0; i < customApis.length; i++) 'custom_$i'];
    }
    return out;
  }

  SourceMeta? resolveSource(String code) {
    if (code.startsWith('custom_')) {
      final i = int.tryParse(code.substring(7));
      if (i == null || i < 0 || i >= customApis.length) return null;
      final c = customApis[i];
      return SourceMeta(c.name, c.url);
    }
    return null;
  }

  void _normalizeFeedMode() {
    if (feedMode == feedAllLegacy) {
      feedMode = feedSource;
    }
    if (feedMode != feedDouban && feedMode != feedSource) {
      feedMode = feedDouban;
    }
    if (feedMode == feedSource) {
      if (feedSourceCode.isEmpty || resolveSource(feedSourceCode) == null) {
        final enabled = enabledSources;
        feedSourceCode = enabled.isNotEmpty ? enabled.first : '';
      }
      if (feedSourceCode.isEmpty) {
        feedMode = feedDouban;
      }
    }
  }

  Future<void> setDouban(bool v) async {
    if (v) {
      await setFeedMode(feedDouban);
    } else {
      final code = enabledSources.isNotEmpty ? enabledSources.first : null;
      await setFeedMode(feedSource, sourceCode: code);
    }
  }

  Future<void> setFeedMode(String mode, {String? sourceCode}) async {
    feedMode = mode;
    if (sourceCode != null) feedSourceCode = sourceCode;
    _normalizeFeedMode();
    doubanEnabled = feedMode == feedDouban;
    notifyListeners();
    final p = await _prefsReady();
    await p.setString(_kFeedMode, feedMode);
    await p.setString(_kFeedSource, feedSourceCode);
    await p.setString(_kDouban, '$doubanEnabled');
  }

  Future<void> setYellow(bool v) async {
    yellowFilterEnabled = v;
    final p = await _prefsReady();
    await p.setString(_kYellow, '$v');
    notifyListeners();
  }

  Future<void> setAdFiltering(bool v) async {
    adFilteringEnabled = v;
    notifyListeners();
    final p = await _prefsReady();
    await p.setString(_kAdFilter, '$v');
  }

  Future<void> setEpReversed(bool v) async {
    episodesReversed = v;
    final p = await _prefsReady();
    await p.setString(_kEpReversed, '$v');
    notifyListeners();
  }

  Future<void> setKbPinyin(bool v) async {
    kbPinyin = v;
    final p = await _prefsReady();
    await p.setString(_kKbPinyin, '$v');
    notifyListeners();
  }

  Future<void> setSelected(List<String> codes) async {
    selectedApis = codes;
    final p = await _prefsReady();
    await p.setString(_kSelected, jsonEncode(codes));
    notifyListeners();
  }

  Future<void> addCustomApi(CustomApi api) async {
    customApis = [...customApis, api];
    final p = await _prefsReady();
    await p.setString(
        _kCustom, jsonEncode(customApis.map((e) => e.toJson()).toList()));
    final code = 'custom_${customApis.length - 1}';
    if (!selectedApis.contains(code)) {
      selectedApis = [...selectedApis, code];
      await p.setString(_kSelected, jsonEncode(selectedApis));
    }
    notifyListeners();
  }

  Future<void> removeCustomApi(int index) async {
    if (index < 0 || index >= customApis.length) return;
    // 删除后索引会前移：把仍启用的旧 code 映射到新下标，不要整表重开
    final keep = <int>{};
    for (final s in selectedApis) {
      if (!s.startsWith('custom_')) continue;
      final i = int.tryParse(s.substring(7));
      if (i == null || i == index) continue;
      if (i > index) {
        keep.add(i - 1);
      } else {
        keep.add(i);
      }
    }
    customApis = [...customApis]..removeAt(index);
    selectedApis = [
      for (final i in keep.toList()..sort())
        if (i >= 0 && i < customApis.length) 'custom_$i',
    ];
    // 删光启用项时，若还有源则默认全开，避免搜不到片
    if (selectedApis.isEmpty && customApis.isNotEmpty) {
      selectedApis = [
        for (var i = 0; i < customApis.length; i++) 'custom_$i',
      ];
    }
    final p = await _prefsReady();
    await p.setString(
        _kCustom, jsonEncode(customApis.map((e) => e.toJson()).toList()));
    await p.setString(_kSelected, jsonEncode(selectedApis));
    notifyListeners();
  }

  /// 按探测结果批量删掉失败源（传入当前失败的 custom_i）
  Future<void> removeCustomApisByCodes(Iterable<String> codes) async {
    final doomed = codes
        .map((c) => int.tryParse(c.startsWith('custom_') ? c.substring(7) : c))
        .whereType<int>()
        .where((i) => i >= 0 && i < customApis.length)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a)); // 从大到小删，避免下标错位
    for (final i in doomed) {
      await removeCustomApi(i);
    }
  }

  Future<void> importConfigJson(String text) async {
    await ensureReady();
    final data = jsonDecode(text);
    if (data is! Map) throw Exception('配置格式错误');
    final map = Map<String, dynamic>.from(data);

    if (map['sources'] is List) {
      final list = (map['sources'] as List)
          .whereType<Map>()
          .map((e) {
            final m = Map<String, dynamic>.from(e);
            final url =
                '${m['url'] ?? m['api'] ?? ''}'.replaceAll(RegExp(r'/+$'), '');
            return CustomApi(
              name: '${m['name'] ?? ''}'.trim().isEmpty
                  ? '自定义源'
                  : '${m['name']}'.trim(),
              url: url,
              isAdult: m['isAdult'] == true,
            );
          })
          .where((e) =>
              RegExp(r'^https?://', caseSensitive: false).hasMatch(e.url))
          .take(50)
          .toList();
      if (list.isEmpty) throw Exception('sources 列表为空或格式无效');
      await _applyApis(list);
      return;
    }

    final name = '${map['name'] ?? ''}';
    if (name == 'Veliora-Settings' || name == 'LibreTV-Settings') {
      final inner = map['data'];
      if (inner is! Map) throw Exception('配置 data 无效');
      final raw = inner['customAPIs'];
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! List) throw Exception('备份中无 customAPIs');
      final list = decoded
          .whereType<Map>()
          .map((e) => CustomApi.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.url.isNotEmpty)
          .toList();
      await _applyApis(list);
      final sel = inner['selectedAPIs'];
      if (sel is String) {
        try {
          final arr = jsonDecode(sel);
          if (arr is List) {
            selectedApis = arr.map((e) => '$e').toList();
            _sanitizeSelected();
            final p = await _prefsReady();
            await p.setString(_kSelected, jsonEncode(selectedApis));
          }
        } catch (_) {}
      }
      notifyListeners();
      return;
    }

    final apis = map['customAPIs'] ?? map['apis'];
    if (apis is List) {
      final list = apis
          .whereType<Map>()
          .map((e) => CustomApi.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.url.isNotEmpty)
          .toList();
      await _applyApis(list);
      if (map['selectedAPIs'] is List) {
        selectedApis =
            (map['selectedAPIs'] as List).map((e) => '$e').toList();
        _sanitizeSelected();
        final p = await _prefsReady();
        await p.setString(_kSelected, jsonEncode(selectedApis));
        notifyListeners();
      }
      return;
    }
    throw Exception('无法识别的配置格式');
  }

  Future<void> _applyApis(List<CustomApi> list) async {
    customApis = list;
    selectedApis = [
      for (var i = 0; i < customApis.length; i++) 'custom_$i',
    ];
    final p = await _prefsReady();
    await p.setString(
        _kCustom, jsonEncode(customApis.map((e) => e.toJson()).toList()));
    await p.setString(_kSelected, jsonEncode(selectedApis));
    notifyListeners();
  }

  /// 丢掉指向不存在源的 selected 下标，避免导入备份后「勾了却搜不到」
  void _sanitizeSelected() {
    final next = <String>[];
    for (final s in selectedApis) {
      if (!s.startsWith('custom_')) continue;
      final i = int.tryParse(s.substring(7));
      if (i != null && i >= 0 && i < customApis.length) next.add(s);
    }
    selectedApis = next.isEmpty && customApis.isNotEmpty
        ? [for (var i = 0; i < customApis.length; i++) 'custom_$i']
        : next;
  }

  String exportConfigJson() => jsonEncode({
        'customAPIs': customApis.map((e) => e.toJson()).toList(),
        'selectedAPIs': selectedApis,
      });

  Future<void> pushSearchHistory(String q) async {
    final t = q.trim();
    if (t.isEmpty) return;
    searchHistory = [t, ...searchHistory.where((e) => e != t)].take(8).toList();
    notifyListeners();
    try {
      final p = await _prefsReady();
      await p.setString(
        _kSearchHistory,
        jsonEncode(searchHistory
            .map((e) => {
                  'text': e,
                  'timestamp': DateTime.now().millisecondsSinceEpoch
                })
            .toList()),
      );
    } catch (e) {
      debugPrint('pushSearchHistory persist failed: $e');
    }
  }

  Future<void> clearSearchHistory() async {
    searchHistory = [];
    final p = await _prefsReady();
    await p.setString(_kSearchHistory, '[]');
    notifyListeners();
  }

  Future<void> recordHistory(HistoryItem item) async {
    viewingHistory = [
      item,
      ...viewingHistory.where((e) =>
          !(e.vodId == item.vodId && e.sourceCode == item.sourceCode)),
    ].take(40).toList();
    notifyListeners();
    try {
      final p = await _prefsReady();
      await p.setString(
          _kHistory, jsonEncode(viewingHistory.map((e) => e.toJson()).toList()));
    } catch (e) {
      debugPrint('recordHistory persist failed: $e');
    }
  }

  HistoryItem? findHistory({required String vodId, required String sourceCode}) {
    if (vodId.isEmpty) return null;
    for (final h in viewingHistory) {
      if (h.vodId == vodId && h.sourceCode == sourceCode) return h;
    }
    return null;
  }

  Future<void> clearHistory() async {
    viewingHistory = [];
    final p = await _prefsReady();
    await p.setString(_kHistory, '[]');
    notifyListeners();
  }

  bool isFavorite({required String vodId, required String sourceCode}) {
    if (vodId.isEmpty) return false;
    return favorites.any((e) => e.vodId == vodId && e.sourceCode == sourceCode);
  }

  Future<void> toggleFavorite(FavoriteItem item) async {
    final exists = isFavorite(vodId: item.vodId, sourceCode: item.sourceCode);
    if (exists) {
      favorites = favorites
          .where((e) =>
              !(e.vodId == item.vodId && e.sourceCode == item.sourceCode))
          .toList();
    } else {
      favorites = [item, ...favorites].take(80).toList();
    }
    notifyListeners();
    try {
      final p = await _prefsReady();
      await p.setString(
        _kFavorites,
        jsonEncode(favorites.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('toggleFavorite persist failed: $e');
    }
  }

  Future<void> clearFavorites() async {
    favorites = [];
    final p = await _prefsReady();
    await p.setString(_kFavorites, '[]');
    notifyListeners();
  }
}
