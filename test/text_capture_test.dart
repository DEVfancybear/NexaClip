import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/text_capture.dart';
import 'package:nexaclip/clipboard/text_history_recorder.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:nexaclip/clipboard/windows_clipboard_source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('captures events while active and stops listening after stop', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = TextHistoryStore(db);
    await store.initialize();
    final events = StreamController<String?>.broadcast(sync: true);
    final errors = <Object>[];
    final capture = TextCapture(TextHistoryRecorder(store),
        onError: (error, _) => errors.add(error));
    try {
      capture.start(events.stream);
      expect(capture.isActive, isTrue);
      expect(() => capture.start(events.stream), throwsStateError);
      events.add('saved');
      await capture.stop();
      expect(capture.isActive, isFalse);
      events.add('not saved');
      expect((await store.list()).map((entry) => entry.text), ['saved']);
      expect(errors, isEmpty);
    } finally {
      await capture.stop();
      await events.close();
      await db.close();
    }
  });

  test('reports an onRecorded callback failure', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = TextHistoryStore(db);
    await store.initialize();
    final events = StreamController<Object?>(sync: true);
    final reported = Completer<Object>();
    final capture = TextCapture(TextHistoryRecorder(store),
        onError: (error, _) => reported.complete(error),
        onRecorded: () => throw StateError('callback failed'));
    try {
      capture.start(events.stream);
      events.add('synthetic');
      expect(
          (await reported.future.timeout(const Duration(seconds: 5)))
              .toString(),
          contains('callback failed'));
      await capture.stop();
      expect((await store.list()).single.text, 'synthetic');
    } finally {
      await capture.stop();
      await events.close();
      await db.close();
    }
  });

  test('captures a combined snapshot with invalid image as text', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = TextHistoryStore(db);
    await store.initialize();
    final events = StreamController<Object?>(sync: true);
    final errors = <Object>[];
    var notifications = 0;
    final capture = TextCapture(TextHistoryRecorder(store),
        onError: (error, _) => errors.add(error),
        onRecorded: () => notifications++);
    try {
      capture.start(events.stream);
      events.add(
          ClipboardImageWithText(Uint8List.fromList([1, 2, 3]), 'fallback'));
      await capture.stop();
      expect((await store.list()).single.text, 'fallback');
      expect(notifications, 1);
      expect(errors, isEmpty);
    } finally {
      await events.close();
      await db.close();
    }
  });

  test('stop waits for an image write already in progress', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = GatedImageStore(db);
    await store.initialize();
    final events = StreamController<Object?>.broadcast(sync: true);
    final errors = <Object>[];
    final capture = TextCapture(TextHistoryRecorder(store),
        onError: (error, _) => errors.add(error));
    try {
      capture.start(events.stream);
      events.add(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='));
      await store.started.future.timeout(const Duration(seconds: 5));
      var stopped = false;
      final stopping = capture.stop().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      store.release.complete();
      await stopping;
      expect((await store.list()).single.isImage, isTrue);
      expect(errors, isEmpty);
    } finally {
      if (!store.release.isCompleted) store.release.complete();
      await capture.stop();
      await events.close();
      await db.close();
    }
  });

  test('source diagnostic waits for earlier capture and stop drains it',
      () async {
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = GatedImageStore(database);
    await store.initialize();
    final events = StreamController<Object?>(sync: true);
    final errors = <Object>[];
    final capture = TextCapture(TextHistoryRecorder(store),
        onError: (error, _) => errors.add(error));
    try {
      capture.start(events.stream);
      events.add(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='));
      await store.started.future.timeout(const Duration(seconds: 5));
      events.addError(StateError('later warning'));
      var stopped = false;
      final stopping = capture.stop().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(errors, isEmpty);
      expect(stopped, isFalse);
      store.release.complete();
      await stopping;
      expect(errors.single.toString(), contains('later warning'));
      expect((await store.list()).single.isImage, isTrue);
    } finally {
      if (!store.release.isCompleted) store.release.complete();
      await capture.stop();
      await events.close();
      await database.close();
    }
  });

  test('queue overflow is reported before a later source warning', () async {
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = GatedImageStore(database);
    await store.initialize();
    final events = StreamController<Object?>(sync: true);
    final errors = <Object>[];
    final capture = TextCapture(TextHistoryRecorder(store),
        onError: (error, _) => errors.add(error));
    try {
      capture.start(events.stream);
      final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');
      events.add(png);
      await store.started.future.timeout(const Duration(seconds: 5));
      events.add(Uint8List(10 * 1024 * 1024));
      events.add(Uint8List(10 * 1024 * 1024 - png.length));
      events.add(Uint8List(1));
      events.addError(StateError('later warning'));
      store.release.complete();
      await capture.stop();
      expect(errors, hasLength(2));
      expect(errors[0].toString(), contains('Hàng đợi ảnh đã đầy'));
      expect(errors[1].toString(), contains('later warning'));
    } finally {
      if (!store.release.isCompleted) store.release.complete();
      await capture.stop();
      await events.close();
      await database.close();
    }
  });

  test('snapshot queue overflow keeps source warning and does not poison flush',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = GatedImageStore(db);
    await store.initialize();
    final events = StreamController<Object?>(sync: true);
    final errors = <Object>[];
    final capture = TextCapture(TextHistoryRecorder(store),
        onError: (e, _) => errors.add(e));
    try {
      capture.start(events.stream);
      final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');
      events.add(png);
      await store.started.future.timeout(const Duration(seconds: 5));
      events.add(Uint8List(10 * 1024 * 1024));
      events.add(Uint8List(10 * 1024 * 1024 - png.length));
      events.add(
          ClipboardSnapshot(Uint8List(1), warning: StateError('text omitted')));
      events.add(ClipboardSnapshot(
          ClipboardImageWithText(Uint8List(1), 'fallback'),
          warning: StateError('source warning')));
      store.release.complete();
      await capture.stop();
      expect(errors, hasLength(2));
      expect(errors.first.toString(), contains('text omitted'));
      expect(errors.first.toString(), contains('Hàng đợi ảnh đã đầy'));
      expect(errors.last.toString(), contains('source warning'));
      expect(errors.last.toString(), contains('hàng đợi ảnh đã đầy'));
      expect((await store.list()).any((entry) => entry.text == 'fallback'),
          isTrue);
    } finally {
      if (!store.release.isCompleted) store.release.complete();
      await capture.stop();
      await events.close();
      await db.close();
    }
  });

  test('warning-only snapshot waits behind earlier image and stop drains it',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = GatedImageStore(db);
    await store.initialize();
    final events = StreamController<Object?>(sync: true);
    final errors = <Object>[];
    final capture = TextCapture(TextHistoryRecorder(store),
        onError: (e, _) => errors.add(e));
    try {
      capture.start(events.stream);
      events.add(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='));
      await store.started.future.timeout(const Duration(seconds: 5));
      events.add(ClipboardSnapshot(null, warning: StateError('warning only')));
      var stopped = false;
      final stopping = capture.stop().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(errors, isEmpty);
      expect(stopped, isFalse);
      store.release.complete();
      await stopping;
      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('warning only'));
    } finally {
      if (!store.release.isCompleted) store.release.complete();
      await capture.stop();
      await events.close();
      await db.close();
    }
  });

  test('snapshot combines source and write errors and flush keeps DB failure',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = FailingSnapshotStore(db);
    await store.initialize();
    final events = StreamController<Object?>(sync: true);
    final errors = <Object>[];
    final capture = TextCapture(TextHistoryRecorder(store),
        onError: (e, _) => errors.add(e));
    try {
      capture.start(events.stream);
      events.add(ClipboardSnapshot('fallback',
          warning: StateError('image source failed')));
      await expectLater(capture.stop(), throwsA(isA<StateError>()));
      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('image source failed'));
      expect(errors.single.toString(), contains('database failed'));
    } finally {
      await capture.stop();
      await events.close();
      await db.close();
    }
  });

  test('throwing snapshot diagnostic does not suppress saved notification',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = TextHistoryStore(db);
    await store.initialize();
    final events = StreamController<Object?>(sync: true);
    var notified = 0;
    final capture = TextCapture(TextHistoryRecorder(store),
        onError: (_, __) => throw StateError('diagnostic callback'),
        onRecorded: () => notified++);
    try {
      capture.start(events.stream);
      events.add(ClipboardSnapshot('saved', warning: StateError('warning')));
      await capture.stop();
      expect(notified, 1);
      expect((await store.list()).single.text, 'saved');
    } finally {
      await capture.stop();
      await events.close();
      await db.close();
    }
  });

  test('notifies only after a valid image is stored', () async {
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = TextHistoryStore(database);
    await store.initialize();
    final events = StreamController<Object?>(sync: true);
    final errors = <Object>[];
    var notifications = 0;
    final recorded = Completer<void>();
    final recorder = TextHistoryRecorder(store);
    final capture = TextCapture(recorder,
        onError: (error, _) => errors.add(error),
        onRecorded: () {
          notifications++;
          if (!recorded.isCompleted) recorded.complete();
        });
    try {
      capture.start(events.stream);
      events.add(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(Duration.zero);
      await recorder.flush();
      expect(notifications, 0);
      events.add(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='));
      await recorded.future.timeout(const Duration(seconds: 5));
      await capture.stop();
      expect(errors, isEmpty);
      expect(notifications, 1);
      final entries = await store.list();
      expect(entries, hasLength(1));
      expect(entries.single.isImage, isTrue);
    } finally {
      await events.close();
      await database.close();
    }
  });
}

class FailingSnapshotStore extends TextHistoryStore {
  FailingSnapshotStore(super.database);
  @override
  Future<void> add(String text, DateTime copiedAt) async {
    throw StateError('database failed');
  }
}

class GatedImageStore extends TextHistoryStore {
  GatedImageStore(super.database);
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> addImage(Uint8List png, DateTime copiedAt) async {
    started.complete();
    await release.future;
    await super.addImage(png, copiedAt);
  }
}
