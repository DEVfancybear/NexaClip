import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:nexaclip/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('capture failure remains visible through other actions',
      (tester) async {
    sqfliteFfiInit();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('nexaclip/clipboard');
    final starts = <int>[];
    var stopCalls = 0;
    final gate = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        starts.add(call.arguments as int);
        if (starts.length == 2) await gate.future;
      }
      if (call.method == 'stop' && ++stopCalls == 1) {
        throw PlatformException(code: 'capture_delivery_failed');
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
        SystemChannels.platform, (_) async => null);
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_warning_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('synthetic item', DateTime.utc(2026));
      await db.close();
    });
    Future<void> waitFor(Finder finder) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      expect(finder, findsOneWidget);
    }

    Future<void> warning(int generation) async {
      final response = Completer<ByteData?>();
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(MethodCall('captureFailed', generation)),
          response.complete);
      const StandardMethodCodec().decodeEnvelope((await response.future)!);
      await tester.pump();
    }

    final notice =
        find.textContaining('Theo dõi clipboard đã dừng do lỗi hàng đợi');
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory)));
      await waitFor(find.text('synthetic item'));
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await tester.pumpAndSettle();
      await warning(starts.single);
      expect(notice, findsOneWidget);
      await tester.tap(find.byTooltip('Sao chép'));
      await tester.pumpAndSettle();
      expect(notice, findsOneWidget);
      await tester.tap(find.text('Dừng theo dõi'));
      await tester.pumpAndSettle();
      expect(notice, findsOneWidget);
      final startButton = find.widgetWithText(FilledButton, 'Bắt đầu theo dõi');
      for (var i = 0;
          i < 100 && tester.widget<FilledButton>(startButton).onPressed == null;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(tester.widget<FilledButton>(startButton).onPressed, isNotNull);
      await tester.tap(startButton);
      for (var i = 0; i < 100 && starts.length < 2; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(starts.length, 2);
      expect(stopCalls, 2);
      await warning(starts.last);
      gate.complete();
      await tester.pumpAndSettle();
      expect(notice, findsOneWidget);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 25; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });
}
