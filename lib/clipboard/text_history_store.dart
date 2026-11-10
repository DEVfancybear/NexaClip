import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Stores text history locally. Callers own and close the database.
class TextHistoryStore {
  TextHistoryStore(this.database);

  final Database database;

  Future<void> initialize() async {
    await database.transaction((txn) async {
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS text_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          text TEXT NOT NULL,
          copied_at INTEGER NOT NULL,
          pinned INTEGER NOT NULL DEFAULT 0
        )
      ''');
      final columns = await txn.rawQuery('PRAGMA table_info(text_history)');
      if (!columns.any((column) => column['name'] == 'pinned')) {
        await txn.execute(
            'ALTER TABLE text_history ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0');
      }
    });
  }

  static const maxEntries = 500;

  Future<void> add(String text, DateTime copiedAt) async {
    await database.transaction((txn) async {
      await txn.insert('text_history', {
        'text': text,
        'copied_at': copiedAt.toUtc().millisecondsSinceEpoch,
      });
      await _trim(txn);
    });
  }

  Future<void> _trim(Transaction txn) async {
    await txn.rawDelete('''
      DELETE FROM text_history WHERE pinned = 0 AND id NOT IN (
        SELECT id FROM text_history WHERE pinned = 0
        ORDER BY copied_at DESC, id DESC LIMIT ?
      )
    ''', [maxEntries]);
  }

  Future<void> setPinned(int id, bool pinned) async {
    await database.transaction((txn) async {
      final updated = await txn.update(
          'text_history', {'pinned': pinned ? 1 : 0},
          where: 'id = ?', whereArgs: [id]);
      if (updated == 0) {
        throw StateError('Mục lịch sử không còn tồn tại.');
      }
      if (!pinned) await _trim(txn);
    });
  }

  Future<void> clear() async {
    await database.delete('text_history');
  }

  Future<List<TextHistoryEntry>> list() async {
    final rows = await database.query(
      'text_history',
      orderBy: 'pinned DESC, copied_at DESC, id DESC',
    );
    return rows
        .map((row) => TextHistoryEntry(
              id: row['id'] as int,
              text: row['text'] as String,
              pinned: (row['pinned'] as int) == 1,
              copiedAt: DateTime.fromMillisecondsSinceEpoch(
                row['copied_at'] as int,
                isUtc: true,
              ),
            ))
        .toList();
  }
}

class TextHistoryEntry {
  const TextHistoryEntry({
    required this.id,
    required this.text,
    required this.copiedAt,
    this.pinned = false,
  });

  final int id;
  final String text;
  final DateTime copiedAt;
  final bool pinned;
}
