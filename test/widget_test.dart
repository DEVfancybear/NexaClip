import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:nexaclip/main.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

class FailingRefreshStore extends TextHistoryStore {
  FailingRefreshStore(super.database);
  bool cleared = false;

  @override
  Future<void> clear() async {
    await super.clear();
    cleared = true;
  }

  @override
  Future<List<TextHistoryEntry>> list() {
    if (cleared) throw StateError('refresh failed');
    return super.list();
  }
}

class DelayedRefreshStore extends TextHistoryStore {
  DelayedRefreshStore(
      super.database, this.started, this.release, this.returned);
  final Completer<void> started;
  final Completer<void> release;
  final Completer<void> returned;
  int calls = 0;
  @override
  Future<List<TextHistoryEntry>> list() async {
    final items = await super.list();
    if (++calls == 2) {
      started.complete();
      await release.future;
      returned.complete();
    }
    return items;
  }
}

class FailingClearStore extends TextHistoryStore {
  FailingClearStore(super.database);
  @override
  Future<void> clear() async => throw StateError('synthetic delete failure');
}

class FailedHeldWriteStore extends TextHistoryStore {
  FailedHeldWriteStore(super.database, this.started, this.release);
  final Completer<void> started;
  final Completer<void> release;
  @override
  Future<void> add(String text, DateTime copiedAt) async {
    started.complete();
    await release.future;
    throw StateError('synthetic write failure');
  }
}

class HeldWriteStore extends TextHistoryStore {
  HeldWriteStore(super.database, this.started, this.release);
  final Completer<void> started;
  final Completer<void> release;
  @override
  Future<void> add(String text, DateTime copiedAt) async {
    started.complete();
    await release.future;
    await super.add(text, copiedAt);
  }
}

class BlockingExitObserver with WidgetsBindingObserver {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    entered.complete();
    await release.future;
    return AppExitResponse.exit;
  }
}

void main() {
  testWidgets('disposed observer safely handles delayed binding exit',
      (tester) async {
    final observer = BlockingExitObserver();
    final directory = Completer<Directory>();
    tester.binding.addObserver(observer);
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () => directory.future)));
      AppExitResponse? response;
      tester.binding.handleRequestAppExit().then((value) => response = value);
      await tester.pump();
      expect(observer.entered.isCompleted, isTrue);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      observer.release.complete();
      await tester.pump();
      expect(response, AppExitResponse.exit);
      expect(tester.takeException(), isNull);
    } finally {
      if (!observer.release.isCompleted) observer.release.complete();
      tester.binding.removeObserver(observer);
    }
  });

  testWidgets('clear confirmation removes persisted history', (tester) async {
    late Directory directory;
    sqfliteFfiInit();
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_widget_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('saved item', DateTime.utc(2026));
      await db.close();
    });
    try {
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory),
        ));
        for (var i = 0;
            i < 100 && find.text('saved item').evaluate().isEmpty;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      expect(find.text('saved item'), findsOneWidget);
      await tester.tap(find.text('Xóa toàn bộ lịch sử'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(find.text('saved item'), findsOneWidget);
      await tester.tap(find.text('Xóa toàn bộ lịch sử'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 && find.text('saved item').evaluate().isNotEmpty;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      expect(find.text('saved item'), findsNothing);
      expect(find.text('Chưa có lịch sử clipboard.'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final db = await databaseFactoryFfi.openDatabase(
            '${directory.path}${Platform.pathSeparator}history.db');
        expect(await TextHistoryStore(db).list(), isEmpty);
        await db.close();
      });
    } finally {
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });

  testWidgets('shows persisted history on startup', (tester) async {
    late Directory directory;
    sqfliteFfiInit();
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_widget_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('saved item', DateTime.utc(2026));
      await db.close();
    });
    try {
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory),
        ));
        for (var i = 0;
            i < 100 && find.text('saved item').evaluate().isEmpty;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      expect(find.text('saved item'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
    } finally {
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });

  testWidgets('clear removes visible history even if refresh fails',
      (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_refresh_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('old secret', DateTime.utc(2026));
      await db.close();
    });
    try {
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
            home: ClipboardHomePage(
          supportDirectory: () async => directory,
          storeFactory: FailingRefreshStore.new,
        )));
        for (var i = 0;
            i < 100 && find.text('old secret').evaluate().isEmpty;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      expect(find.text('old secret'), findsOneWidget);
      await tester.tap(find.text('Xóa toàn bộ lịch sử'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 && find.textContaining('refresh failed').evaluate().isEmpty;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      expect(find.text('old secret'), findsNothing);
      expect(find.textContaining('refresh failed'), findsOneWidget);
    } finally {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await directory.delete(recursive: true);
      });
    }
  });

  testWidgets('exit is cancelled while initialization is in progress',
      (tester) async {
    final directory = Completer<Directory>();
    await tester.pumpWidget(MaterialApp(
      home: ClipboardHomePage(supportDirectory: () => directory.future),
    ));
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
    await tester.pumpWidget(const SizedBox());
    directory.completeError(StateError('test cleanup'));
    await tester.pump();
  });

  testWidgets('clear confirmation does not overlap pending exit',
      (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async =>
        dir = await Directory.systemTemp.createTemp('nexaclip_dialog_exit_'));
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await tester.runAsync(() async {
      final db = await databaseFactoryFfi
          .openDatabase('${dir.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('synthetic retained', DateTime.utc(2026));
      await db.close();
    });
    final stopGate = Completer<void>();
    var stops = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop') {
        stops++;
        await stopGate.future;
      }
      return null;
    });
    Future<void> waitFor(bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(done(), isTrue);
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => dir)));
      await waitFor(() =>
          tester
              .widget<FilledButton>(find.byType(FilledButton).first)
              .onPressed !=
          null);
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await waitFor(() => find.text('Dừng theo dõi').evaluate().isNotEmpty);
      await tester.tap(find.text('Xóa toàn bộ lịch sử'));
      await tester.pumpAndSettle();
      AppExitResponse? result;
      tester.binding.handleRequestAppExit().then((value) => result = value);
      await waitFor(() => stops == 1);
      await tester.tap(find.text('Xóa'));
      await tester.pumpAndSettle();
      expect(stops, 1);
      expect(result, isNull);
      stopGate.complete();
      await waitFor(() => result != null);
      expect(result, AppExitResponse.exit);
      expect(stops, 1);
      await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(
          '${dir.path}${Platform.pathSeparator}history.db',
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final store = TextHistoryStore(db);
        expect((await store.list()).map((entry) => entry.text),
            contains('synthetic retained'));
        await db.close();
      });
    } finally {
      if (!stopGate.isCompleted) stopGate.complete();
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('exit retries a failed listener stop', (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async =>
        dir = await Directory.systemTemp.createTemp('nexaclip_exit_'));
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    var stops = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'stop' && ++stops == 1) {
        throw PlatformException(code: 'listener_failed');
      }
      return null;
    });
    Future<void> waitFor(bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(done(), isTrue);
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => dir)));
      await waitFor(() =>
          tester
              .widget<FilledButton>(find.byType(FilledButton).first)
              .onPressed !=
          null);
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await waitFor(() => find.text('Dừng theo dõi').evaluate().isNotEmpty);
      AppExitResponse? result;
      tester.binding.handleRequestAppExit().then((value) => result = value);
      await waitFor(() => result != null);
      expect(result, AppExitResponse.cancel);
      expect(find.textContaining('listener_failed'), findsOneWidget);
      result = null;
      tester.binding.handleRequestAppExit().then((value) => result = value);
      await waitFor(() => result != null);
      expect(result, AppExitResponse.exit);
      expect(calls, ['start', 'stop', 'stop']);
    } finally {
      stops = 1;
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('shows oversized clipboard text warning', (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async =>
        dir = await Directory.systemTemp.createTemp('nexaclip_warning_'));
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    Future<void> waitFor(bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(done(), isTrue);
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => dir)));
      await waitFor(() =>
          tester
              .widget<FilledButton>(find.byType(FilledButton).first)
              .onPressed !=
          null);
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await waitFor(() => find.text('Dừng theo dõi').evaluate().isNotEmpty);
      final data = const StandardMethodCodec().encodeMethodCall(
          const MethodCall('changed', {'textTooLarge': true}));
      tester.binding.defaultBinaryMessenger
          .handlePlatformMessage(channel.name, data, (_) {});
      await waitFor(() => find
          .textContaining('Văn bản clipboard vượt 1 MiB')
          .evaluate()
          .isNotEmpty);
      await tester.tap(find.text('Dừng theo dõi'));
      await waitFor(() => find.text('Bắt đầu theo dõi').evaluate().isNotEmpty);
    } finally {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets(
      'retains both warnings when an oversized text accompanies a corrupt image',
      (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async =>
        dir = await Directory.systemTemp.createTemp('nexaclip_warning_'));
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    Future<void> waitFor(bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(done(), isTrue);
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => dir)));
      await waitFor(() =>
          tester
              .widget<FilledButton>(find.byType(FilledButton).first)
              .onPressed !=
          null);
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await waitFor(() => find.text('Dừng theo dõi').evaluate().isNotEmpty);
      final data =
          const StandardMethodCodec().encodeMethodCall(MethodCall('changed', {
        'textTooLarge': true,
        'png': Uint8List.fromList([1, 2, 3])
      }));
      tester.binding.defaultBinaryMessenger
          .handlePlatformMessage(channel.name, data, (_) {});
      await waitFor(() =>
          find.textContaining('Ảnh PNG không hợp lệ').evaluate().isNotEmpty);
      expect(
          find.textContaining('Văn bản clipboard vượt 1 MiB'), findsOneWidget);
      await tester.tap(find.text('Dừng theo dõi'));
      await waitFor(() => find.text('Bắt đầu theo dõi').evaluate().isNotEmpty);
    } finally {
      if (find.text('Dừng theo dõi').evaluate().isNotEmpty) {
        await tester.tap(find.text('Dừng theo dõi'));
        await waitFor(
            () => find.text('Bắt đầu theo dõi').evaluate().isNotEmpty);
      }
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  for (final closeBeforeThrow in [false, true]) {
    testWidgets(
        'close failure disables actions and exit can retry ($closeBeforeThrow)',
        (tester) async {
      sqfliteFfiInit();
      late Directory dir;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('nexaclip_close_failure_');
        final db = await databaseFactoryFfi
            .openDatabase('${dir.path}${Platform.pathSeparator}history.db');
        final store = TextHistoryStore(db);
        await store.initialize();
        await store.add('close failure item', DateTime.utc(2026));
        await db.close();
      });
      var attempts = 0;
      try {
        await tester.pumpWidget(MaterialApp(
            home: ClipboardHomePage(
          supportDirectory: () async => dir,
          closeDatabase: (db) async {
            attempts++;
            if (attempts == 1) {
              if (closeBeforeThrow) await db.close();
              throw StateError('synthetic close failure');
            }
            await db.close();
          },
        )));
        await tester.runAsync(() async {
          for (var i = 0;
              i < 100 && find.text('close failure item').evaluate().isEmpty;
              i++) {
            await tester.pump();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
        expect(find.text('close failure item'), findsOneWidget);
        Future<AppExitResponse?> requestExit() async {
          AppExitResponse? result;
          tester.binding.handleRequestAppExit().then((value) => result = value);
          await tester.runAsync(() async {
            for (var i = 0; i < 100 && result == null; i++) {
              await tester.pump();
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          });
          return result;
        }

        expect(await requestExit(), AppExitResponse.cancel);
        expect(find.textContaining('synthetic close failure'), findsOneWidget);
        expect(
            tester
                .widget<FilledButton>(find.byType(FilledButton).first)
                .onPressed,
            isNull);
        expect(
            tester
                .widget<IconButton>(find.byWidgetPredicate(
                    (w) => w is IconButton && w.tooltip == 'Xóa mục'))
                .onPressed,
            isNull);
        expect(
            tester
                .widget<IconButton>(find.byWidgetPredicate(
                    (w) => w is IconButton && w.tooltip == 'Sao chép'))
                .onPressed,
            isNull);
        expect(await requestExit(), AppExitResponse.exit);
        expect(attempts, closeBeforeThrow ? 1 : 2);
      } finally {
        await tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox());
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await dir.delete(recursive: true);
        });
      }
    });
  }

  testWidgets('dispose waits for listener stop before closing', (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async =>
        dir = await Directory.systemTemp.createTemp('nexaclip_exit_stop_'));
    late Future<AppExitResponse> Function() requestExit;
    final stopStarted = Completer<void>();
    final stopGate = Completer<void>();
    final closeStarted = Completer<void>();
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop') {
        if (!stopStarted.isCompleted) stopStarted.complete();
        await stopGate.future;
      }
      return null;
    });
    Future<void> waitFor(bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(done(), isTrue);
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(
        supportDirectory: () async => dir,
        onExitCallbackReady: (callback) => requestExit = callback,
        closeDatabase: (db) async {
          closeStarted.complete();
          await db.close();
        },
      )));
      await waitFor(() =>
          tester
              .widget<FilledButton>(find.byType(FilledButton).first)
              .onPressed !=
          null);
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await waitFor(() => find.text('Dừng theo dõi').evaluate().isNotEmpty);
      AppExitResponse? result;
      requestExit().then((value) => result = value);
      await waitFor(() => stopStarted.isCompleted);
      await tester.runAsync(() => tester.pumpWidget(const SizedBox()));
      expect(closeStarted.isCompleted, isFalse);
      stopGate.complete();
      await waitFor(() => result != null);
      expect(result, AppExitResponse.exit);
      expect(closeStarted.isCompleted, isTrue);
    } finally {
      if (!stopGate.isCompleted) stopGate.complete();
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await dir.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('dispose waits for an in-flight exit close', (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async =>
        dir = await Directory.systemTemp.createTemp('nexaclip_exit_dispose_'));
    late Future<AppExitResponse> Function() requestExit;
    final closeStarted = Completer<void>();
    final closeGate = Completer<void>();
    var closeCalls = 0;
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(
        supportDirectory: () async => dir,
        onExitCallbackReady: (callback) => requestExit = callback,
        closeDatabase: (db) async {
          closeCalls++;
          closeStarted.complete();
          await closeGate.future;
          await db.close();
        },
      )));
      await tester.runAsync(() async {
        for (var i = 0; i < 100; i++) {
          await tester.pump();
          if (tester
                  .widget<FilledButton>(find.byType(FilledButton).first)
                  .onPressed !=
              null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      final exit = requestExit();
      await tester.runAsync(() => closeStarted.future);
      await tester.runAsync(() => tester.pumpWidget(const SizedBox()));
      expect(closeCalls, 1);
      closeGate.complete();
      final response = await tester.runAsync(() => exit);
      expect(response, AppExitResponse.exit);
      expect(closeCalls, 1);
    } finally {
      if (!closeGate.isCompleted) closeGate.complete();
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await dir.delete(recursive: true);
      });
    }
  });

  testWidgets('exit waits for an outstanding history refresh', (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async =>
        dir = await Directory.systemTemp.createTemp('nexaclip_exit_refresh_'));
    final started = Completer<void>();
    final release = Completer<void>();
    final returned = Completer<void>();
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    Future<void> waitFor(bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(done(), isTrue);
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(
        supportDirectory: () async => dir,
        storeFactory: (db) =>
            DelayedRefreshStore(db, started, release, returned),
      )));
      await waitFor(() =>
          tester
              .widget<FilledButton>(find.byType(FilledButton).first)
              .onPressed !=
          null);
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await waitFor(() => find.text('Dừng theo dõi').evaluate().isNotEmpty);
      final data = const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('changed', 'refresh pending'));
      messenger.handlePlatformMessage(channel.name, data, (_) {});
      await waitFor(() => started.isCompleted);
      AppExitResponse? result;
      tester.binding.handleRequestAppExit().then((value) => result = value);
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(result, isNull);
      release.complete();
      await waitFor(() => result != null);
      expect(returned.isCompleted, isTrue);
      expect(result, AppExitResponse.exit);
    } finally {
      if (!release.isCompleted) release.complete();
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('exit waits for pending history write', (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async =>
        dir = await Directory.systemTemp.createTemp('nexaclip_drain_'));
    Database? appDatabase;
    final started = Completer<void>();
    final release = Completer<void>();
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    Future<void> waitFor(bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(done(), isTrue);
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(
        supportDirectory: () async => dir,
        storeFactory: (db) {
          appDatabase = db;
          return HeldWriteStore(db, started, release);
        },
      )));
      await waitFor(() =>
          tester
              .widget<FilledButton>(find.byType(FilledButton).first)
              .onPressed !=
          null);
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await waitFor(() => find.text('Dừng theo dõi').evaluate().isNotEmpty);
      final data = const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('changed', 'synthetic pending'));
      tester.binding.defaultBinaryMessenger
          .handlePlatformMessage('nexaclip/clipboard', data, (_) {});
      await waitFor(() => started.isCompleted);
      AppExitResponse? result;
      tester.binding.handleRequestAppExit().then((value) => result = value);
      await tester.runAsync(() async {
        for (var i = 0; i < 10; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(result, isNull);
      release.complete();
      await waitFor(() => result != null);
      expect(result, AppExitResponse.exit);
      expect(appDatabase!.isOpen, isFalse);
      await tester.runAsync(() async {
        final db = await databaseFactoryFfi
            .openDatabase('${dir.path}${Platform.pathSeparator}history.db');
        expect((await TextHistoryStore(db).list()).map((e) => e.text),
            contains('synthetic pending'));
        await db.close();
      });
    } finally {
      if (!release.isCompleted) release.complete();
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('exit cancels when a pending write fails', (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async =>
        dir = await Directory.systemTemp.createTemp('nexaclip_fail_exit_'));
    final started = Completer<void>();
    final release = Completer<void>();
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    Future<void> waitFor(bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(done(), isTrue);
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(
        supportDirectory: () async => dir,
        storeFactory: (db) => HeldWriteStore(db, started, release),
      )));
      await waitFor(() =>
          tester
              .widget<FilledButton>(find.byType(FilledButton).first)
              .onPressed !=
          null);
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await waitFor(() => find.text('Dừng theo dõi').evaluate().isNotEmpty);
      final data = const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('changed', 'synthetic failure'));
      messenger.handlePlatformMessage(channel.name, data, (_) {});
      await waitFor(() => started.isCompleted);
      AppExitResponse? result;
      tester.binding.handleRequestAppExit().then((value) => result = value);
      await tester.runAsync(() async {
        for (var i = 0; i < 5; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(result, isNull);
      release.completeError(StateError('synthetic write failure'));
      await waitFor(() => result != null);
      expect(result, AppExitResponse.cancel);
      expect(find.textContaining('synthetic write failure'), findsOneWidget);
    } finally {
      if (!release.isCompleted) release.complete();
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('clear drains an active pending write and leaves no saved item',
      (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async =>
        dir = await Directory.systemTemp.createTemp('nexaclip_clear_active_'));
    final started = Completer<void>();
    final release = Completer<void>();
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    Future<void> waitFor(bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(done(), isTrue);
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(
        supportDirectory: () async => dir,
        storeFactory: (db) => HeldWriteStore(db, started, release),
      )));
      await waitFor(() =>
          tester
              .widget<FilledButton>(find.byType(FilledButton).first)
              .onPressed !=
          null);
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await waitFor(() => find.text('Dừng theo dõi').evaluate().isNotEmpty);
      final data = const StandardMethodCodec().encodeMethodCall(
          const MethodCall('changed', 'synthetic pending clear'));
      messenger.handlePlatformMessage(channel.name, data, (_) {});
      await waitFor(() => started.isCompleted);
      await tester.tap(find.text('Xóa toàn bộ lịch sử'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(find.text('Dừng theo dõi'), findsOneWidget);
      expect(calls, ['start']);
      await tester.tap(find.text('Xóa toàn bộ lịch sử'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
      await waitFor(() => calls.contains('stop'));
      await tester.pump();
      expect(
          tester
              .widget<TextButton>(
                  find.widgetWithText(TextButton, 'Xóa toàn bộ lịch sử'))
              .onPressed,
          isNull);
      release.complete();
      await waitFor(() =>
          tester
              .widget<TextButton>(
                  find.widgetWithText(TextButton, 'Xóa toàn bộ lịch sử'))
              .onPressed !=
          null);
      expect(find.text('Bắt đầu theo dõi'), findsOneWidget);
      expect(find.text('synthetic pending clear'), findsNothing);
      await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(
          '${dir.path}${Platform.pathSeparator}history.db',
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(await TextHistoryStore(db).list(), isEmpty);
        await db.close();
      });
    } finally {
      if (!release.isCompleted) release.complete();
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('failed delete keeps visible and persisted history',
      (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('nexaclip_delete_failure_');
      final db = await databaseFactoryFfi
          .openDatabase('${dir.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('synthetic saved', DateTime.utc(2026));
      await db.close();
    });
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(
              supportDirectory: () async => dir,
              storeFactory: FailingClearStore.new)));
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 && find.text('synthetic saved').evaluate().isEmpty;
            i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('synthetic saved'), findsOneWidget);
      await tester.tap(find.text('Xóa toàn bộ lịch sử'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 &&
                find
                    .textContaining('synthetic delete failure')
                    .evaluate()
                    .isEmpty;
            i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.textContaining('synthetic delete failure'), findsOneWidget);
      expect(find.text('synthetic saved'), findsOneWidget);
      await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(
          '${dir.path}${Platform.pathSeparator}history.db',
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
            (await TextHistoryStore(db).list()).single.text, 'synthetic saved');
        await db.close();
      });
    } finally {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
    }
  });

  testWidgets('failed listener stop prevents clear and retry succeeds',
      (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('nexaclip_clear_stop_');
      final db = await databaseFactoryFfi
          .openDatabase('${dir.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('synthetic saved', DateTime.utc(2026));
      await db.close();
    });
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var stops = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop' && ++stops == 1) {
        throw PlatformException(code: 'listener_failed');
      }
      return null;
    });
    Future<void> waitFor(bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(done(), isTrue);
    }

    Future<void> confirm() async {
      await tester.tap(find.text('Xóa toàn bộ lịch sử'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => dir)));
      await waitFor(() => find.text('synthetic saved').evaluate().isNotEmpty);
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await waitFor(() => find.text('Dừng theo dõi').evaluate().isNotEmpty);
      await confirm();
      await waitFor(
          () => find.textContaining('listener_failed').evaluate().isNotEmpty);
      expect(find.text('synthetic saved'), findsOneWidget);
      await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(
          '${dir.path}${Platform.pathSeparator}history.db',
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
            (await TextHistoryStore(db).list()).single.text, 'synthetic saved');
        await db.close();
      });
      await tester.pumpAndSettle();
      await waitFor(() =>
          tester
              .widget<TextButton>(
                  find.widgetWithText(TextButton, 'Xóa toàn bộ lịch sử'))
              .onPressed !=
          null);
      await confirm();
      await waitFor(() => find.text('synthetic saved').evaluate().isEmpty);
      expect(stops, 2);
      await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(
          '${dir.path}${Platform.pathSeparator}history.db',
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(await TextHistoryStore(db).list(), isEmpty);
        await db.close();
      });
    } finally {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('failed pending write aborts clear and retry removes history',
      (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('nexaclip_clear_write_');
      final db = await databaseFactoryFfi
          .openDatabase('${dir.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add('synthetic saved', DateTime.utc(2026));
      await db.close();
    });
    final started = Completer<void>();
    final release = Completer<void>();
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    Future<void> waitFor(bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(done(), isTrue);
    }

    Future<void> confirm() async {
      await tester.tap(find.text('Xóa toàn bộ lịch sử'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(
        supportDirectory: () async => dir,
        storeFactory: (db) => FailedHeldWriteStore(db, started, release),
      )));
      await waitFor(() => find.text('synthetic saved').evaluate().isNotEmpty);
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await waitFor(() => find.text('Dừng theo dõi').evaluate().isNotEmpty);
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
              const MethodCall('changed', 'synthetic failed write')),
          (_) {});
      await waitFor(() => started.isCompleted);
      await confirm();
      await tester.pump();
      release.complete();
      await waitFor(() =>
          find.textContaining('synthetic write failure').evaluate().isNotEmpty);
      await waitFor(() =>
          tester
              .widget<TextButton>(
                  find.widgetWithText(TextButton, 'Xóa toàn bộ lịch sử'))
              .onPressed !=
          null);
      expect(find.text('synthetic saved'), findsOneWidget);
      await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(
            '${dir.path}${Platform.pathSeparator}history.db',
            options: OpenDatabaseOptions(singleInstance: false));
        expect(
            (await TextHistoryStore(db).list()).single.text, 'synthetic saved');
        await db.close();
      });
      await confirm();
      await waitFor(() => find.text('synthetic saved').evaluate().isEmpty);
      await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(
            '${dir.path}${Platform.pathSeparator}history.db',
            options: OpenDatabaseOptions(singleInstance: false));
        expect(await TextHistoryStore(db).list(), isEmpty);
        await db.close();
      });
    } finally {
      if (!release.isCompleted) release.complete();
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('delayed old refresh cannot restore cleared history',
      (tester) async {
    sqfliteFfiInit();
    late Directory dir;
    await tester.runAsync(() async =>
        dir = await Directory.systemTemp.createTemp('nexaclip_stale_refresh_'));
    final started = Completer<void>();
    final release = Completer<void>();
    final returned = Completer<void>();
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    Future<void> waitFor(bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(done(), isTrue);
    }

    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(
        supportDirectory: () async => dir,
        storeFactory: (db) =>
            DelayedRefreshStore(db, started, release, returned),
      )));
      await waitFor(() =>
          tester
              .widget<FilledButton>(find.byType(FilledButton).first)
              .onPressed !=
          null);
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await waitFor(() => find.text('Dừng theo dõi').evaluate().isNotEmpty);
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
              const MethodCall('changed', 'synthetic old refresh')),
          (_) {});
      await waitFor(() => started.isCompleted);
      await tester.tap(find.text('Xóa toàn bộ lịch sử'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
      await waitFor(() => find.text('Bắt đầu theo dõi').evaluate().isNotEmpty);
      await waitFor(() =>
          tester
              .widget<TextButton>(
                  find.widgetWithText(TextButton, 'Xóa toàn bộ lịch sử'))
              .onPressed !=
          null);
      release.complete();
      await waitFor(() => returned.isCompleted);
      await tester.pump();
      expect(find.text('synthetic old refresh'), findsNothing);
      await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(
            '${dir.path}${Platform.pathSeparator}history.db',
            options: OpenDatabaseOptions(singleInstance: false));
        expect(await TextHistoryStore(db).list(), isEmpty);
        await db.close();
      });
    } finally {
      if (!release.isCompleted) release.complete();
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('shows the initial screen', (tester) async {
    await tester.pumpWidget(const ClipboardApp());

    expect(find.text('NexaClip'), findsOneWidget);
    expect(find.text('Lịch sử clipboard'), findsOneWidget);
    expect(
      find.text(
          'Lịch sử văn bản và ảnh được lưu trên máy mà không mã hóa. Nội dung có thể chứa mật khẩu hoặc thông tin nhạy cảm.'),
      findsOneWidget,
    );
    expect(find.text('Bắt đầu theo dõi'), findsOneWidget);
    expect(find.text('Chưa có lịch sử clipboard.'), findsOneWidget);
  });
}
