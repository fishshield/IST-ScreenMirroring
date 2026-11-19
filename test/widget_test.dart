import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/app.dart';

void main() {
  testWidgets('renders the merged device list and opens the about page',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const ScreenCastApp());

    expect(find.text('Screen Cast'), findsOneWidget);
    expect(find.text('设备与连接'), findsOneWidget);
    expect(find.text('扫描设备'), findsOneWidget);
    expect(find.text('尚未发现设备'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The three transport modes and the PSK field were removed from the UI.
    expect(find.text('无线'), findsNothing);
    expect(find.text('直连'), findsNothing);
    expect(find.text('手机局域网 IP'), findsNothing);
    expect(find.text('预共享密钥 PSK（hex，可选）'), findsNothing);

    // Persisted switches are visible and off by default.
    expect(find.byKey(const Key('auto-connect-switch')), findsOneWidget);
    expect(find.byKey(const Key('limit-60fps-switch')), findsOneWidget);

    // Architecture/preview texts moved to the about page.
    expect(find.text('渲染边界'), findsNothing);
    await tester.tap(find.byKey(const Key('open-about')));
    await tester.pumpAndSettle();
    expect(find.text('渲染边界'), findsOneWidget);
    expect(find.text('实时预览'), findsOneWidget);
    expect(find.text('Android 画面，Windows 原生呈现'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
