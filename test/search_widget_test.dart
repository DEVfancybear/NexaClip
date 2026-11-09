import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:nexaclip/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('search filters history and clearing the query restores it',
      (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_search_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('Xin Chào Việt Nam', DateTime.utc(2026));
      await store.add('Other item', DateTime.utc(2026));
      await store.add('one\ntwo\nthree\nfour needle', DateTime.utc(2026));
      await db.close();
    });
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory)));
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 && find.text('Other item').evaluate().isEmpty;
            i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('Xin Chào Việt Nam'), findsOneWidget);
      expect(find.text('Other item'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'CHÀO');
      await tester.pump();
      expect(find.text('Xin Chào Việt Nam'), findsOneWidget);
      expect(find.text('Other item'), findsNothing);
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.pump();
      expect(
          tester
              .widget<Text>(find.text('one\ntwo\nthree\nfour needle'))
              .maxLines,
          isNull);
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pump();
      expect(find.text('Không tìm thấy kết quả.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(find.text('Xin Chào Việt Nam'), findsOneWidget);
      expect(find.text('Other item'), findsOneWidget);
    } finally {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
    }
  });
  testWidgets('active search updates after capture and clear', (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async => directory =
        await Directory.systemTemp.createTemp('nexaclip_search_live_'));
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    Future<void> waitFor(bool Function() predicate) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !predicate(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(predicate(), isTrue);
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory)));
      await waitFor(() =>
          tester
              .widget<FilledButton>(find.byType(FilledButton).first)
              .onPressed !=
          null);
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await waitFor(() => find.text('Dừng theo dõi').evaluate().isNotEmpty);
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
              const MethodCall('changed', 'synthetic needle')),
          (_) {});
      await waitFor(() => find.text('synthetic needle').evaluate().isNotEmpty);
      await tester.tap(find.text('Xóa toàn bộ lịch sử'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
      await waitFor(() => find.text('synthetic needle').evaluate().isEmpty);
      await waitFor(() =>
          tester
              .widget<TextButton>(
                  find.widgetWithText(TextButton, 'Xóa toàn bộ lịch sử'))
              .onPressed !=
          null);
      expect(find.text('Không tìm thấy kết quả.'), findsOneWidget);
      expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text ??
              tester
                  .widget<EditableText>(find.byType(EditableText))
                  .controller
                  .text,
          'needle');
    } finally {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
