import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/text_history_recorder.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database database;
  late TextHistoryStore store;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    store = TextHistoryStore(database);
    await store.initialize();
  });

  tearDown(() => database.close());

  test('records events in order with the observed time', () async {
    final now = DateTime.utc(2026);
    final recorder = TextHistoryRecorder(store, clock: () => now);
    final first = recorder.record('one');
    final second = recorder.record('two');
    await Future.wait([first, second]);
    final history = await store.list();
    expect(history.map((entry) => entry.text), ['two', 'one']);
    expect(history.map((entry) => entry.copiedAt), [now, now]);
  });

  test('flush waits until a pending write completes', () async {
    final delayed = DelayedStore(database);
    final recorder = TextHistoryRecorder(delayed);
    final write = recorder.record('pending');
    await delayed.started.future;
    var flushed = false;
    final flush = recorder.flush().then((_) => flushed = true);
    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);
    delayed.release.complete();
    await write;
    await flush;
    expect(flushed, isTrue);
    expect((await store.list()).single.text, 'pending');
  });

  test('ignores null and empty text but keeps whitespace', () async {
    final recorder = TextHistoryRecorder(store);
    await recorder.record(null);
    await recorder.record('');
    await recorder.record(' ');
    expect((await store.list()).map((entry) => entry.text), [' ']);
  });

  test('reports a failed write and continues processing later events',
      () async {
    final broken = FailingOnceStore(database);
    final recorder = TextHistoryRecorder(broken);
    final first = recorder.record('first');
    final second = recorder.record('second');
    await expectLater(first, throwsStateError);
    await second;
    await expectLater(recorder.flush(), throwsStateError);
    await recorder.flush();
    expect((await store.list()).map((entry) => entry.text), ['second']);
  });
}

class DelayedStore extends TextHistoryStore {
  DelayedStore(super.database);
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> add(String text, DateTime copiedAt) async {
    started.complete();
    await release.future;
    await super.add(text, copiedAt);
  }
}

class FailingOnceStore extends TextHistoryStore {
  FailingOnceStore(super.database);
  bool fail = true;

  @override
  Future<void> add(String text, DateTime copiedAt) async {
    if (fail) {
      fail = false;
      throw StateError('write failed');
    }
    await super.add(text, copiedAt);
  }
}
