import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexaclip/main.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
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
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
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
      await tester.runAsync(() async {
        final db = await databaseFactoryFfi
            .openDatabase('${dir.path}${Platform.pathSeparator}history.db');
        expect((await TextHistoryStore(db).list()).map((e) => e.text),
            contains('synthetic pending'));
        await db.close();
      });
    } finally {
      if (!release.isCompleted) release.complete();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
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
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('shows the initial screen', (tester) async {
    await tester.pumpWidget(const ClipboardApp());

    expect(find.text('NexaClip'), findsOneWidget);
    expect(find.text('Lịch sử văn bản'), findsOneWidget);
    expect(
      find.text(
          'Lịch sử văn bản được lưu trên máy mà không mã hóa. Nội dung có thể chứa mật khẩu hoặc thông tin nhạy cảm.'),
      findsOneWidget,
    );
    expect(find.text('Bắt đầu theo dõi'), findsOneWidget);
    expect(find.text('Chưa có lịch sử văn bản.'), findsOneWidget);
  });
}
