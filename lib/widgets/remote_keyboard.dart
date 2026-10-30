import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// PC/Web 键盘当遥控器：方向键移动焦点、Enter 确认、Esc 返回。
/// （右下角触控垫已按需求隐藏，快捷键仍全局生效）
class RemoteKeyboardScope extends StatelessWidget {
  const RemoteKeyboardScope({super.key, required this.child});

  final Widget child;

  static final Map<ShortcutActivator, Intent> shortcuts = {
    ...WidgetsApp.defaultShortcuts,
    const SingleActivator(LogicalKeyboardKey.arrowUp):
        const DirectionalFocusIntent(TraversalDirection.up),
    const SingleActivator(LogicalKeyboardKey.arrowDown):
        const DirectionalFocusIntent(TraversalDirection.down),
    const SingleActivator(LogicalKeyboardKey.arrowLeft):
        const DirectionalFocusIntent(TraversalDirection.left),
    const SingleActivator(LogicalKeyboardKey.arrowRight):
        const DirectionalFocusIntent(TraversalDirection.right),
    const SingleActivator(LogicalKeyboardKey.numpad8):
        const DirectionalFocusIntent(TraversalDirection.up),
    const SingleActivator(LogicalKeyboardKey.numpad2):
        const DirectionalFocusIntent(TraversalDirection.down),
    const SingleActivator(LogicalKeyboardKey.numpad4):
        const DirectionalFocusIntent(TraversalDirection.left),
    const SingleActivator(LogicalKeyboardKey.numpad6):
        const DirectionalFocusIntent(TraversalDirection.right),
    const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
    const SingleActivator(LogicalKeyboardKey.numpadEnter):
        const ActivateIntent(),
    const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
  };

  static final Map<Type, Action<Intent>> actions = {
    ...WidgetsApp.defaultActions,
    DirectionalFocusIntent: DirectionalFocusAction(),
  };

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: actions,
        child: child,
      ),
    );
  }
}
