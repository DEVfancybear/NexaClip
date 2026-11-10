import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:nexaclip/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class HeldDeleteStore extends TextHistoryStore {
  HeldDeleteStore(super.database, this.started, this.release);
  final Completer<void> started;
  final Completer<void> release;

  @override
  Future<void> delete(int id) async {
    started.complete();
    await release.future;
    await super.delete(id);
  }
}

class FailOnceDeleteStore extends TextHistoryStore {
  FailOnceDeleteStore(super.database);
  bool fail = true;

  @override
  Future<void> delete(int id) async {
    if (fail) {
      fail = false;
      throw StateError('synthetic delete failure');
    }
    await super.delete(id);
  }
}

void main() {
  testWidgets('delete selected pinned item after confirmation', (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_delete_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('pinned synthetic', DateTime.utc(2026));
      final id = (await store.list()).single.id;
      await store.setPinned(id, true);
      await store.add('other synthetic', DateTime.utc(2026, 1, 2));
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
      await waitFor(() => find.text('pinned synthetic').evaluate().isNotEmpty);
      await tester.enterText(find.byType(TextField), 'pinned');
      await tester.pump();
      expect(find.text('other synthetic'), findsNothing);
      await tester.tap(find.byTooltip('Xóa mục'));
      await tester.pumpAndSettle();
      expect(find.textContaining('đã được ghim'), findsOneWidget);
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(find.text('pinned synthetic'), findsOneWidget);
      await tester.tap(find.byTooltip('Xóa mục'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
      await waitFor(() => find.text('pinned synthetic').evaluate().isEmpty);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(find.text('other synthetic'), findsOneWidget);
      await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(
          '${directory.path}${Platform.pathSeparator}history.db',
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final entries = await TextHistoryStore(db).list();
        expect(entries.map((e) => e.text), ['other synthetic']);
        await db.close();
      });
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
    }
  });

  testWidgets('exit is canceled while deletion is pending', (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    final started = Completer<void>();
    final release = Completer<void>();
    await tester.runAsync(() async {
      directory =
          await Directory.systemTemp.createTemp('nexaclip_delete_exit_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('synthetic held', DateTime.utc(2026));
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
          storeFactory: (db) => HeldDeleteStore(db, started, release),
        ),
      ));
      await waitFor(() => find.byTooltip('Xóa mục').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Xóa mục'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
      await waitFor(() => started.isCompleted);
      AppExitResponse? result;
      tester.binding.handleRequestAppExit().then((value) => result = value);
      await waitFor(() => result != null);
      expect(result, AppExitResponse.cancel);
      expect(find.text('synthetic held'), findsOneWidget);
      release.complete();
      await waitFor(() => find.text('synthetic held').evaluate().isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
    }
  });

  testWidgets('failed delete keeps item and allows retry', (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory =
          await Directory.systemTemp.createTemp('nexaclip_delete_fail_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('synthetic retry', DateTime.utc(2026));
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
          storeFactory: FailOnceDeleteStore.new,
        ),
      ));
      await waitFor(() => find.byTooltip('Xóa mục').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Xóa mục'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
      await waitFor(() => find
          .textContaining('synthetic delete failure')
          .evaluate()
          .isNotEmpty);
      expect(find.text('synthetic retry'), findsOneWidget);
      await tester.tap(find.byTooltip('Xóa mục'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
      await waitFor(() => find.text('synthetic retry').evaluate().isEmpty);
      expect(find.textContaining('synthetic delete failure'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
    }
  });
}
