import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Uint8List> makePng(int width, int height, List<int> rgba) async {
  final result = Completer<ui.Image>();
  ui.decodeImageFromPixels(Uint8List.fromList(rgba), width, height,
      ui.PixelFormat.rgba8888, result.complete);
  final image = await result.future;
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  } finally {
    image.dispose();
  }
}

// Add a valid ancillary tEXt chunk before IEND, changing the encoding only.
Uint8List withMetadata(Uint8List png) {
  final typeAndData = <int>[...'tEXt'.codeUnits, ...'key\x00value'.codeUnits];
  var crc = 0xffffffff;
  for (final byte in typeAndData) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  crc ^= 0xffffffff;
  final length = ByteData(4)..setUint32(0, typeAndData.length - 4);
  final checksum = ByteData(4)..setUint32(0, crc);
  return Uint8List.fromList([
    ...png.sublist(0, png.length - 12),
    ...length.buffer.asUint8List(),
    ...typeAndData,
    ...checksum.buffer.asUint8List(),
    ...png.sublist(png.length - 12)
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late TextHistoryStore store;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    store = TextHistoryStore(db);
  });
  tearDown(() => db.close());

  test(
      'same pixels across encodings preserve id and pin, different pixels do not',
      () async {
    await store.initialize();
    final first = await makePng(1, 1, [255, 0, 0, 255]);
    final alternate = withMetadata(first);
    final other = await makePng(1, 1, [0, 255, 0, 255]);
    final time = DateTime.utc(2026);
    await store.addImage(first, time);
    final id = (await store.list()).single.id;
    await store.setPinned(id, true);
    await store.addImage(alternate, time.add(const Duration(seconds: 1)));
    final row = (await store.list()).single;
    expect(row.id, id);
    expect(row.pinned, isTrue);
    expect(row.copiedAt, time.add(const Duration(seconds: 1)));
    expect(await store.loadImage(id), first);
    await store.addImage(other, time);
    expect(await store.list(), hasLength(2));
  });

  test('APNG first-frame matches never overwrite pinned animation', () async {
    await store.initialize();
    final animation = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAABAAAAAQAAAAAAAAAAAAEACgAAWn8w0AAAAA1JREFUeJxj+M/A8B8ABQAB/4mZPR0AAAAaZmNUTAAAAAEAAAABAAAAAQAAAAAAAAAAAAEACgAAwQzaBAAAABFmZEFUAAAAAnicY2D4z/AfAAQBAf9i5+mcAAAAAElFTkSuQmCC');
    final other = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAABAAAAAQAAAAAAAAAAAAEACgAAWn8w0AAAAA1JREFUeJxj+M/A8B8ABQAB/4mZPR0AAAAaZmNUTAAAAAEAAAABAAAAAQAAAAAAAAAAAAEACgAAwQzaBAAAABFmZEFUAAAAAnicY2Bg+P8fAAMCAf/1e6XXAAAAAElFTkSuQmCC');
    final codec = await ui.instantiateImageCodec(animation);
    try {
      expect(codec.frameCount, 2);
    } finally {
      codec.dispose();
    }
    final staticImage = await makePng(1, 1, [255, 0, 0, 255]);
    // Simulate a previously persisted unversioned first-frame hash.
    final id = await db.insert('text_history', {
      'text': '',
      'copied_at': 1,
      'pinned': 1,
      'image_png': animation,
      'image_pixel_hash': 'a' * 64
    });
    await store.initialize();
    await store.addImage(staticImage, DateTime.utc(2026));
    await store.addImage(other, DateTime.utc(2026));
    await store.addImage(animation, DateTime.utc(2027));
    await store.addImage(other, DateTime.utc(2027));
    expect(await store.list(), hasLength(3));
    expect((await store.list()).first.copiedAt, DateTime.utc(2027));
    expect((await store.list()).first.id, id);
    expect((await store.list()).first.pinned, isTrue);
    expect(await store.loadImage(id), animation);
    final rows =
        await db.query('text_history', where: 'id = ?', whereArgs: [id]);
    expect(rows.single['image_pixel_hash'], 'invalid');
  });

  test('legacy unhashable identical blobs prefer pinned and remain intact',
      () async {
    await store.initialize();
    final bytes = Uint8List.fromList([1, 2, 3]);
    final pinned = await db.insert('text_history', {
      'text': '',
      'copied_at': 1,
      'pinned': 1,
      'image_png': bytes,
    });
    final newer = await db.insert('text_history', {
      'text': '',
      'copied_at': 2,
      'image_png': bytes,
      'image_pixel_hash': 'invalid',
    });
    store = TextHistoryStore(db, pixelHasher: (_) async => null);
    final time = DateTime.utc(2027);
    await store.addImage(bytes, time);
    final entries = await store.list();
    expect(entries, hasLength(2));
    expect(entries.first.id, pinned);
    expect(entries.first.pinned, isTrue);
    expect(entries.first.copiedAt, time);
    expect(await store.loadImage(pinned), bytes);
    expect(await store.loadImage(newer), bytes);
    expect(entries.last.copiedAt.millisecondsSinceEpoch, 2);
  });

  test('same millisecond image repeat is newest and preserves id', () async {
    await store.initialize();
    final a = await makePng(1, 1, [255, 0, 0, 255]);
    final b = await makePng(1, 1, [0, 255, 0, 255]);
    final time = DateTime.utc(2026);
    await store.addImage(a, time);
    final id = (await store.list()).single.id;
    await store.addImage(b, time);
    await store.addImage(withMetadata(a), time);
    final rows = await store.list();
    expect(rows, hasLength(2));
    expect(rows.first.id, id);
    expect(rows.first.copiedAt, time);
    expect(rows.first.pinned, isFalse);
  });

  test('alpha pixels roundtrip across PNG encodings', () async {
    await store.initialize();
    final png = await makePng(2, 1, [120, 80, 40, 128, 0, 0, 0, 0]);
    final alternate = withMetadata(png);
    final time = DateTime.utc(2026);
    await store.addImage(png, time);
    final id = (await store.list()).single.id;
    await store.addImage(alternate, time);
    expect((await store.list()).single.id, id);
    expect(await store.loadImage(id), png);
  });

  test('older concurrent completion cannot overwrite newer equal-time copy',
      () async {
    await store.initialize();
    final started = Completer<void>();
    final resume = Completer<void>();
    store = TextHistoryStore(db, pixelHasher: (bytes) async {
      if (bytes.first == 1) {
        started.complete();
        await resume.future;
      }
      return 'same';
    });
    final time = DateTime.utc(2026);
    final old = store.addImage(Uint8List.fromList([1]), time);
    await started.future;
    final second = store.addImage(Uint8List.fromList([2]), time);
    final third = store.addImage(Uint8List.fromList([3]), time);
    resume.complete();
    await Future.wait([old, second, third]);
    final id = (await store.list()).single.id;
    expect(await store.loadImage(id), [1]);
    expect((await store.list()).single.copiedAt, time);
  });

  test('legacy scan decodes in id order and does not retain a snapshot',
      () async {
    await store.initialize();
    for (var i = 1; i <= 3; i++) {
      await db.insert('text_history', {
        'text': '',
        'copied_at': i,
        'image_png': Uint8List.fromList([i])
      });
    }
    final seen = <int>[];
    store = TextHistoryStore(db, pixelHasher: (bytes) async {
      if (bytes.first != 9) {
        seen.add(bytes.first);
        if (bytes.first == 1) {
          await db.delete('text_history', where: 'image_png = ?', whereArgs: [
            Uint8List.fromList([2])
          ]);
        }
      }
      return 'hash${bytes.first}';
    });
    await store.addImage(Uint8List.fromList([9]), DateTime.utc(2026));
    expect(seen, [1, 3]);
  });

  test('dimensions are part of pixel identity', () async {
    await store.initialize();
    final rgba = [255, 0, 0, 255, 0, 255, 0, 255];
    await store.addImage(await makePng(1, 2, rgba), DateTime.utc(2026));
    await store.addImage(await makePng(2, 1, rgba), DateTime.utc(2026));
    expect(await store.list(), hasLength(2));
  });

  test('invalid legacy image is attempted only once and retained', () async {
    await store.initialize();
    final id = await db.insert('text_history', {
      'text': '',
      'copied_at': 1,
      'image_png': Uint8List.fromList([9])
    });
    var invalidAttempts = 0;
    store = TextHistoryStore(db, pixelHasher: (bytes) async {
      if (bytes.first == 9) {
        invalidAttempts++;
        return null;
      }
      return 'valid';
    });
    await store.addImage(Uint8List.fromList([1]), DateTime.utc(2026));
    await store.addImage(Uint8List.fromList([1]), DateTime.utc(2026));
    expect(invalidAttempts, 1);
    expect(await store.loadImage(id), [9]);
  });

  test('backfill does not lock writes or overwrite deleted/replaced blobs',
      () async {
    await store.initialize();
    final id = await db.insert('text_history', {
      'text': '',
      'copied_at': 1,
      'image_png': Uint8List.fromList([9])
    });
    final started = Completer<void>();
    final resume = Completer<void>();
    store = TextHistoryStore(db, pixelHasher: (bytes) async {
      if (bytes.first == 9) {
        started.complete();
        await resume.future;
        return 'old';
      }
      return 'new';
    });
    final pending = store.addImage(Uint8List.fromList([1]), DateTime.utc(2026));
    await started.future;
    await db.update(
        'text_history',
        {
          'image_png': Uint8List.fromList([8])
        },
        where: 'id = ?',
        whereArgs: [id]);
    resume.complete();
    await pending;
    final row =
        (await db.query('text_history', where: 'id = ?', whereArgs: [id]))
            .single;
    expect(row['image_png'], [8]);
    expect(row['image_pixel_hash'], isNull);
  });

  test('concurrent adds and deletion during backfill are safe', () async {
    await store.initialize();
    final id = await db.insert('text_history', {
      'text': '',
      'copied_at': 1,
      'image_png': Uint8List.fromList([9])
    });
    final started = Completer<void>();
    final resume = Completer<void>();
    var attempts = 0;
    store = TextHistoryStore(db, pixelHasher: (bytes) async {
      if (bytes.first == 9 && attempts++ == 0) {
        started.complete();
        await resume.future;
      }
      return bytes.first == 9 ? 'legacy' : 'new';
    });
    final first = store.addImage(Uint8List.fromList([1]), DateTime.utc(2026));
    await started.future;
    await store.delete(id);
    final second = store.addImage(Uint8List.fromList([1]), DateTime.utc(2026));
    resume.complete();
    await Future.wait([first, second]);
    expect(await store.list(), hasLength(1));
    expect(await store.loadImage(id), isNull);
  });

  test('old duplicate rows remain; preferred pinned row is reused', () async {
    await db.execute(
        'CREATE TABLE text_history (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, copied_at INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, image_png BLOB)');
    final png = await makePng(1, 1, [0, 0, 255, 255]);
    final pinnedId = await db.insert('text_history',
        {'text': '', 'copied_at': 1, 'pinned': 1, 'image_png': png});
    final otherId = await db.insert('text_history',
        {'text': '', 'copied_at': 2, 'image_png': withMetadata(png)});
    await store.initialize();
    await store.initialize();
    await store.addImage(png, DateTime.utc(2026));
    final rows = await store.list();
    expect(rows, hasLength(2));
    expect(rows.first.id, pinnedId);
    expect(rows.first.pinned, isTrue);
    expect(rows.last.id, otherId);
    expect(await store.loadImage(otherId), isNotNull);
  });
}
