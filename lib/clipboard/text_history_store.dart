import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Stores text history locally. Callers own and close the database.
class TextHistoryStore {
  TextHistoryStore(this.database);

  final Database database;

  Future<void> initialize() async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS text_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT NOT NULL,
        copied_at INTEGER NOT NULL
      )
    ''');
  }

  static const maxEntries = 500;

  Future<void> add(String text, DateTime copiedAt) async {
    await database.transaction((txn) async {
      await txn.insert('text_history', {
        'text': text,
        'copied_at': copiedAt.toUtc().millisecondsSinceEpoch,
      });
      await txn.rawDelete('''
        DELETE FROM text_history WHERE id NOT IN (
          SELECT id FROM text_history ORDER BY copied_at DESC, id DESC LIMIT ?
        )
      ''', [maxEntries]);
    });
  }

  Future<List<TextHistoryEntry>> list() async {
    final rows = await database.query(
      'text_history',
      orderBy: 'copied_at DESC, id DESC',
    );
    return rows
        .map((row) => TextHistoryEntry(
              id: row['id'] as int,
              text: row['text'] as String,
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
  });

  final int id;
  final String text;
  final DateTime copiedAt;
}
