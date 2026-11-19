import 'dart:async';
import 'dart:convert';

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

class DelayedImageStore extends TextHistoryStore {
  DelayedImageStore(super.database);
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> addImage(Uint8List png, DateTime copiedAt) async {
    started.complete();
    await release.future;
    await super.addImage(png, copiedAt);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const channel = MethodChannel('nexaclip/clipboard');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('concurrent and later dispose calls share cleanup failure', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop') throw PlatformException(code: 'stop_failed');
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
      final first = session.dispose();
      final second = session.dispose();
      expect(identical(first, second), isTrue);
      final firstCheck =
          expectLater(first, throwsA(isA<HistoryDisposeException>()));
      final secondCheck =
          expectLater(second, throwsA(isA<HistoryDisposeException>()));
      await Future.wait([firstCheck, secondCheck]);
      await expectLater(
          session.dispose(), throwsA(isA<HistoryDisposeException>()));
    } finally {
      await database.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

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

  test('channel fallback image is saved before stop completes', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = DelayedImageStore(database);
    await store.initialize();
    final errors = <Object>[];
    final session = HistorySession(
      store: store,
      source: WindowsClipboardSource(channel: channel),
      onError: (error, _) => errors.add(error),
    );
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');
    try {
      await session.start();
      final reply = Completer<ByteData?>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall('changed', {
          'png': Uint8List.fromList([1, 2, 3]),
          'fallbackPng': png,
          'text': 'synthetic',
        })),
        reply.complete,
      );
      await store.started.future;
      var stopped = false;
      final stop = session.stop().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      expect(reply.isCompleted, isFalse);
      store.release.complete();
      const StandardMethodCodec().decodeEnvelope((await reply.future)!);
      await stop;
      expect(stopped, isTrue);
      final entries = await store.list();
      expect(entries, hasLength(1));
      expect(entries.single.isImage, isTrue);
      expect(await store.loadImage(entries.single.id), orderedEquals(png));
      expect(errors, isEmpty);
    } finally {
      if (!store.release.isCompleted) store.release.complete();
      await session.dispose();
      await database.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('urgent capture failure is reported while a write is blocked', () async {
    int? generation;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') generation = call.arguments as int;
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
      onError: (error, _) {
        errors.add(error);
        throw StateError('UI failed');
      },
    );
    try {
      await session.start();
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(const MethodCall('changed', 'pending')),
          (_) => delivered.complete());
      await store.started.future;
      final warningReply = Completer<ByteData?>();
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(MethodCall('captureFailed', generation)),
          warningReply.complete);
      const StandardMethodCodec().decodeEnvelope((await warningReply.future)!);
      expect(errors, hasLength(1));
      expect(delivered.isCompleted, isFalse);
      store.release.complete();
      await delivered.future;
      await session.stop();
      expect((await store.list()).single.text, 'pending');
    } finally {
      if (!store.release.isCompleted) store.release.complete();
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
      await store.started.future;
      expect(delivered.isCompleted, isFalse);
      var stopped = false;
      final stop = session.stop().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      store.release.complete();
      await delivered.future;
      await stop;
      expect((await store.list()).single.text, 'pending');
    } finally {
      if (!store.release.isCompleted) store.release.complete();
      await session.dispose();
      await database.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('native stop waits for recording acknowledgement', () async {
    final acknowledgement = Completer<void>();
    var stopping = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop') {
        stopping = true;
        await acknowledgement.future;
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
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('changed', 'synthetic')),
        (reply) {
          const StandardMethodCodec().decodeEnvelope(reply!);
          acknowledgement.complete();
        },
      );
      await store.started.future;
      var stopped = false;
      final stop = session.stop().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopping, isTrue);
      expect(acknowledgement.isCompleted, isFalse);
      expect(stopped, isFalse);
      store.release.complete();
      await stop;
      expect(acknowledgement.isCompleted, isTrue);
      expect((await store.list()).single.text, 'synthetic');
    } finally {
      if (!store.release.isCompleted) store.release.complete();
      if (!acknowledgement.isCompleted) await acknowledgement.future;
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
      await store.started.future;
      expect(delivered.isCompleted, isFalse);
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
      await store.started.future;
      expect(delivered.isCompleted, isFalse);
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
      await store.started.future;
      expect(delivered.isCompleted, isFalse);
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
    final cleanup = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        registering.complete();
        await registration.future;
      } else if (call.method == 'stop') {
        cleanup.complete();
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
      await store.started.future;
      expect(delivered.isCompleted, isFalse);
      registration.completeError(PlatformException(code: 'listener_failed'));
      await cleanup.future;
      expect(delivered.isCompleted, isFalse);
      var completed = false;
      result.then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
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

  test('failed start drains snapshots delivered during native cleanup',
      () async {
    final stopStarted = Completer<void>();
    final stopGate = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') throw PlatformException(code: 'reply_failed');
      if (call.method == 'stop') {
        stopStarted.complete();
        await stopGate.future;
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
    try {
      final failedStart =
          expectLater(session.start(), throwsA(isA<PlatformException>()));
      await stopStarted.future;
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('changed', 'during cleanup'),
        ),
        (_) => delivered.complete(),
      );
      await delivered.future;
      stopGate.complete();
      await failedStart;
      expect((await store.list()).single.text, 'during cleanup');
    } finally {
      if (!stopGate.isCompleted) stopGate.complete();
      await session.dispose();
      await database.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('failed start and cleanup retain listener for retry', () async {
    var registered = false;
    var stops = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        registered = true;
        throw PlatformException(code: 'start_reply_failed');
      }
      if (call.method == 'stop') {
        if (++stops == 1) throw PlatformException(code: 'remove_failed');
        registered = false;
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
    try {
      await expectLater(session.start(), throwsA(isA<HistoryStopException>()));
      expect(session.isActive, isFalse);
      expect(registered, isTrue);
      await session.stop();
      expect(registered, isFalse);
      expect(stops, 2);
    } finally {
      await session.dispose();
      await database.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('retry reports failure when a queued snapshot is rejected', () async {
    var stops = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop' && ++stops == 1) {
        throw PlatformException(code: 'stop_reply_failed');
      }
      if (call.method == 'stop' && stops == 2) {
        final response = Completer<ByteData?>();
        messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('changed', 'queued synthetic'),
          ),
          response.complete,
        );
        const StandardMethodCodec().decodeEnvelope((await response.future)!);
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
    try {
      await session.start();
      await expectLater(session.stop(), throwsA(isA<PlatformException>()));
      await expectLater(session.stop(), throwsA(isA<PlatformException>()));
      expect(await store.list(), isEmpty);
      await session.stop();
    } finally {
      await session.dispose();
      await database.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('failed listener registration leaves session inactive', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
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
