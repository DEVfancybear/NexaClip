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
      await diskDatabase.close();

      diskDatabase = await databaseFactoryFfi.openDatabase(path);
      try {
        diskStore = TextHistoryStore(diskDatabase);
        await diskStore.initialize();
        expect((await diskStore.list()).single.text, 'persisted');
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

  test('initializing again preserves entries', () async {
    await store.add('kept', DateTime.utc(2026));
    await store.initialize();
    expect((await store.list()).single.text, 'kept');
  });
}
