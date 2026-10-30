import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models/models.dart';
import '../services/m3u8_play_resolver.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';

/// 电视风播放器：进度 / 倍速 / 选集 / 线路(4K) / 遥控操作
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.title,
    required this.episodes,
    this.lines = const [],
    this.initialLineIndex = 0,
    this.initialIndex = 0,
    this.initialPositionMs = 0,
    this.cover = '',
    this.sourceCode = '',
    this.sourceName = '',
    this.apiUrl,
    this.vodId = '',
    this.hasNextSource = false,
  });

  final String title;
  final List<Episode> episodes;
  final List<PlayLine> lines;
  final int initialLineIndex;
  final int initialIndex;
  /// 断点续播（毫秒）；靠近片尾则忽略
  final int initialPositionMs;
  final String cover;
  final String sourceCode;
  final String sourceName;
  final String? apiUrl;
  final String vodId;
  /// 详情还有其它播放源时可一键换源
  final bool hasNextSource;

  /// Navigator.pop 返回值：换下一播放源
  static const popNextSource = 'next_source';

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  static const _speeds = [0.75, 1.0, 1.25, 1.5, 2.0];

  late int index;
  late List<Episode> _episodes;
  late List<PlayLine> _lines;
  late int _lineIndex;
  VideoPlayerController? controller;
  bool ready = false;
  String? error;
  double speed = 1.0;

  bool showControls = true;
  /// 统一设置面板（倍速 / 选集 / 线路）
  bool showSettings = false;
  /// 0=倍速 1=选集 2=线路（无线路时只有前两项）
  int settingsTab = 0;
  bool _endedHandled = false;
  Timer? hideTimer;
  Timer? _progressTimer;
  bool _didSeekResume = false;

  /// 面板内遥控光标
  int _speedCursor = 1;
  int _epCursor = 0;
  int _lineCursor = 0;
  final _epScroll = ScrollController();
  final _focusNode = FocusNode();
  /// 播放失败自动换线时防止死循环
  final Set<int> _failedLines = {};
  bool _switchingLine = false;
  SettingsStore? _store;

  bool get _hasMultiLine => _lines.length > 1;
  int get _tabCount => _hasMultiLine ? 3 : 2;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = context.read<SettingsStore>();
  }

  @override
  void initState() {
    super.initState();
    _lines = widget.lines.isNotEmpty
        ? List<PlayLine>.from(widget.lines)
        : [
            if (widget.episodes.isNotEmpty)
              PlayLine(name: '默认', episodes: widget.episodes),
          ];
    // Web 上 /share/ 直链几乎必挂，默认挑可播性更高的线
    var prefer = widget.initialLineIndex;
    if (_lines.isNotEmpty) {
      prefer = prefer.clamp(0, _lines.length - 1);
      if (kIsWeb && _lines[prefer].looksUnreliable) {
        final better = _lines.indexWhere((l) => !l.looksUnreliable);
        if (better >= 0) prefer = better;
      }
    }
    _lineIndex = _lines.isEmpty ? 0 : prefer;
    _episodes = _lines.isEmpty
        ? List<Episode>.from(widget.episodes)
        : List<Episode>.from(_lines[_lineIndex].episodes);
    _lineCursor = _lineIndex;
    if (_episodes.isEmpty) {
      index = 0;
      _epCursor = 0;
    } else {
      index = widget.initialIndex.clamp(0, _episodes.length - 1);
      _epCursor = index;
    }
    _speedCursor = _speeds.indexOf(speed).clamp(0, _speeds.length - 1);
    _open();
    _bumpHide();
    _progressTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _saveProgress();
    });
  }

  @override
  void dispose() {
    hideTimer?.cancel();
    _progressTimer?.cancel();
    _saveProgress();
    _epScroll.dispose();
    _focusNode.dispose();
    M3u8PlayResolver.revokeLast();
    controller?.dispose();
    super.dispose();
  }

  bool get _canSaveHistory =>
      widget.vodId.isNotEmpty && widget.sourceCode.isNotEmpty;

  void _saveProgress() {
    if (!_canSaveHistory) return;
    final store = _store;
    if (store == null) return;
    final c = controller;
    var posMs = 0;
    if (c != null && c.value.isInitialized) {
      final dur = c.value.duration.inMilliseconds;
      final pos = c.value.position.inMilliseconds;
      // 距片尾不足 60s：记为看完，进度归零方便下次重看
      if (dur > 0 && pos >= dur - 60000) {
        posMs = 0;
      } else {
        posMs = pos.clamp(0, dur > 0 ? dur : pos);
      }
    }
    store.recordHistory(HistoryItem(
      title: widget.title,
      cover: widget.cover,
      sourceCode: widget.sourceCode,
      sourceName: widget.sourceName,
      apiUrl: widget.apiUrl,
      vodId: widget.vodId,
      episodeIndex: index,
      positionMs: posMs,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  void _closePanels() {
    setState(() => showSettings = false);
    _bumpHide();
    _focusNode.requestFocus();
  }

  void _openSettings({int tab = 0}) {
    setState(() {
      showSettings = true;
      showControls = true;
      settingsTab = tab.clamp(0, _tabCount - 1);
      _speedCursor = _speeds.indexOf(speed);
      if (_speedCursor < 0) _speedCursor = 1;
      _epCursor = index;
      _lineCursor = _lineIndex;
    });
    _focusNode.requestFocus();
    if (settingsTab == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureEpVisible());
    }
  }

  void _nudgeSettingsTab(int delta) {
    setState(() {
      settingsTab = (settingsTab + delta).clamp(0, _tabCount - 1);
      if (settingsTab == 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _ensureEpVisible());
      }
    });
  }

  void _applySettingsSelection() {
    switch (settingsTab) {
      case 0:
        _setSpeed(_speeds[_speedCursor]);
      case 1:
        _playIndex(_epCursor);
      case 2:
        if (_hasMultiLine) _applyLine(_lineCursor);
    }
  }

  void _nudgeSpeed(int delta) {
    setState(() {
      _speedCursor =
          (_speedCursor + delta).clamp(0, _speeds.length - 1);
    });
  }

  void _nudgeLine(int delta) {
    if (_lines.isEmpty) return;
    setState(() {
      _lineCursor = (_lineCursor + delta).clamp(0, _lines.length - 1);
    });
  }

  void _nudgeEpisode(int delta) {
    if (_episodes.isEmpty) return;
    setState(() {
      _epCursor = (_epCursor + delta).clamp(0, _episodes.length - 1);
    });
    _ensureEpVisible();
  }

  Future<void> _applyLine(int lineIdx, {bool manual = true}) async {
    if (lineIdx < 0 || lineIdx >= _lines.length) return;
    // 仅挡住连按；自动换线要能嵌套进 _open
    if (_switchingLine && manual) return;
    final nextEps = _lines[lineIdx].episodes;
    if (nextEps.isEmpty) return;
    final keepName = index < _episodes.length ? _episodes[index].name : '';
    var nextIndex = index.clamp(0, nextEps.length - 1);
    if (keepName.isNotEmpty) {
      final byName = nextEps.indexWhere((e) => e.name == keepName);
      if (byName >= 0) nextIndex = byName;
    }
    final wasSwitching = _switchingLine;
    _switchingLine = true;
    setState(() {
      _lineIndex = lineIdx;
      _episodes = List<Episode>.from(nextEps);
      index = nextIndex;
      _epCursor = nextIndex;
      showSettings = false;
      if (manual) _failedLines.clear();
    });
    try {
      await _open(allowLineFallback: true);
    } finally {
      _switchingLine = wasSwitching;
    }
  }

  /// 当前集播挂时，自动试下一条更可播的线路
  Future<bool> _tryFallbackLine(String reason) async {
    if (!_hasMultiLine) return false;
    _failedLines.add(_lineIndex);
    final candidates = <int>[
      for (var i = 0; i < _lines.length; i++)
        if (!_failedLines.contains(i) &&
            // Web 上 /share/ 网页链必挂，自动换线时直接跳过
            !(kIsWeb && _lines[i].looksUnreliable))
          i,
    ]..sort((a, b) =>
        _lines[b].playabilityScore.compareTo(_lines[a].playabilityScore));
    if (candidates.isEmpty) return false;
    final next = candidates.first;
    if (!mounted) return false;
    setState(() {
      error = '线路不可播，正在换「${_lines[next].name}」…\n$reason';
    });
    final nextEps = _lines[next].episodes;
    if (nextEps.isEmpty) return false;
    final keepName = index < _episodes.length ? _episodes[index].name : '';
    var nextIndex = index.clamp(0, nextEps.length - 1);
    if (keepName.isNotEmpty) {
      final byName = nextEps.indexWhere((e) => e.name == keepName);
      if (byName >= 0) nextIndex = byName;
    }
    setState(() {
      _lineIndex = next;
      _episodes = List<Episode>.from(nextEps);
      index = nextIndex;
      _epCursor = nextIndex;
      _lineCursor = next;
    });
    await _open(allowLineFallback: true);
    return true;
  }

  void _ensureEpVisible() {
    if (!_epScroll.hasClients) return;
    // 约每项 52px
    final target = (_epCursor * 52.0).clamp(
      0.0,
      _epScroll.position.maxScrollExtent,
    );
    _epScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  bool _handleBack() {
    if (showSettings) {
      _closePanels();
      return true;
    }
    if (showControls) {
      setState(() => showControls = false);
      return true;
    }
    Navigator.pop(context);
    return true;
  }

  void _bumpHide() {
    hideTimer?.cancel();
    if (!showControls || showSettings) return;
    hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || showSettings) return;
      setState(() => showControls = false);
    });
  }

  void _revealControls() {
    setState(() => showControls = true);
    _bumpHide();
  }

  String get _epLabel {
    if (index < 0 || index >= _episodes.length) return '播放';
    final e = _episodes[index];
    if (e.name.trim().isNotEmpty) return e.name;
    return '第${index + 1}集';
  }

  String get _lineLabel {
    if (_lines.isEmpty) return '';
    final i = _lineIndex.clamp(0, _lines.length - 1);
    return _lines[i].name;
  }

  Future<void> _open({bool allowLineFallback = true}) async {
    await controller?.dispose();
    _endedHandled = false;
    if (_episodes.isEmpty) {
      setState(() {
        ready = false;
        error = '没有可播放剧集';
        controller = null;
      });
      return;
    }
    setState(() {
      ready = false;
      error = null;
      controller = null;
    });
    final url = _episodes[index].url;
    final low = url.toLowerCase();
    // Web 上 /share/ 基本必挂，直接换线，少一次红错
    if (kIsWeb &&
        low.contains('/share/') &&
        allowLineFallback &&
        _hasMultiLine) {
      final tip = '当前是网页分享链，浏览器播不了';
      final ok = await _tryFallbackLine(tip);
      if (ok) return;
      if (mounted) {
        setState(() {
          error = '$tip\n请打开「设置」换带 HLS 的线路，或换播放源';
        });
      }
      return;
    }
    M3u8PlayResolver.revokeLast();
    final adOn = _store?.adFilteringEnabled ?? true;
    var playUrl = await M3u8PlayResolver.resolveForPlay(
      url,
      adFilterEnabled: adOn,
    );
    if (!mounted) return;
    VideoPlayerController? c;
    try {
      c = VideoPlayerController.networkUrl(Uri.parse(playUrl));
      try {
        await c.initialize();
      } catch (e) {
        // 去广告改写地址失败时，先回退同源直链，避免误跳到 /share/ 线路
        if (adOn && playUrl != url) {
          // ignore: avoid_print
          print('去广告地址初始化失败，回退直链: $e');
          await c.dispose();
          playUrl = url;
          c = VideoPlayerController.networkUrl(Uri.parse(playUrl));
          await c.initialize();
        } else {
          rethrow;
        }
      }
      await c.setPlaybackSpeed(speed);
      // 断点续播：仅本集首次打开时 seek；距片尾 <60s 则从头
      if (!_didSeekResume &&
          index == widget.initialIndex &&
          widget.initialPositionMs > 5000) {
        final dur = c.value.duration.inMilliseconds;
        final want = widget.initialPositionMs;
        if (dur <= 0 || want < dur - 60000) {
          await c.seekTo(Duration(milliseconds: want));
        }
        _didSeekResume = true;
      }
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      final active = c;
      setState(() {
        controller = active;
        ready = true;
        error = null;
      });
      active.addListener(() {
        if (!mounted) return;
        if (active.value.hasError) {
          final desc = active.value.errorDescription ?? '播放失败';
          _onPlayFailed(desc, allowLineFallback: allowLineFallback);
          return;
        }
        setState(() {}); // 刷新进度
        final v = active.value;
        if (!_endedHandled &&
            v.isInitialized &&
            !v.isPlaying &&
            v.duration > Duration.zero &&
            v.position >= v.duration - const Duration(milliseconds: 400)) {
          _endedHandled = true;
          _saveProgress();
          _next();
        }
      });
      _revealControls();
    } catch (e) {
      await c?.dispose();
      await _onPlayFailed('$e', allowLineFallback: allowLineFallback);
    }
  }

  Future<void> _onPlayFailed(
    String raw, {
    required bool allowLineFallback,
  }) async {
    if (!mounted) return;
    final friendly = _friendlyPlayError(raw);
    if (allowLineFallback && _hasMultiLine) {
      final ok = await _tryFallbackLine(friendly);
      if (ok) return;
    }
    if (!mounted) return;
    setState(() {
      ready = false;
      error = friendly;
    });
  }

  String _friendlyPlayError(String raw) {
    final s = raw.toLowerCase();
    if (s.contains('src_not_supported') ||
        s.contains('format error') ||
        s.contains('not supported')) {
      return '线路不可播';
    }
    if (s.contains('network') || s.contains('timeout')) {
      return '加载失败';
    }
    if (s.contains('platformexception')) {
      return '播放失败';
    }
    final one = raw.replaceAll('\n', ' ').trim();
    if (one.length > 48) return '${one.substring(0, 48)}…';
    return one;
  }

  Future<void> _playIndex(int i) async {
    if (i < 0 || i >= _episodes.length) return;
    if (i == index && ready) {
      setState(() => showSettings = false);
      return;
    }
    _saveProgress();
    setState(() {
      index = i;
      showSettings = false;
    });
    await _open();
  }

  Future<void> _next() async {
    if (index >= _episodes.length - 1) return;
    await _playIndex(index + 1);
  }

  Future<void> _prev() async {
    if (index <= 0) return;
    await _playIndex(index - 1);
  }

  void _togglePlay() {
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    c.value.isPlaying ? c.pause() : c.play();
    _revealControls();
  }

  Future<void> _seekBy(Duration d) async {
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    var next = c.value.position + d;
    if (next < Duration.zero) next = Duration.zero;
    if (next > c.value.duration) next = c.value.duration;
    await c.seekTo(next);
    _revealControls();
  }

  Future<void> _setSpeed(double s) async {
    speed = s;
    final c = controller;
    if (c != null && c.value.isInitialized) {
      await c.setPlaybackSpeed(s);
    }
    setState(() => showSettings = false);
    _revealControls();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;

    final isBack = key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.backspace;
    if (isBack) {
      _handleBack();
      return KeyEventResult.handled;
    }

    // —— 统一设置面板：左右切 Tab，上下选，确认应用 ——
    if (showSettings) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _nudgeSettingsTab(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _nudgeSettingsTab(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        switch (settingsTab) {
          case 0:
            _nudgeSpeed(-1);
          case 1:
            _nudgeEpisode(-1);
          case 2:
            _nudgeLine(-1);
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        switch (settingsTab) {
          case 0:
            _nudgeSpeed(1);
          case 1:
            _nudgeEpisode(1);
          case 2:
            _nudgeLine(1);
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.space) {
        _applySettingsSelection();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    _revealControls();

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(const Duration(seconds: -10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(const Duration(seconds: 10));
      return KeyEventResult.handled;
    }
    // 上键 / 菜单键：打开设置（电视遥控进面板）
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.contextMenu) {
      _openSettings();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      _next();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      _prev();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final pos = c?.value.position ?? Duration.zero;
    final dur = c?.value.duration ?? Duration.zero;
    final playing = c?.value.isPlaying ?? false;
    final progress = dur.inMilliseconds <= 0
        ? 0.0
        : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (showSettings) {
              _closePanels();
              return;
            }
            if (showControls) {
              _togglePlay();
            } else {
              _revealControls();
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (ready && c != null)
                Center(
                  child: AspectRatio(
                    aspectRatio: c.value.aspectRatio == 0
                        ? 16 / 9
                        : c.value.aspectRatio,
                    child: VideoPlayer(c),
                  ),
                )
              else if (error != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          alignment: WrapAlignment.center,
                          children: [
                            Focusable(
                              autofocus: true,
                              onTap: () => _open(allowLineFallback: true),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 12),
                                color: AppTheme.accent,
                                child: const Text('重试',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w700)),
                              ),
                            ),
                            if (_hasMultiLine)
                              Focusable(
                                onTap: () => _openSettings(tab: 2),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 20, vertical: 12),
                                  color: const Color(0xFF1A2740),
                                  child: const Text('换线路',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w700)),
                                ),
                              ),
                            if (widget.hasNextSource)
                              Focusable(
                                onTap: () {
                                  _saveProgress();
                                  Navigator.pop(
                                      context, PlayerScreen.popNextSource);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 20, vertical: 12),
                                  color: const Color(0xFF1A2740),
                                  child: const Text('换下一源',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w700)),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                )
              else
                const Center(child: CircularProgressIndicator()),

              // 顶部 / 底部控制条
              IgnorePointer(
                ignoring: !showControls && !showSettings,
                child: AnimatedOpacity(
                  opacity: (showControls || showSettings) ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Stack(
                    children: [
                      const Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.center,
                              colors: [
                                Color(0xCC000000),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                      const Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.center,
                              colors: [
                                Color(0xE6000000),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 20,
                        right: 20,
                        top: 16,
                        child: Row(
                          children: [
                            Focusable(
                              scale: 1.05,
                              borderRadius: 999,
                              glass: false,
                              onTap: () => Navigator.pop(context),
                              child: const Padding(
                                padding: EdgeInsets.all(10),
                                child: Icon(Icons.arrow_back,
                                    color: Colors.white, size: 26),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 18,
                                    ),
                                  ),
                                  Text(
                                    _lineLabel.isEmpty
                                        ? _epLabel
                                        : '$_epLabel · $_lineLabel',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${speed == speed.roundToDouble() ? speed.toInt() : speed}x',
                              style: const TextStyle(
                                color: AppTheme.neon,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        left: 24,
                        right: 24,
                        bottom: 28,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Text(_fmt(pos),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 13)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 4,
                                      thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 7),
                                      overlayShape:
                                          const RoundSliderOverlayShape(
                                              overlayRadius: 14),
                                      activeTrackColor: AppTheme.accent,
                                      inactiveTrackColor:
                                          Colors.white24,
                                      thumbColor: Colors.white,
                                    ),
                                    child: Slider(
                                      value: progress,
                                      onChanged: (v) {
                                        if (c == null ||
                                            !c.value.isInitialized ||
                                            dur <= Duration.zero) {
                                          return;
                                        }
                                        final t = Duration(
                                          milliseconds:
                                              (dur.inMilliseconds * v).round(),
                                        );
                                        c.seekTo(t);
                                        _revealControls();
                                      },
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(_fmt(dur),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 13)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                _CtrlBtn(
                                  icon: Icons.replay_10,
                                  label: '-10s',
                                  onTap: () =>
                                      _seekBy(const Duration(seconds: -10)),
                                ),
                                _CtrlBtn(
                                  icon: Icons.skip_previous,
                                  label: '上一集',
                                  onTap: index > 0 ? _prev : null,
                                ),
                                _CtrlBtn(
                                  icon: playing
                                      ? Icons.pause_circle_filled
                                      : Icons.play_circle_filled,
                                  label: playing ? '暂停' : '播放',
                                  big: true,
                                  onTap: _togglePlay,
                                ),
                                _CtrlBtn(
                                  icon: Icons.skip_next,
                                  label: '下一集',
                                  onTap: index < _episodes.length - 1
                                      ? () => _next()
                                      : null,
                                ),
                                _CtrlBtn(
                                  icon: Icons.forward_10,
                                  label: '+10s',
                                  onTap: () =>
                                      _seekBy(const Duration(seconds: 10)),
                                ),
                                const Spacer(),
                                _CtrlBtn(
                                  icon: Icons.settings,
                                  label: '设置',
                                  onTap: () {
                                    if (showSettings) {
                                      _closePanels();
                                    } else {
                                      _openSettings();
                                    }
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              showSettings
                                  ? '设置：左右切页 · 上下选择 · 确认应用 · 返回关闭'
                                  : '确认播停 · 左右快进退 · 上键/菜单打开设置',
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 统一设置面板：倍速 / 选集 / 线路
              if (showSettings)
                Positioned(
                  top: 56,
                  right: 0,
                  bottom: 120,
                  width: (MediaQuery.sizeOf(context).width * 0.34)
                      .clamp(280.0, 400.0),
                  child: Material(
                    color: const Color(0xF50B1220),
                    child: SafeArea(
                      left: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
                            child: Row(
                              children: [
                                const Expanded(
                                  child: Text('播放设置',
                                      style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w900)),
                                ),
                                GestureDetector(
                                  onTap: _closePanels,
                                  child: const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Icon(Icons.close,
                                        color: Colors.white70),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                            child: Row(
                              children: [
                                for (var t = 0; t < _tabCount; t++)
                                  Expanded(
                                    child: Padding(
                                      padding: EdgeInsets.only(
                                          right: t < _tabCount - 1 ? 8 : 0),
                                      child: GestureDetector(
                                        onTap: () {
                                          setState(() => settingsTab = t);
                                          if (t == 1) {
                                            WidgetsBinding.instance
                                                .addPostFrameCallback(
                                                    (_) => _ensureEpVisible());
                                          }
                                        },
                                        child: AnimatedContainer(
                                          duration: const Duration(
                                              milliseconds: 120),
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 10),
                                          decoration: BoxDecoration(
                                            color: settingsTab == t
                                                ? AppTheme.accent
                                                : const Color(0xFF121A2B),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            border: Border.all(
                                              color: settingsTab == t
                                                  ? AppTheme.neon
                                                  : Colors.transparent,
                                              width: 2,
                                            ),
                                          ),
                                          alignment: Alignment.center,
                                          child: Text(
                                            t == 0
                                                ? '倍速'
                                                : t == 1
                                                    ? '选集'
                                                    : '线路',
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 13),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
                            child: Text('左右切页 · 上下选择 · 确认应用',
                                style: TextStyle(
                                    color: Colors.white54, fontSize: 11)),
                          ),
                          Expanded(child: _buildSettingsBody()),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    );
  }

  Widget _buildSettingsBody() {
    if (settingsTab == 0) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [
          for (var i = 0; i < _speeds.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                onTap: () => _setSpeed(_speeds[i]),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: i == _speedCursor
                        ? AppTheme.accent
                        : (_speeds[i] == speed
                            ? const Color(0xFF1A2740)
                            : const Color(0xFF121A2B)),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color:
                          i == _speedCursor ? AppTheme.neon : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Text(
                    _speeds[i] == 1.0 ? '1.0x 正常' : '${_speeds[i]}x',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    if (settingsTab == 2 && _hasMultiLine) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [
          for (var i = 0; i < _lines.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                onTap: () => _applyLine(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: i == _lineCursor
                        ? AppTheme.accent
                        : (i == _lineIndex
                            ? const Color(0xFF1A2740)
                            : const Color(0xFF121A2B)),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color:
                          i == _lineCursor ? AppTheme.neon : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Text(
                    _lines[i].looksLike4k
                        ? '★ ${_lines[i].name}'
                        : _lines[i].name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    // 选集
    return ListView.builder(
      controller: _epScroll,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      itemCount: _episodes.length,
      itemBuilder: (_, i) {
        final e = _episodes[i];
        final label = e.name.trim().isNotEmpty ? e.name : '第${i + 1}集';
        final playingNow = i == index;
        final focused = i == _epCursor;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GestureDetector(
            onTap: () => _playIndex(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: focused
                    ? AppTheme.accent
                    : (playingNow
                        ? const Color(0xFF1A2740)
                        : const Color(0xFF121A2B)),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: focused ? AppTheme.neon : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CtrlBtn extends StatelessWidget {
  const _CtrlBtn({
    required this.icon,
    required this.label,
    this.onTap,
    this.big = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Focusable(
        scale: 1.06,
        borderRadius: 12,
        glass: false,
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.35,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: big ? 14 : 12,
              vertical: big ? 10 : 8,
            ),
            color: const Color(0x66121A2B),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: big ? 34 : 22),
                const SizedBox(height: 2),
                Text(label,
                    style: TextStyle(
                      fontSize: big ? 12 : 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white70,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
