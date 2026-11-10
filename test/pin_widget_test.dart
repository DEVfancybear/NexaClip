import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:nexaclip/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class RemovedBeforePinStore extends TextHistoryStore {
  RemovedBeforePinStore(super.database);

  @override
  Future<void> setPinned(int id, bool pinned) async {
    // Simulate retention removing the row after the UI loaded it.
    await database.delete('text_history', where: 'id = ?', whereArgs: [id]);
    await super.setPinned(id, pinned);
  }
}

void main() {
  testWidgets('pin and unpin with confirmation', (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_pin_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('synthetic pin', DateTime.utc(2026));
      await db.close();
    });
    Future<void> waitFor(bool Function() condition) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !condition(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(condition(), isTrue);
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory)));
      await waitFor(() => find.byTooltip('Ghim').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Ghim'));
      await waitFor(() => find.byTooltip('Bỏ ghim').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Bỏ ghim'));
      await tester.pumpAndSettle();
      expect(find.textContaining('500 mục không ghim'), findsOneWidget);
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Bỏ ghim'), findsOneWidget);
      await tester.tap(find.byTooltip('Bỏ ghim'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bỏ ghim'));
      await waitFor(() => find.byTooltip('Ghim').evaluate().isNotEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
    }
  });

  testWidgets('reports when an entry disappears before pinning',
      (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_pin_race_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('expired synthetic item', DateTime.utc(2026));
      await db.close();
    });
    Future<void> waitFor(bool Function() condition) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !condition(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(condition(), isTrue);
    }

    try {
      await tester.pumpWidget(MaterialApp(
        home: ClipboardHomePage(
          supportDirectory: () async => directory,
          storeFactory: RemovedBeforePinStore.new,
        ),
      ));
      await waitFor(() => find.byTooltip('Ghim').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Ghim'));
      await waitFor(() => find
          .textContaining('Mục lịch sử không còn tồn tại')
          .evaluate()
          .isNotEmpty);
      expect(find.text('expired synthetic item'), findsNothing);
      expect(find.byTooltip('Ghim'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
    }
  });
}
