import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

  test('stores and reads Unicode text with its timestamp', () async {
    final time = DateTime.utc(2026, 11, 9, 12, 30);
    await store.add('Xin chào 🌍', time);
    final entries = await store.list();
    expect(entries, hasLength(1));
    expect(entries.single.text, 'Xin chào 🌍');
    expect(entries.single.copiedAt, time);
  });

  test('repeated text updates the existing entry and keeps its pin', () async {
    final time = DateTime.utc(2026);
    await store.add('first', time);
    final id = (await store.list()).single.id;
    await store.add('second', time.add(const Duration(seconds: 1)));
    await store.add('first', time.add(const Duration(seconds: 2)));
    var entries = await store.list();
    expect(entries.map((e) => e.text), ['first', 'second']);
    expect(entries.first.id, id);
    await store.setPinned(id, true);
    await store.add('first', time.add(const Duration(seconds: 3)));
    entries = await store.list();
    expect(entries, hasLength(2));
    expect(entries.first.id, id);
    expect(entries.first.pinned, isTrue);
    expect(entries.first.copiedAt, time.add(const Duration(seconds: 3)));
  });

  test('returns newest entries first, breaking ties by insertion order',
      () async {
    final time = DateTime.utc(2026);
    await store.add('first', time);
    await store.add('second', time);
    await store.add('newest', time.add(const Duration(seconds: 1)));
    expect((await store.list()).map((entry) => entry.text),
        ['newest', 'second', 'first']);
  });

  test('same millisecond repeat sorts first without changing timestamp or id',
      () async {
    final time = DateTime.utc(2026);
    await store.add('A', time);
    final id = (await store.list()).single.id;
    await store.add('B', time);
    await store.add('A', time);
    final entries = await store.list();
    expect(entries.map((e) => e.text), ['A', 'B']);
    expect(entries.first.id, id);
    expect(entries.first.copiedAt, time);
    expect(entries.first.pinned, isFalse);
  });

  test('history persists after closing and reopening the database', () async {
    final directory = await Directory.systemTemp.createTemp('nexaclip_test_');
    final path = '${directory.path}${Platform.pathSeparator}history.db';
    try {
      var diskDatabase = await databaseFactoryFfi.openDatabase(path);
      var diskStore = TextHistoryStore(diskDatabase);
      await diskStore.initialize();
      await diskStore.add('persisted', DateTime.utc(2026));
      await diskStore.setPinned((await diskStore.list()).single.id, true);
      await diskDatabase.close();

      diskDatabase = await databaseFactoryFfi.openDatabase(path);
      try {
        diskStore = TextHistoryStore(diskDatabase);
        await diskStore.initialize();
        expect((await diskStore.list()).single.text, 'persisted');
        expect((await diskStore.list()).single.pinned, isTrue);
      } finally {
        await diskDatabase.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('cleared history stays empty after reopening the database', () async {
    final directory = await Directory.systemTemp.createTemp('nexaclip_clear_');
    final path = '${directory.path}${Platform.pathSeparator}history.db';
    try {
      var diskDatabase = await databaseFactoryFfi.openDatabase(path);
      var diskStore = TextHistoryStore(diskDatabase);
      await diskStore.initialize();
      await diskStore.add('private text', DateTime.utc(2026));
      await diskStore.clear();
      await diskDatabase.close();

      diskDatabase = await databaseFactoryFfi.openDatabase(path);
      try {
        diskStore = TextHistoryStore(diskDatabase);
        await diskStore.initialize();
        expect(await diskStore.list(), isEmpty);
      } finally {
        await diskDatabase.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('retains only the newest 500 entries', () async {
    final time = DateTime.utc(2026);
    for (var i = 0; i < 501; i++) {
      await store.add('entry $i', time);
    }
    final entries = await store.list();
    expect(entries, hasLength(500));
    expect(entries.first.text, 'entry 500');
    expect(entries.last.text, 'entry 1');
  });

  test('clear removes all saved entries and permits new entries', () async {
    await store.add('first', DateTime.utc(2026));
    await store.add('second', DateTime.utc(2026));
    await store.clear();
    expect(await store.list(), isEmpty);
    await store.add('new', DateTime.utc(2026));
    expect((await store.list()).single.text, 'new');
  });

  test('migrates old schema without losing entries', () async {
    await database.execute('DROP TABLE text_history');
    await database.execute(
        'CREATE TABLE text_history (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, copied_at INTEGER NOT NULL)');
    await database.insert('text_history', {'text': 'old', 'copied_at': 0});
    await store.initialize();
    await store.initialize();
    expect((await store.list()).single.text, 'old');
    expect((await store.list()).single.pinned, isFalse);
  });

  test('pins survive retention, unpin re-applies limit, clear removes all',
      () async {
    final time = DateTime.utc(2026);
    await store.add('protected', time);
    final id = (await store.list()).single.id;
    await store.setPinned(id, true);
    for (var i = 0; i < 501; i++) {
      await store.add('item $i', time.add(Duration(seconds: i + 1)));
    }
    var entries = await store.list();
    expect(entries, hasLength(501));
    expect(entries.first.text, 'protected');
    expect(entries.first.pinned, isTrue);
    expect(entries.any((entry) => entry.text == 'item 0'), isFalse);
    await store.setPinned(id, false);
    entries = await store.list();
    expect(entries, hasLength(500));
    expect(entries.any((entry) => entry.id == id), isFalse);
    await store.setPinned(entries.first.id, true);
    await store.clear();
    expect(await store.list(), isEmpty);
  });

  test('pinning an entry removed by retention reports an error', () async {
    final time = DateTime.utc(2026);
    await store.add('expired', time);
    final id = (await store.list()).single.id;
    for (var i = 0; i < 500; i++) {
      await store.add('new $i', time.add(Duration(seconds: i + 1)));
    }
    await expectLater(store.setPinned(id, true), throwsStateError);
    expect((await store.list()).any((entry) => entry.id == id), isFalse);
  });

  test('migrates pinned schema and persists image after reopening', () async {
    final directory = await Directory.systemTemp.createTemp('nexaclip_image_');
    final path = '${directory.path}${Platform.pathSeparator}history.db';
    final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10]);
    try {
      var db = await databaseFactoryFfi.openDatabase(path);
      await db.execute(
          'CREATE TABLE text_history (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, copied_at INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0)');
      await db.insert(
          'text_history', {'text': 'old pinned', 'copied_at': 1, 'pinned': 1});
      var diskStore = TextHistoryStore(db);
      await diskStore.initialize();
      await diskStore.initialize();
      await diskStore.addImage(bytes, DateTime.utc(2026));
      await db.close();
      db = await databaseFactoryFfi.openDatabase(path);
      try {
        diskStore = TextHistoryStore(db);
        await diskStore.initialize();
        final entries = await diskStore.list();
        expect(entries, hasLength(2));
        expect(entries.first.text, 'old pinned');
        expect(entries.first.pinned, isTrue);
        expect(entries.first.isImage, isFalse);
        expect(await diskStore.loadImage(entries.first.id), isNull);
        expect(entries.last.isImage, isTrue);
        expect(
            await diskStore.loadImage(entries.last.id), orderedEquals(bytes));
      } finally {
        await db.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('image entries share pin, retention, delete and clear behavior',
      () async {
    final bytes = Uint8List.fromList([137, 80, 78, 71]);
    final time = DateTime.utc(2026);
    await store.addImage(bytes, time);
    final image = (await store.list()).single;
    expect(image.isImage, isTrue);
    expect(await store.loadImage(image.id), orderedEquals(bytes));
    expect(image.text, isEmpty);
    await store.setPinned(image.id, true);
    for (var i = 0; i < 501; i++) {
      await store.add('text $i', time.add(Duration(seconds: i + 1)));
    }
    expect((await store.list()).first.isImage, isTrue);
    expect(await store.loadImage(image.id), orderedEquals(bytes));
    await store.delete(image.id);
    expect(await store.loadImage(image.id), isNull);
    expect((await store.list()).any((e) => e.id == image.id), isFalse);
    await store.addImage(bytes, time.add(const Duration(days: 1)));
    await store.clear();
    expect(await store.list(), isEmpty);
    await expectLater(store.addImage(Uint8List(0), time), throwsArgumentError);
  });

  test('old unpinned images are trimmed, including after unpinning', () async {
    final time = DateTime.utc(2026);
    final bytes = Uint8List.fromList([1, 2, 3]);
    await store.addImage(bytes, time);
    final unpinnedId = (await store.list()).single.id;
    final pinnedBytes = Uint8List.fromList([4, 5, 6]);
    await store.addImage(pinnedBytes, time.add(const Duration(seconds: 1)));
    final pinnedId = (await store.list()).first.id;
    expect(pinnedId, isNot(unpinnedId));
    await store.setPinned(pinnedId, true);
    for (var i = 0; i < TextHistoryStore.maxEntries; i++) {
      await store.add('new $i', time.add(Duration(seconds: i + 2)));
    }
    expect(await store.loadImage(unpinnedId), isNull);
    expect(await store.loadImage(pinnedId), orderedEquals(pinnedBytes));
    await store.setPinned(pinnedId, false);
    expect(await store.loadImage(pinnedId), isNull);
    expect(await store.list(), hasLength(TextHistoryStore.maxEntries));
  });

  test('initializing again preserves entries', () async {
    await store.add('kept', DateTime.utc(2026));
    await store.initialize();
    expect((await store.list()).single.text, 'kept');
  });
}
