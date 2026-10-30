import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'screens/shell_screen.dart';
import 'services/settings_store.dart';
import 'theme/app_theme.dart';
import 'widgets/remote_keyboard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 电视上 setPreferredOrientations 偶发卡住，加超时且失败不阻塞启动
  try {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]).timeout(const Duration(seconds: 2));
  } catch (_) {}

  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)
        .timeout(const Duration(seconds: 1));
  } catch (_) {}

  final store = SettingsStore();
  // 先启动 UI，配置异步加载，避免 SharedPreferences 卡住导致白屏。
  // 各处读写会 ensureReady()，不会再踩 LateInitializationError。
  runApp(YingshiApp(store: store));
  unawaited(store.ensureReady().catchError((Object e, StackTrace st) {
    debugPrint('SettingsStore bootstrap failed: $e\n$st');
  }));
}

class YingshiApp extends StatelessWidget {
  const YingshiApp({super.key, required this.store});
  final SettingsStore store;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(
        title: '影视聚合',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        // 全局遥控快捷键，覆盖 Dialog 等路由（不能只包在 Shell 里）
        shortcuts: RemoteKeyboardScope.shortcuts,
        actions: RemoteKeyboardScope.actions,
        builder: (context, child) {
          // 电视端保证有可绘制底色；遥控垫也盖住弹窗层
          return ColoredBox(
            color: AppTheme.bg,
            child: RemoteKeyboardScope(
              child: child ?? const SizedBox.shrink(),
            ),
          );
        },
        home: const ShellScreen(),
      ),
    );
  }
}
