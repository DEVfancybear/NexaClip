import 'dart:io';

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

  test('returns newest entries first, breaking ties by insertion order',
      () async {
    final time = DateTime.utc(2026);
    await store.add('first', time);
    await store.add('second', time);
    await store.add('newest', time.add(const Duration(seconds: 1)));
    expect((await store.list()).map((entry) => entry.text),
        ['newest', 'second', 'first']);
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

  test('initializing again preserves entries', () async {
    await store.add('kept', DateTime.utc(2026));
    await store.initialize();
    expect((await store.list()).single.text, 'kept');
  });
}
