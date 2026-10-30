import 'package:flutter_test/flutter_test.dart';
import 'package:yingshi_daquan/main.dart';
import 'package:yingshi_daquan/services/settings_store.dart';

void main() {
  testWidgets('app builds', (tester) async {
    final store = SettingsStore();
    // skip prefs load in unit test environment
    await tester.pumpWidget(YingshiApp(store: store));
    expect(find.text('影视聚合'), findsOneWidget);
  });
}
