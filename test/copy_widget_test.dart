import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:nexaclip/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('copies selected full text and reports failures', (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    const value = 'Dữ liệu thử\nfull text';
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_copy_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add(value, DateTime.utc(2026));
      await store.add('another synthetic item', DateTime.utc(2026, 1, 2));
      await db.close();
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var fail = false;
    Completer<void>? gate;
    final values = <String>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        if (fail) throw PlatformException(code: 'copy_failed');
        values.add((call.arguments as Map)['text'] as String);
        await gate?.future;
      }
      return null;
    });
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory)));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && find.text(value).evaluate().isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text(value), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'full text');
      await tester.pump();
      expect(find.text('another synthetic item'), findsNothing);
      await tester.tap(find.byTooltip('Sao chép'));
      await tester.pump();
      expect(values, [value]);
      expect(find.text('Đã sao chép vào clipboard.'), findsOneWidget);
      fail = true;
      await tester.tap(find.byTooltip('Sao chép'));
      await tester.pump();
      expect(find.textContaining('copy_failed'), findsOneWidget);
      expect(values, [value]);
      fail = false;
      await tester.tap(find.byTooltip('Sao chép'));
      await tester.pump();
      expect(find.textContaining('copy_failed'), findsNothing);
      expect(values, [value, value]);
      gate = Completer<void>();
      final copyButton = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Sao chép',
      );
      final button = tester.widget<IconButton>(copyButton);
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(values, [value, value, value]);
      expect(tester.widget<IconButton>(copyButton).onPressed, isNull);
      final exit = await tester.binding.handleRequestAppExit();
      expect(exit, AppExitResponse.cancel);
      gate.complete();
      await tester.pump();
      expect(tester.widget<IconButton>(copyButton).onPressed, isNotNull);
    } finally {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    }
  });
}
