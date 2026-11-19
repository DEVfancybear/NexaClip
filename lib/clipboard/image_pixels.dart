import 'dart:typed_data';
import 'dart:ui' as ui;

import 'png_validation.dart';

/// Decoded pixels for Windows DIB, in top-down straight-alpha BGRA order.
class ImagePixels {
  ImagePixels(this.width, this.height, this.bgra);

  final int width;
  final int height;
  final Uint8List bgra;
}

Future<ImagePixels> decodeImagePixels(Uint8List png) async {
  final dimensions = supportedPngDimensions(png);
  if (dimensions == null) {
    throw const FormatException('Ảnh PNG không hợp lệ hoặc quá lớn.');
  }
  final codec = await ui.instantiateImageCodec(png);
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      if (image.width != dimensions.width ||
          image.height != dimensions.height) {
        throw const FormatException('Kích thước PNG không hợp lệ.');
      }
      final data =
          await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (data == null) throw StateError('Không thể giải mã ảnh.');
      final bgra =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      for (var i = 0; i < bgra.length; i += 4) {
        final red = bgra[i];
        bgra[i] = bgra[i + 2];
        bgra[i + 2] = red;
      }
      return ImagePixels(image.width, image.height, bgra);
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}
