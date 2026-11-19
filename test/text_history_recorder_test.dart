import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/text_history_recorder.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database database;
  late TextHistoryStore store;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    store = TextHistoryStore(database);
    await store.initialize();
  });

  tearDown(() => database.close());

  test(
      'reports empty and oversized direct images in queue without failing flush',
      () async {
    var notices = 0;
    final recorder =
        TextHistoryRecorder(store, onImageRejected: () => notices++);
    final empty = recorder.record(Uint8List(0));
    final large = recorder.record(Uint8List(10 * 1024 * 1024 + 1));
    expect(await empty, isFalse);
    expect(await large, isFalse);
    await recorder.flush();
    expect(notices, 2);
    expect(await store.list(), isEmpty);
  });

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

  test('serializes text and image snapshots and owns the image bytes',
      () async {
    final recorder =
        TextHistoryRecorder(store, clock: () => DateTime.utc(2026));
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');
    final original = Uint8List.fromList(bytes);
    final first = recorder.record('before');
    final second = recorder.record(bytes);
    bytes[0] = 9;
    final third = recorder.record('after');
    await Future.wait([first, second, third]);
    await recorder.flush();
    final entries = await store.list();
    expect(entries.map((e) => e.text), ['after', '', 'before']);
    expect(entries[1].isImage, isTrue);
    expect(await store.loadImage(entries[1].id), orderedEquals(original));
    expect(await recorder.record(Uint8List.fromList([1, 2, 3])), isFalse);
    expect(await recorder.record(Uint8List(10 * 1024 * 1024 + 1)), isFalse);
    await recorder.flush();
    expect(await store.list(), hasLength(3));
  });

  test('uses valid fallback image when primary is corrupt', () async {
    var rejected = 0;
    final recorder =
        TextHistoryRecorder(store, onImageRejected: () => rejected++);
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');
    final invalid = Uint8List.fromList([1, 2, 3]);
    expect(
        await recorder.record(
            ClipboardImageWithText(invalid, 'text', fallbackImage: png)),
        isTrue);
    final entries = await store.list();
    expect(entries.single.isImage, isTrue);
    expect(await store.loadImage(entries.single.id), orderedEquals(png));
    expect(rejected, 0);
  });

  test('rejects both invalid image candidates once and keeps text', () async {
    var rejected = 0;
    final recorder =
        TextHistoryRecorder(store, onImageRejected: () => rejected++);
    final snapshot = ClipboardImageWithText(
      Uint8List.fromList([1, 2, 3]),
      'text',
      fallbackImage: Uint8List.fromList([4, 5, 6]),
    );
    expect(await recorder.record(snapshot), isTrue);
    await recorder.flush();
    expect(rejected, 1);
    expect((await store.list()).single.text, 'text');
  });

  test('prefers valid image and falls back to text for invalid image',
      () async {
    final recorder = TextHistoryRecorder(store);
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');
    expect(
        await recorder.record(ClipboardImageWithText(png, 'fallback')), isTrue);
    expect(
        await recorder.record(
            ClipboardImageWithText(Uint8List.fromList([1, 2, 3]), 'text')),
        isTrue);
    final entries = await store.list();
    expect(entries, hasLength(2));
    expect(entries.first.text, 'text');
    expect(entries.last.isImage, isTrue);
  });

  test('reports rejected image without poisoning flush', () async {
    var notices = 0;
    final recorder =
        TextHistoryRecorder(store, onImageRejected: () => notices++);
    expect(await recorder.record(Uint8List.fromList([1, 2, 3])), isFalse);
    expect(notices, 1);
    await recorder.flush();
    expect(await store.list(), isEmpty);
    final throwing = TextHistoryRecorder(store,
        onImageRejected: () => throw StateError('notice failed'));
    expect(
        await throwing.record(
            ClipboardImageWithText(Uint8List.fromList([1]), 'fallback')),
        isTrue);
    await throwing.flush();
    expect((await store.list()).single.text, 'fallback');
  });

  test('bounds queued image bytes and releases capacity after processing',
      () async {
    final delayed = DelayedStore(database);
    var notices = 0;
    final recorder =
        TextHistoryRecorder(delayed, onImageRejected: () => notices++);
    final write = recorder.record('held');
    await delayed.started.future;
    final image1 = recorder.record(Uint8List(10 * 1024 * 1024));
    final image2 = recorder.record(Uint8List(10 * 1024 * 1024));
    final overflow =
        expectLater(recorder.record(Uint8List(1)), throwsStateError);
    final fallback = recorder.record(
        ClipboardImageWithText(Uint8List.fromList([1]), 'queue fallback'));
    delayed.release.complete();
    await write;
    expect(await image1, isFalse);
    expect(await image2, isFalse);
    await overflow;
    expect(await fallback, isTrue);
    expect(notices, 3); // Two invalid images and the full queue fallback.
    expect((await store.list()).first.text, 'queue fallback');
    expect(await recorder.record(Uint8List(1)), isFalse);
    await recorder.flush();
  });

  test('releases queued image capacity after a failed image write', () async {
    final failing = DelayedFailingImageStore(database);
    final recorder = TextHistoryRecorder(failing);
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');
    final first = recorder.record(png);
    final failure = expectLater(first, throwsStateError);
    await failing.started.future;
    final queued1 = recorder.record(Uint8List(10 * 1024 * 1024));
    final queued2 = recorder.record(Uint8List(10 * 1024 * 1024 - png.length));
    final overflow =
        expectLater(recorder.record(Uint8List(1)), throwsStateError);
    failing.release.complete();
    await failure;
    expect(await recorder.record(png), isTrue);
    expect(await queued1, isFalse);
    expect(await queued2, isFalse);
    await overflow;
    await expectLater(recorder.flush(), throwsStateError);
    await recorder.flush();
    expect(await store.list(), hasLength(1));
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
    if (!started.isCompleted) started.complete();
    await release.future;
    await super.add(text, copiedAt);
  }
}

class DelayedFailingImageStore extends TextHistoryStore {
  DelayedFailingImageStore(super.database);
  final started = Completer<void>();
  final release = Completer<void>();
  bool fail = true;

  @override
  Future<void> addImage(Uint8List png, DateTime copiedAt) async {
    if (fail) {
      fail = false;
      started.complete();
      await release.future;
      throw StateError('image write failed');
    }
    await super.addImage(png, copiedAt);
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
