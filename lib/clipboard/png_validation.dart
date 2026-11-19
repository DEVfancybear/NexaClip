import 'dart:typed_data';
import 'dart:ui' as ui;

const maxPngBytes = 10 * 1024 * 1024;

/// Checks size and IHDR before a decoder allocates image pixels.
({int width, int height})? supportedPngDimensions(Uint8List bytes) {
  const maxDimension = 8192;
  const maxPixels = 16000000;
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 33 || bytes.length > maxPngBytes) return null;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(8) != 13 ||
      bytes[12] != 73 ||
      bytes[13] != 72 ||
      bytes[14] != 68 ||
      bytes[15] != 82) {
    return null;
  }
  final width = data.getUint32(16);
  final height = data.getUint32(20);
  if (width == 0 ||
      height == 0 ||
      width > maxDimension ||
      height > maxDimension ||
      width * height > maxPixels) {
    return null;
  }
  return (width: width, height: height);
}

/// Rejects oversized or malformed PNG images before they reach history.
Future<bool> isSupportedPng(Uint8List bytes) async {
  final dimensions = supportedPngDimensions(bytes);
  if (dimensions == null) return false;
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        return frame.image.width == dimensions.width &&
            frame.image.height == dimensions.height;
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return false;
  }
}
