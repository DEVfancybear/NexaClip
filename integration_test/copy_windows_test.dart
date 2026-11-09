import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:nexaclip/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('copy invokes Windows clipboard without starting capture',
      (tester) async {
    sqfliteFfiInit();
    final directory =
        await Directory.systemTemp.createTemp('nexaclip_copy_windows_');
    const text = 'NexaClip synthetic copy đ 😀\nsecond line';
    try {
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add(text, DateTime.utc(2026));
      await db.close();
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory)));
      for (var i = 0; i < 100 && find.text(text).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text(text), findsOneWidget);
      expect(find.text('Bắt đầu theo dõi'), findsOneWidget);
      await tester.tap(find.byTooltip('Sao chép'));
      for (var i = 0;
          i < 100 && find.text('Đã sao chép vào clipboard.').evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Đã sao chép vào clipboard.'), findsOneWidget);
      expect(find.textContaining('Có lỗi:'), findsNothing);
      expect(find.text('Bắt đầu theo dõi'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await directory.delete(recursive: true);
    }
  });
}
