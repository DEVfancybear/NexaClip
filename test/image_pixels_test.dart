import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/image_pixels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('decodes top-down pixels into straight-alpha BGRA', () async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255]),
      1,
      2,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final pixels = await decodeImagePixels(png!.buffer.asUint8List());
    expect(pixels.width, 1);
    expect(pixels.height, 2);
    expect(pixels.bgra, [0, 0, 255, 255, 0, 255, 0, 255]);
  });

  test('preserves straight alpha on a translucent pixel', () async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(Uint8List.fromList([64, 32, 16, 128]), 1, 1,
        ui.PixelFormat.rgba8888, completer.complete);
    final image = await completer.future;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final pixels = await decodeImagePixels(png!.buffer.asUint8List());
    expect(pixels.bgra, [32, 64, 128, 128]);
  });

  test('decoded BGRA retains transparency levels', () async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      Uint8List.fromList([
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        1,
        32,
        16,
        8,
        64,
        64,
        32,
        16,
        128,
        255,
        127,
        63,
        255,
      ]),
      5,
      1,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    final encoded = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final first = await decodeImagePixels(encoded!.buffer.asUint8List());
    expect([for (var i = 3; i < first.bgra.length; i += 4) first.bgra[i]],
        [0, 1, 64, 128, 255]);
  });

  test('rejects malformed PNG bytes', () async {
    await expectLater(decodeImagePixels(Uint8List.fromList([1, 2, 3])),
        throwsFormatException);
  });
}
