import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'image_pixels.dart';

/// Stores text history locally. Callers own and close the database.
class TextHistoryStore {
  TextHistoryStore(this.database,
      {Future<String?> Function(Uint8List)? pixelHasher})
      : _hashPixels = pixelHasher ?? _pixelHash;

  final Database database;
  final Future<String?> Function(Uint8List) _hashPixels;
  // SHA-256 hashes are hexadecimal, so this cannot match a valid image hash.
  static const _invalidImageHash = 'invalid';
  static final Expando<_ImageCalls> _imageCalls = Expando<_ImageCalls>();

  Future<void> initialize() async {
    await database.transaction((txn) async {
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS text_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          text TEXT NOT NULL,
          copied_at INTEGER NOT NULL,
          pinned INTEGER NOT NULL DEFAULT 0,
          image_png BLOB
        )
      ''');
      final columns = await txn.rawQuery('PRAGMA table_info(text_history)');
      if (!columns.any((column) => column['name'] == 'pinned')) {
        await txn.execute(
            'ALTER TABLE text_history ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0');
      }
      if (!columns.any((column) => column['name'] == 'image_png')) {
        await txn.execute('ALTER TABLE text_history ADD COLUMN image_png BLOB');
      }
      if (!columns.any((column) => column['name'] == 'image_pixel_hash')) {
        await txn.execute(
            'ALTER TABLE text_history ADD COLUMN image_pixel_hash TEXT');
      }
      if (!columns.any((column) => column['name'] == 'recency_order')) {
        await txn.execute(
            'ALTER TABLE text_history ADD COLUMN recency_order INTEGER NOT NULL DEFAULT 0');
      }
      // Version old unprefixed pixel hashes: they may identify only the first
      // frame of an animated PNG and must be recalculated safely.
      await txn.execute(
          "UPDATE text_history SET image_pixel_hash = NULL WHERE length(image_pixel_hash) = 64");
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS image_pixel_hash_idx ON text_history(image_pixel_hash)');
    });
  }

  static const maxEntries = 500;

  Future<void> add(String text, DateTime copiedAt) async {
    await database.transaction((txn) async {
      final matches = await txn.query('text_history',
          columns: ['id'],
          where: 'image_png IS NULL AND text = ?',
          whereArgs: [text],
          orderBy: 'pinned DESC, copied_at DESC, recency_order DESC, id DESC',
          limit: 1);
      final timestamp = copiedAt.toUtc().millisecondsSinceEpoch;
      final order = await _nextRecencyOrder(txn);
      if (matches.isEmpty) {
        await txn.insert('text_history',
            {'text': text, 'copied_at': timestamp, 'recency_order': order});
      } else {
        await txn.update(
            'text_history', {'copied_at': timestamp, 'recency_order': order},
            where: 'id = ?', whereArgs: [matches.single['id']]);
      }
      await _trim(txn);
    });
  }

  // Invalid historical blobs remain readable and are never coalesced.
  static Future<String?> _pixelHash(Uint8List png) async {
    try {
      if (!_isStaticPng(png)) return null;
      final pixels = await decodeImagePixels(png);
      final dimensions = ByteData(8)
        ..setUint32(0, pixels.width)
        ..setUint32(4, pixels.height);
      final sink = _DigestSink();
      final hash = sha256.startChunkedConversion(sink);
      hash.add(dimensions.buffer.asUint8List());
      hash.add(pixels.bgra);
      hash.close();
      return 'static-v2:${sink.digest}';
    } catch (_) {
      return null;
    }
  }

  // Reject animation even if the platform decoder exposes only its first
  // frame. Fail closed on truncated chunk streams, including legacy blobs.
  static bool _isStaticPng(Uint8List png) {
    if (png.length < 33) return false;
    final data = ByteData.sublistView(png);
    var offset = 8;
    while (offset + 12 <= png.length) {
      final length = data.getUint32(offset);
      final end = offset + 12 + length;
      if (end > png.length) return false;
      final type = String.fromCharCodes(png.sublist(offset + 4, offset + 8));
      if (type == 'acTL') return false;
      if (type == 'IEND') return length == 0 && end == png.length;
      offset = end;
    }
    return false;
  }

  Future<void> addImage(Uint8List png, DateTime copiedAt) async {
    if (png.isEmpty) throw ArgumentError('Image data must not be empty');
    final calls = _imageCalls[database] ??= _ImageCalls();
    final previous = calls.tail;
    final done = Completer<void>();
    calls.tail = done.future;
    await previous;
    try {
      final pixelHash = await _hashPixels(png);
      // Fetch and decode only one legacy blob at a time, outside transactions.
      if (pixelHash != null) {
        int? lastId;
        while (true) {
          final rows = await database.query('text_history',
              columns: ['id', 'image_png'],
              where: lastId == null
                  ? 'image_png IS NOT NULL AND image_pixel_hash IS NULL'
                  : 'id > ? AND image_png IS NOT NULL AND image_pixel_hash IS NULL',
              whereArgs: lastId == null ? null : [lastId],
              orderBy: 'id',
              limit: 1);
          if (rows.isEmpty) break;
          final row = rows.single;
          lastId = row['id'] as int;
          final image = row['image_png'] as Uint8List;
          final hash = await _hashPixels(image) ?? _invalidImageHash;
          await database.update('text_history', {'image_pixel_hash': hash},
              where: 'id = ? AND image_pixel_hash IS NULL AND image_png = ?',
              whereArgs: [lastId, image]);
        }
      }
      await database.transaction((txn) async {
        final order = await _nextRecencyOrder(txn);
        final matches = await txn.query('text_history',
            columns: ['id'],
            where: pixelHash == null ? 'image_png = ?' : 'image_pixel_hash = ?',
            whereArgs: [pixelHash ?? png],
            orderBy: 'pinned DESC, copied_at DESC, recency_order DESC, id DESC',
            limit: 1);
        if (matches.isNotEmpty) {
          await txn.update(
              'text_history',
              {
                'copied_at': copiedAt.toUtc().millisecondsSinceEpoch,
                'recency_order': order,
              },
              where: 'id = ?',
              whereArgs: [matches.single['id']]);
          await _trim(txn);
          return;
        }
        await txn.insert('text_history', {
          'text': '',
          'image_png': png,
          'image_pixel_hash': pixelHash ?? _invalidImageHash,
          'copied_at': copiedAt.toUtc().millisecondsSinceEpoch,
          'recency_order': order,
        });
        await _trim(txn);
      });
    } finally {
      done.complete();
    }
  }

  Future<int> _nextRecencyOrder(Transaction txn) async {
    final rows = await txn.rawQuery(
        'SELECT COALESCE(MAX(recency_order), 0) + 1 AS next_order FROM text_history');
    return rows.single['next_order'] as int;
  }

  Future<void> _trim(Transaction txn) async {
    await txn.rawDelete('''
      DELETE FROM text_history WHERE pinned = 0 AND id NOT IN (
        SELECT id FROM text_history WHERE pinned = 0
        ORDER BY copied_at DESC, recency_order DESC, id DESC LIMIT ?
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

  Future<void> delete(int id) async {
    await database.delete('text_history', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clear() async {
    await database.delete('text_history');
  }

  Future<List<TextHistoryEntry>> list() async {
    final rows = await database.query(
      'text_history',
      columns: [
        'id',
        'text',
        'copied_at',
        'pinned',
        'image_png IS NOT NULL AS is_image'
      ],
      orderBy: 'pinned DESC, copied_at DESC, recency_order DESC, id DESC',
    );
    return rows
        .map((row) => TextHistoryEntry(
              id: row['id'] as int,
              text: row['text'] as String,
              isImage: (row['is_image'] as int) == 1,
              pinned: (row['pinned'] as int) == 1,
              copiedAt: DateTime.fromMillisecondsSinceEpoch(
                row['copied_at'] as int,
                isUtc: true,
              ),
            ))
        .toList();
  }

  Future<Uint8List?> loadImage(int id) async {
    final rows = await database.query('text_history',
        columns: ['image_png'], where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.single['image_png'] as Uint8List?;
  }
}

class _ImageCalls {
  Future<void> tail = Future<void>.value();
}

class _DigestSink implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}

class TextHistoryEntry {
  const TextHistoryEntry({
    required this.id,
    required this.text,
    required this.copiedAt,
    this.isImage = false,
    this.pinned = false,
  });

  final int id;
  final String text;
  final bool isImage;
  final DateTime copiedAt;
  final bool pinned;
}
