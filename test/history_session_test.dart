import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/history_session.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:nexaclip/clipboard/windows_clipboard_source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DelayedHistoryStore extends TextHistoryStore {
  DelayedHistoryStore(super.database);
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> add(String text, DateTime copiedAt) async {
    started.complete();
    await release.future;
    await super.add(text, copiedAt);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const channel = MethodChannel('nexaclip/clipboard');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('native notification is recorded and stop drains queued writes',
      () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = TextHistoryStore(database);
    await store.initialize();
    final errors = <Object>[];
    final source = WindowsClipboardSource(channel: channel);
    final session = HistorySession(
        store: store, source: source, onError: (error, _) => errors.add(error));
    try {
      await session.start();
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(const MethodCall('changed', 'sample')),
          (_) => delivered.complete());
      await delivered.future;
      await Future<void>.delayed(Duration.zero);
      await session.stop();
      expect((await store.list()).single.text, 'sample');
      expect(errors, isEmpty);
    } finally {
      await session.dispose();
      await database.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('stop waits for an in-flight database write', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = DelayedHistoryStore(database);
    await store.initialize();
    final session = HistorySession(
      store: store,
      source: WindowsClipboardSource(channel: channel),
      onError: (_, __) {},
    );
    try {
      await session.start();
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('changed', 'pending')),
        (_) => delivered.complete(),
      );
      await delivered.future;
      await store.started.future;
      var stopped = false;
      final stop = session.stop().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      store.release.complete();
      await stop;
      expect((await store.list()).single.text, 'pending');
    } finally {
      if (!store.release.isCompleted) store.release.complete();
      await session.dispose();
      await database.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('failed stop still waits for an in-flight write', () async {
    var failStop = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop' && failStop) {
        throw PlatformException(code: 'listener_failed');
      }
      return null;
    });
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = DelayedHistoryStore(database);
    await store.initialize();
    final session = HistorySession(
      store: store,
      source: WindowsClipboardSource(channel: channel),
      onError: (_, __) {},
    );
    try {
      await session.start();
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('changed', 'pending')),
        (_) => delivered.complete(),
      );
      await delivered.future;
      await store.started.future;
      var completed = false;
      final result = session
          .stop()
          .then<Object?>((_) => null, onError: (Object e) => e)
          .then((value) {
        completed = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      store.release.complete();
      expect(
          await result,
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'listener_failed'));
      expect((await store.list()).single.text, 'pending');
      expect(session.isActive, isFalse);
    } finally {
      failStop = false;
      if (!store.release.isCompleted) store.release.complete();
      await session.dispose();
      await database.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('reports both failed listener stop and failed pending write', () async {
    var failStop = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop' && failStop) {
        throw PlatformException(code: 'listener_failed');
      }
      return null;
    });
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = DelayedHistoryStore(database);
    await store.initialize();
    final errors = <Object>[];
    final session = HistorySession(
      store: store,
      source: WindowsClipboardSource(channel: channel),
      onError: (error, _) => errors.add(error),
    );
    try {
      await session.start();
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(const MethodCall('changed', 'synthetic')),
          (_) => delivered.complete());
      await delivered.future;
      await store.started.future;
      final result =
          session.stop().then<Object?>((_) => null, onError: (Object e) => e);
      store.release.completeError(StateError('synthetic write failure'));
      final error = await result;
      expect(
          error,
          isA<HistoryStopException>()
              .having(
                  (e) => e.listenerError,
                  'listener error',
                  isA<PlatformException>()
                      .having((e) => e.code, 'code', 'listener_failed'))
              .having((e) => e.writeError, 'write error', isA<StateError>()));
      expect(errors, contains(isA<StateError>()));
      failStop = false;
      await session.stop();
    } finally {
      failStop = false;
      if (!store.release.isCompleted) store.release.complete();
      await session.dispose();
      await database.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('dispose preserves write error when both listener stop attempts fail',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop') {
        throw PlatformException(code: 'listener_failed');
      }
      return null;
    });
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = DelayedHistoryStore(db);
    await store.initialize();
    final session = HistorySession(
        store: store,
        source: WindowsClipboardSource(channel: channel),
        onError: (_, __) {});
    try {
      await session.start();
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(const MethodCall('changed', 'synthetic')),
          (_) => delivered.complete());
      await delivered.future;
      await store.started.future;
      final result = session
          .dispose()
          .then<Object?>((_) => null, onError: (Object e) => e);
      store.release.completeError(StateError('synthetic write failure'));
      final error = await result;
      expect(
          error,
          isA<HistoryDisposeException>()
              .having(
                  (e) => e.stopError,
                  'stop',
                  isA<HistoryStopException>()
                      .having(
                          (e) => e.listenerError,
                          'listener',
                          isA<PlatformException>()
                              .having((e) => e.code, 'code', 'listener_failed'))
                      .having((e) => e.writeError, 'write', isA<StateError>()))
              .having(
                  (e) => e.disposeError,
                  'dispose',
                  isA<PlatformException>()
                      .having((e) => e.code, 'code', 'listener_failed')));
    } finally {
      if (!store.release.isCompleted) store.release.complete();
      await db.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('dispose waits for an in-flight start and unregisters listener',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'start') {
        started.complete();
        await release.future;
      }
      return null;
    });
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = TextHistoryStore(database);
    await store.initialize();
    final session = HistorySession(
        store: store,
        source: WindowsClipboardSource(channel: channel),
        onError: (_, __) {});
    final start = session.start();
    await started.future;
    final dispose = session.dispose();
    release.complete();
    await start;
    await dispose;
    expect(calls, ['start', 'stop']);
    expect(session.isActive, isFalse);
    await expectLater(session.start(), throwsStateError);
    await database.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('stop failure reports the error and retries listener removal on dispose',
      () async {
    var stopCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop' && ++stopCalls == 1) {
        throw PlatformException(code: 'listener_failed');
      }
      return null;
    });
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = TextHistoryStore(database);
    await store.initialize();
    final session = HistorySession(
      store: store,
      source: WindowsClipboardSource(channel: channel),
      onError: (_, __) {},
    );
    try {
      await session.start();
      await expectLater(
          session.stop(),
          throwsA(isA<PlatformException>()
              .having((error) => error.code, 'code', 'listener_failed')));
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('changed', 'after stop')),
        (_) => delivered.complete(),
      );
      await delivered.future;
      await Future<void>.delayed(Duration.zero);
      expect(await store.list(), isEmpty);
      await session.dispose();
      expect(stopCalls, 2);
      expect(session.isActive, isFalse);
    } finally {
      await database.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('start after failed stop cleans up before resuming capture', () async {
    final calls = <String>[];
    var stopCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'stop' && ++stopCalls == 1) {
        throw PlatformException(code: 'listener_failed');
      }
      return null;
    });
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = TextHistoryStore(database);
    await store.initialize();
    final session = HistorySession(
      store: store,
      source: WindowsClipboardSource(channel: channel),
      onError: (_, __) {},
    );
    try {
      await session.start();
      await expectLater(session.stop(), throwsA(isA<PlatformException>()));
      expect(session.isActive, isFalse);
      await session.start();
      expect(session.isActive, isTrue);
      expect(calls, ['start', 'stop', 'stop', 'start']);
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('changed', 'after recovery'),
        ),
        (_) => delivered.complete(),
      );
      await delivered.future;
      await Future<void>.delayed(Duration.zero);
      await session.stop();
      expect((await store.list()).single.text, 'after recovery');
    } finally {
      await session.dispose();
      await database.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('reports failed registration and a pending write failure', () async {
    final registering = Completer<void>();
    final registration = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        registering.complete();
        await registration.future;
      }
      return null;
    });
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = DelayedHistoryStore(db);
    await store.initialize();
    final session = HistorySession(
        store: store,
        source: WindowsClipboardSource(channel: channel),
        onError: (_, __) {});
    try {
      final result =
          session.start().then<Object?>((_) => null, onError: (Object e) => e);
      await registering.future;
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(const MethodCall('changed', 'synthetic')),
          (_) => delivered.complete());
      await delivered.future;
      await store.started.future;
      registration.completeError(PlatformException(code: 'listener_failed'));
      store.release.completeError(StateError('synthetic write failure'));
      expect(
          await result,
          isA<HistoryStartException>()
              .having(
                  (e) => e.listenerError,
                  'registration',
                  isA<PlatformException>()
                      .having((e) => e.code, 'code', 'listener_failed'))
              .having((e) => e.writeError, 'write', isA<StateError>()));
      expect(session.isActive, isFalse);
    } finally {
      if (!registration.isCompleted) registration.complete();
      if (!store.release.isCompleted) store.release.complete();
      await session.dispose();
      await db.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('failed listener registration leaves session inactive', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'listener_failed');
    });
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = TextHistoryStore(database);
    await store.initialize();
    final session = HistorySession(
        store: store,
        source: WindowsClipboardSource(channel: channel),
        onError: (_, __) {});
    try {
      await expectLater(session.start(), throwsA(isA<PlatformException>()));
      expect(session.isActive, isFalse);
    } finally {
      await session.dispose();
      await database.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
