import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/models.dart';
import '../services/phone_config_server.dart';
import '../services/settings_store.dart';
import '../services/usb_config_importer.dart';
import '../services/vod_service.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String nameDraft = '';
  String urlDraft = '';
  /// custom_i -> 探测结果；null=未测，>=0 毫秒，-1 失败
  final Map<String, int> _probeMs = {};
  bool _probing = false;

  @override
  void dispose() {
    PhoneConfigServer.stop();
    super.dispose();
  }

  Future<void> _pickFeedMode(SettingsStore store) async {
    final enabled = store.enabledSources;
    final pick = await showDialog<({String mode, String? code})>(
      context: context,
      builder: (ctx) {
        Widget opt({
          required String label,
          required String desc,
          required String mode,
          String? code,
          bool autofocus = false,
        }) {
          final selected = store.feedMode == mode &&
              (mode != SettingsStore.feedSource ||
                  code == store.feedSourceCode);
          // glow:false：描边画在项内，不放大、无外扩光晕 → 不会被列表裁切，也不会画出弹窗
          return Padding(
            padding: const EdgeInsets.only(bottom: 8, right: 4),
            child: Focusable(
              autofocus: autofocus,
              scale: 1.0,
              glow: false,
              borderRadius: 10,
              glass: false,
              onTap: () => Navigator.pop(ctx, (mode: mode, code: code)),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                color: selected
                    ? AppTheme.accent.withValues(alpha: 0.35)
                    : const Color(0xFF0E1626),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 15)),
                    const SizedBox(height: 4),
                    Text(desc,
                        style: const TextStyle(
                            color: AppTheme.textDim, fontSize: 12, height: 1.3)),
                  ],
                ),
              ),
            ),
          );
        }

        final maxH = MediaQuery.sizeOf(ctx).height * 0.55;
        return AlertDialog(
          backgroundColor: AppTheme.bgElevated,
          title: const Text('推荐数据来源'),
          content: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 480, maxHeight: maxH),
            child: Scrollbar(
              thumbVisibility: true,
              thickness: 6,
              radius: const Radius.circular(3),
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(right: 2, bottom: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    opt(
                      label: '豆瓣',
                      desc: '首页 Billboard / 发现筛选（形态·类型·地区）',
                      mode: SettingsStore.feedDouban,
                      autofocus: store.useDoubanFeed,
                    ),
                    if (enabled.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          '还没有启用采集源。先勾选源，再选下面某一源作推荐。',
                          style:
                              TextStyle(color: AppTheme.textDim, fontSize: 12),
                        ),
                      )
                    else ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(2, 8, 2, 6),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text('采集源（仅单源，发现页显示该源分类）',
                              style: TextStyle(
                                  color: AppTheme.textDim,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12)),
                        ),
                      ),
                      for (final code in enabled)
                        opt(
                          label: store.resolveSource(code)?.name ?? code,
                          desc: '首页最新 + 发现页该源分类',
                          mode: SettingsStore.feedSource,
                          code: code,
                          autofocus:
                              store.feedMode == SettingsStore.feedSource &&
                                  store.feedSourceCode == code,
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          actions: [
            Focusable(
              scale: 1.04,
              borderRadius: 8,
              glass: false,
              onTap: () => Navigator.pop(ctx),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Text('取消', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        );
      },
    );
    if (pick == null || !mounted) return;
    await store.setFeedMode(pick.mode, sourceCode: pick.code);
    _toast('推荐数据已改为：${store.feedModeLabel}');
  }

  Future<void> _probeAll(SettingsStore store) async {
    if (_probing || store.customApis.isEmpty) return;
    setState(() {
      _probing = true;
      _probeMs.clear();
    });
    final vod = VodService(store);
    final codes = [
      for (var i = 0; i < store.customApis.length; i++) 'custom_$i',
    ];
    // 并发别太大：Web 代理 + 弱源站容易误超时
    const batch = 2;
    for (var i = 0; i < codes.length; i += batch) {
      final end = (i + batch > codes.length) ? codes.length : i + batch;
      final chunk = codes.sublist(i, end);
      final results = await Future.wait(chunk.map((c) async {
        final ms = await vod.probeSource(c);
        return MapEntry(c, ms ?? -1);
      }));
      if (!mounted) return;
      setState(() {
        for (final e in results) {
          _probeMs[e.key] = e.value;
        }
      });
    }
    if (!mounted) return;
    setState(() => _probing = false);
    final ok = _probeMs.values.where((v) => v >= 0).length;
    final bad = _probeMs.values.where((v) => v < 0).length;
    _toast(bad > 0
        ? '探测完成：可用 $ok · 失败 $bad（拉 videolist 超时/非 JSON 算失败；可再测一次）'
        : '探测完成：全部可用 $ok');
  }

  List<String> get _failedProbeCodes => _probeMs.entries
      .where((e) => e.value < 0)
      .map((e) => e.key)
      .toList();

  Future<void> _deleteFailed(SettingsStore store) async {
    final failed = _failedProbeCodes;
    if (failed.isEmpty) {
      _toast('没有探测失败的源');
      return;
    }
    final n = failed.length;
    await store.removeCustomApisByCodes(failed);
    if (!mounted) return;
    setState(() => _probeMs.clear());
    _toast('已删除 $n 个失败源');
  }

  Future<void> _deleteOne(SettingsStore store, int index) async {
    await store.removeCustomApi(index);
    if (!mounted) return;
    // 探测结果按索引存，删一条后整表作废，避免张冠李戴
    setState(() => _probeMs.clear());
  }

  Future<void> _add(SettingsStore store) async {
    final name = nameDraft.trim();
    final url = urlDraft.trim();
    if (url.isEmpty) {
      _toast('请先填写采集源 API 地址');
      return;
    }
    await store.addCustomApi(CustomApi(
      name: name.isEmpty ? '自定义源' : name,
      url: url.replaceAll(RegExp(r'/+$'), ''),
    ));
    setState(() {
      nameDraft = '';
      urlDraft = '';
    });
    _toast('已添加采集源');
  }

  Future<String?> _promptText({
    required String title,
    required String initial,
    String hint = '',
    int maxLines = 1,
  }) async {
    final ctrl = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            maxLines: maxLines,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText: hint,
              filled: true,
              fillColor: AppTheme.panel,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        actions: [
          Focusable(
            scale: 1.04,
            borderRadius: 8,
            glass: false,
            onTap: () => Navigator.pop(ctx, false),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text('取消', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
          Focusable(
            // 不要和 TextField 抢 autofocus，否则电视遥控难从输入框移到按钮
            scale: 1.04,
            borderRadius: 8,
            glass: false,
            onTap: () => Navigator.pop(ctx, true),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: AppTheme.accent,
              child: const Text('确定',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
    );
    final text = ctrl.text;
    ctrl.dispose();
    if (ok == true) return text;
    return null;
  }

  Future<void> _importJsonPaste(SettingsStore store) async {
    final text = await _promptText(
      title: '粘贴配置 JSON',
      initial: '',
      maxLines: 12,
      hint: '{"sources":[{"name":"xx","url":"https://..."}]}',
    );
    if (text == null) return;
    try {
      await store.importConfigJson(text);
      _toast('导入成功');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  Future<void> _applyImport(
    SettingsStore store,
    UsbImportResult r,
  ) async {
    if (!r.ok || r.text == null) {
      _toast(r.message);
      return;
    }
    try {
      await store.importConfigJson(r.text!);
      _toast(r.message.isNotEmpty ? '${r.message}，导入成功' : '导入成功');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  Future<void> _importUsb(SettingsStore store) async {
    if (kIsWeb) {
      _toast('请选择配置文件…');
      await _applyImport(store, await UsbConfigImporter.import());
      return;
    }

    _toast('正在扫描 U 盘（最多约 6 秒）…');
    final r = await UsbConfigImporter.import();
    if (r.ok && r.text != null) {
      await _applyImport(store, r);
      return;
    }

    if (!mounted) return;
    // 扫描不到时：电视上文件选择器常无界面，改用剪贴板 / 路径 / 粘贴
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: const Text('未扫到配置文件'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                r.message,
                style: const TextStyle(color: AppTheme.textDim, height: 1.45),
              ),
              const SizedBox(height: 12),
              const Text(
                '请把 veliora-sources.json 放到 U 盘根目录后重试；'
                '或用下方方式导入。',
                style: TextStyle(color: AppTheme.textDim, height: 1.45),
              ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.start,
        actions: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Focusable(
                autofocus: true,
                scale: 1.04,
                borderRadius: 8,
                glass: false,
                onTap: () => Navigator.pop(ctx, 'clipboard'),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  color: AppTheme.accent,
                  child: const Text('从剪贴板导入',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
              Focusable(
                scale: 1.04,
                borderRadius: 8,
                glass: false,
                onTap: () => Navigator.pop(ctx, 'paste'),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  color: const Color(0xFF24344D),
                  child: const Text('粘贴 JSON',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
              Focusable(
                scale: 1.04,
                borderRadius: 8,
                glass: false,
                onTap: () => Navigator.pop(ctx, 'path'),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  color: const Color(0xFF24344D),
                  child: const Text('输入文件路径',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
              Focusable(
                scale: 1.04,
                borderRadius: 8,
                glass: false,
                onTap: () => Navigator.pop(ctx, 'retry'),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  color: const Color(0xFF24344D),
                  child: const Text('再扫一次',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
              Focusable(
                scale: 1.04,
                borderRadius: 8,
                glass: false,
                onTap: () => Navigator.pop(ctx, 'cancel'),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child:
                      Text('取消', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (action == null || action == 'cancel') return;
    if (action == 'retry') {
      await _importUsb(store);
      return;
    }
    if (action == 'clipboard') {
      await _applyImport(store, await UsbConfigImporter.fromClipboard());
      return;
    }
    if (action == 'paste') {
      await _importJsonPaste(store);
      return;
    }
    if (action == 'path') {
      final path = await _promptText(
        title: '配置文件路径',
        initial: '',
        hint: '/storage/XXXX-XXXX/veliora-sources.json',
      );
      if (path == null) return;
      await _applyImport(store, await UsbConfigImporter.fromPath(path));
    }
  }

  Future<void> _phoneQr(SettingsStore store) async {
    if (!PhoneConfigServer.supported) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.bgElevated,
          title: const Text('手机扫码添加'),
          content: const Text(
            '当前环境无法开局域网服务时，请用「U盘导入」或「粘贴 JSON」。',
            style: TextStyle(height: 1.5, color: AppTheme.textDim),
          ),
          actions: [
            Focusable(
              autofocus: true,
              scale: 1.04,
              borderRadius: 8,
              glass: false,
              onTap: () => Navigator.pop(ctx),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: AppTheme.accent,
                child: const Text('知道了',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      );
      return;
    }

    try {
      await store.ensureReady();
      final urls = await PhoneConfigServer.start(
        getConfig: () => store.exportConfigJson(),
        applyConfig: (body) async {
          // 稍作让出，避免 HTTP 回调里同步刷 UI / 写 prefs 卡死连接
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await store.importConfigJson(body);
        },
      );
      if (!mounted) return;
      if (urls.isEmpty) {
        _toast('未找到局域网 IP，请确认已连接 Wi‑Fi');
        await PhoneConfigServer.stop();
        return;
      }
      final primary = urls.first;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.bgElevated,
          title: const Text('手机扫码添加源'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '请用手机浏览器扫描下方二维码（与电视同一 Wi‑Fi）。'
                  '可逐条添加，也可切到「粘贴 JSON」直接导入后点保存。',
                  style: TextStyle(color: AppTheme.textDim, height: 1.45),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: primary,
                    size: 200,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 14),
                SelectableText(
                  primary,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.neon,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            Focusable(
              autofocus: true,
              scale: 1.04,
              borderRadius: 8,
              glass: false,
              onTap: () async {
                await PhoneConfigServer.stop();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: AppTheme.accent,
                child: const Text('完成',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      );
      await PhoneConfigServer.stop();
    } catch (e) {
      await PhoneConfigServer.stop();
      _toast('启动失败：$e');
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    // 电视：整页单一焦点遍历组，避免输入框/开关抢走方向键
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 8, 28, 48),
        children: [
          const Text('设置',
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          const Text(
            '管理采集源与推荐开关 · 用方向键移动，确认键选择',
            style: TextStyle(color: AppTheme.textDim, fontSize: 14),
          ),
          const SizedBox(height: 22),

          // 功能开关置顶：源多时不用翻到最底才能改推荐
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionHead(
                  icon: Icons.tune,
                  title: '功能开关',
                ),
                _TvActionRow(
                  order: 1,
                  autofocus: true,
                  icon: Icons.recommend_outlined,
                  title: '推荐数据',
                  subtitle: '当前：${store.feedModeLabel}（首页 / 发现）',
                  onTap: () => _pickFeedMode(store),
                ),
                _TvSwitchRow(
                  order: 2,
                  title: '过滤敏感分类',
                  subtitle: '隐藏伦理/福利等分类（看成人源请关掉）',
                  value: store.yellowFilterEnabled,
                  onChanged: store.setYellow,
                ),
                _TvSwitchRow(
                  order: 3,
                  title: '过滤片中广告',
                  subtitle: '改写 m3u8，去掉中插博彩等分片（仅 HLS 有效）',
                  value: store.adFilteringEnabled,
                  onChanged: store.setAdFiltering,
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionHead(
                  icon: Icons.cloud_outlined,
                  title: '已添加采集源',
                  trailing: Text(
                    '${store.customApis.length}',
                    style: const TextStyle(
                      color: AppTheme.neon,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '探测依据：请求各源 ?ac=videolist&pg=1（和搜片同一接口），'
                  '12 秒内返回带 list 的 JSON 算可用；失败会自动重试 1 次。'
                  '不稳定多半是源站慢或 Web 代理抖动，建议失败后再测一遍，不要一次删光。',
                  style: TextStyle(
                    color: AppTheme.textDim,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 10),
                if (store.customApis.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: FocusTraversalOrder(
                            order: const NumericFocusOrder(9.5),
                            child: Focusable(
                              scale: 1.03,
                              borderRadius: 10,
                              glass: false,
                              onTap:
                                  _probing ? null : () => _probeAll(store),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 12),
                                color: const Color(0xFF152238),
                                child: Text(
                                  _probing ? '正在检测…' : '检测全部源',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: _probing
                                        ? AppTheme.textDim
                                        : AppTheme.neon,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (_failedProbeCodes.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: FocusTraversalOrder(
                              order: const NumericFocusOrder(9.6),
                              child: Focusable(
                                scale: 1.03,
                                borderRadius: 10,
                                glass: false,
                                onTap: _probing
                                    ? null
                                    : () => _deleteFailed(store),
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 12),
                                  color: const Color(0xFF2A1218),
                                  child: Text(
                                    '删除失败源(${_failedProbeCodes.length})',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: AppTheme.danger,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                if (store.customApis.isEmpty)
                  const Text(
                    '暂无采集源。请用下方「手机扫码 / U盘导入 / 粘贴 JSON / 手动填写」。',
                    style: TextStyle(color: AppTheme.textDim, height: 1.45),
                  )
                else
                  for (var i = 0; i < store.customApis.length; i++)
                    _SourceTile(
                      order: 10.0 + i,
                      api: store.customApis[i],
                      selected: store.selectedApis.contains('custom_$i'),
                      probeMs: _probeMs['custom_$i'],
                      onToggle: () async {
                        final code = 'custom_$i';
                        final next = [...store.selectedApis];
                        if (next.contains(code)) {
                          next.remove(code);
                        } else {
                          next.add(code);
                        }
                        await store.setSelected(next);
                      },
                      onDelete: () => _deleteOne(store, i),
                    ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionHead(
                  icon: Icons.add_circle_outline,
                  title: '添加自定义源',
                ),
                const SizedBox(height: 12),
                // 竖排大按钮：遥控器上下最好走（不内置采集源，需自行添加）
                _TvActionRow(
                  order: 20,
                  icon: Icons.qr_code_2,
                  title: '手机扫码',
                  subtitle: '同一 Wi‑Fi 扫码添加',
                  accent: AppTheme.neon,
                  onTap: () => _phoneQr(store),
                ),
                _TvActionRow(
                  order: 21,
                  icon: Icons.usb,
                  title: 'U盘导入',
                  subtitle: kIsWeb
                      ? '选择 JSON 文件'
                      : '扫描 U 盘根目录 veliora-sources.json',
                  accent: AppTheme.neon2,
                  onTap: () => _importUsb(store),
                ),
                _TvActionRow(
                  order: 22,
                  icon: Icons.content_paste,
                  title: '粘贴 JSON',
                  subtitle: '打开输入框粘贴配置',
                  onTap: () => _importJsonPaste(store),
                ),
                _TvActionRow(
                  order: 23,
                  icon: Icons.copy_all_outlined,
                  title: '复制导出',
                  subtitle: '导出当前源列表到剪贴板',
                  onTap: () async {
                    await Clipboard.setData(
                        ClipboardData(text: store.exportConfigJson()));
                    _toast('配置已复制到剪贴板');
                  },
                ),
                const SizedBox(height: 16),
                const Text(
                  '手动填写',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textDim,
                  ),
                ),
                const SizedBox(height: 10),
                _TvActionRow(
                  order: 30,
                  icon: Icons.badge_outlined,
                  title: '名称（可选）',
                  subtitle: nameDraft.isEmpty ? '点确认后输入' : nameDraft,
                  onTap: () async {
                    final v = await _promptText(
                      title: '源名称',
                      initial: nameDraft,
                      hint: '例如：暴风资源',
                    );
                    if (v != null) setState(() => nameDraft = v.trim());
                  },
                ),
                _TvActionRow(
                  order: 31,
                  icon: Icons.link,
                  title: 'API 地址',
                  subtitle: urlDraft.isEmpty
                      ? '必填 · …/api.php/provide/vod'
                      : urlDraft,
                  onTap: () async {
                    final v = await _promptText(
                      title: 'API 地址',
                      initial: urlDraft,
                      hint: 'https://example.com/api.php/provide/vod',
                    );
                    if (v != null) setState(() => urlDraft = v.trim());
                  },
                ),
                const SizedBox(height: 8),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(32),
                  child: Focusable(
                    scale: 1.04,
                    borderRadius: 10,
                    glass: false,
                    onTap: () => _add(store),
                    child: Container(
                      width: double.infinity,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      color: AppTheme.accent,
                      child: const Text(
                        '添加采集源',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: child,
    );
  }
}

class _SectionHead extends StatelessWidget {
  const _SectionHead({
    required this.icon,
    required this.title,
    this.trailing,
  });
  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.neon, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _TvActionRow extends StatelessWidget {
  const _TvActionRow({
    required this.order,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.accent,
    this.autofocus = false,
  });

  final double order;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? accent;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = accent ?? AppTheme.neon;
    return FocusTraversalOrder(
      order: NumericFocusOrder(order),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Focusable(
          autofocus: autofocus,
          scale: 1.03,
          borderRadius: 12,
          glass: false,
          onTap: onTap,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            color: const Color(0xFF0E1626),
            child: Row(
              children: [
                Icon(icon, color: c, size: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textDim,
                          fontSize: 13,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppTheme.textDim),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TvSwitchRow extends StatelessWidget {
  const _TvSwitchRow({
    required this.order,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final double order;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return FocusTraversalOrder(
      order: NumericFocusOrder(order),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Focusable(
          scale: 1.02,
          borderRadius: 12,
          glass: false,
          onTap: () => onChanged(!value),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            color: const Color(0xFF0E1626),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text(subtitle,
                          style: const TextStyle(
                              color: AppTheme.textDim, fontSize: 13)),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: value
                        ? AppTheme.neon.withValues(alpha: 0.22)
                        : Colors.white10,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: value
                          ? AppTheme.neon
                          : Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  child: Text(
                    value ? '开' : '关',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: value ? AppTheme.neon : AppTheme.textDim,
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
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.order,
    required this.api,
    required this.selected,
    required this.onToggle,
    required this.onDelete,
    this.probeMs,
  });

  final double order;
  final CustomApi api;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  /// null 未测；>=0 成功毫秒；-1 失败
  final int? probeMs;

  @override
  Widget build(BuildContext context) {
    final failed = probeMs != null && probeMs! < 0;
    final ok = probeMs != null && probeMs! >= 0;
    String status;
    Color statusColor;
    if (failed) {
      status = '探测失败 · 建议关掉';
      statusColor = AppTheme.danger;
    } else if (ok) {
      status =
          '${selected ? '已启用' : '未启用'} · ${probeMs}ms';
      statusColor = selected ? AppTheme.neon : AppTheme.textDim;
    } else {
      status = selected ? '已启用 · 确认可关闭' : '未启用 · 确认可打开';
      statusColor = selected ? AppTheme.neon : AppTheme.textDim;
    }

    // 失败源略降透明度，但仍要能点「删除」（别灰到看不见）
    return Opacity(
      opacity: failed ? 0.72 : 1,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Expanded(
              child: FocusTraversalOrder(
                order: NumericFocusOrder(order),
                child: Focusable(
                  scale: 1.02,
                  borderRadius: 10,
                  glass: false,
                  onTap: onToggle,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    color: failed
                        ? const Color(0xFF1A1014)
                        : const Color(0xFF0E1626),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(api.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(
                          api.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppTheme.textDim, fontSize: 12),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          status,
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FocusTraversalOrder(
              order: NumericFocusOrder(order + 0.1),
              child: Focusable(
                scale: 1.04,
                borderRadius: 10,
                glass: false,
                onTap: onDelete,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 18),
                  color: const Color(0xFF2A1218),
                  child: const Text('删除',
                      style: TextStyle(
                          color: AppTheme.danger,
                          fontWeight: FontWeight.w800)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
