import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/image_pixels.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Build windows/tests/wic_roundtrip_bridge and set NEXACLIP_WIC_BRIDGE to
// its executable path. Both files and all pixels below are synthetic.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bridge = Platform.environment['NEXACLIP_WIC_BRIDGE'];
  test('Flutter decode -> WIC PNG -> Flutter pixel identity', () async {
    final imageReady = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        Uint8List.fromList(
            [120, 80, 40, 128, 20, 60, 100, 64, 0, 0, 0, 0, 45, 70, 90, 255]),
        4,
        1,
        ui.PixelFormat.rgba8888,
        imageReady.complete);
    final image = await imageReady.future;
    final ByteData data;
    try {
      data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    } finally {
      image.dispose();
    }
    final original = Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    final decoded = await decodeImagePixels(original);
    final dir = await Directory.systemTemp.createTemp('nexaclip-wic-');
    try {
      final raw = File('${dir.path}/pixels.bgra');
      final png = File('${dir.path}/encoded.png');
      await raw.writeAsBytes(decoded.bgra);
      final result = await Process.run(bridge!,
          ['${decoded.width}', '${decoded.height}', raw.path, png.path]);
      expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
      final encoded = await png.readAsBytes();
      final roundtrip = await decodeImagePixels(encoded);
      expect(roundtrip.bgra, decoded.bgra);
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      try {
        final store = TextHistoryStore(db);
        await store.initialize();
        await store.addImage(original, DateTime.utc(2026));
        final id = (await store.list()).single.id;
        await store.addImage(encoded, DateTime.utc(2026));
        expect((await store.list()).single.id, id);
        expect(await store.loadImage(id), original);
      } finally {
        await db.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  },
      skip: bridge == null
          ? 'Set NEXACLIP_WIC_BRIDGE to run native bridge test'
          : false);
}
