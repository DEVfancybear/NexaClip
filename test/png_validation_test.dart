import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/png_validation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');

  test('accepts a decoded PNG', () async {
    expect(await isSupportedPng(png), isTrue);
  });

  test('rejects corrupt and truncated image data', () async {
    expect(await isSupportedPng(Uint8List.fromList([1, 2, 3])), isFalse);
    expect(await isSupportedPng(Uint8List.sublistView(png, 0, 33)), isFalse);
    final bad = Uint8List.fromList(png)..[0] = 0;
    expect(await isSupportedPng(bad), isFalse);
  });

  test('rejects invalid IHDR and zero-sized images', () async {
    final badLength = Uint8List.fromList(png);
    ByteData.sublistView(badLength).setUint32(8, 12);
    expect(await isSupportedPng(badLength), isFalse);
    final badType = Uint8List.fromList(png)..[12] = 0;
    expect(await isSupportedPng(badType), isFalse);
    final zeroWidth = Uint8List.fromList(png);
    ByteData.sublistView(zeroWidth).setUint32(16, 0);
    expect(await isSupportedPng(zeroWidth), isFalse);
    final zeroHeight = Uint8List.fromList(png);
    ByteData.sublistView(zeroHeight).setUint32(20, 0);
    expect(await isSupportedPng(zeroHeight), isFalse);
  });

  test('rejects dimensions and data above bounds before decoding', () async {
    final tooWide = Uint8List.fromList(png);
    ByteData.sublistView(tooWide).setUint32(16, 8193);
    expect(await isSupportedPng(tooWide), isFalse);
    final tooMany = Uint8List.fromList(png);
    ByteData.sublistView(tooMany).setUint32(16, 4001);
    ByteData.sublistView(tooMany).setUint32(20, 4000);
    expect(await isSupportedPng(tooMany), isFalse);
    expect(await isSupportedPng(Uint8List(10 * 1024 * 1024 + 1)), isFalse);
  });
}
