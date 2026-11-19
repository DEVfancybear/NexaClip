import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/history_session.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:nexaclip/clipboard/windows_clipboard_source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const channel = MethodChannel('nexaclip/clipboard');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('synthetic channel snapshots reach SQLite with image and text fallback',
      () async {
    final database =
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(database.close);
    final store = TextHistoryStore(database);
    await store.initialize();
    final recorded = Completer<void>();
    final errors = <Object>[];
    var count = 0;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    final session = HistorySession(
      store: store,
      source: WindowsClipboardSource(channel: channel),
      onError: (error, _) {
        errors.add(error);
      },
      onRecorded: () {
        if (++count == 2 && !recorded.isCompleted) recorded.complete();
      },
    );
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');
    Future<void> send(Map<String, Object> snapshot) async {
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(MethodCall('changed', snapshot)),
          (_) => delivered.complete());
      await delivered.future.timeout(const Duration(seconds: 10));
    }

    try {
      await session.start();
      await send({'png': png, 'text': 'not saved'});
      await send({
        'png': Uint8List.fromList([1, 2, 3]),
        'text': 'fallback'
      });
      await recorded.future.timeout(const Duration(seconds: 10));
      await session.stop();
      final entries = await store.list();
      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('Ảnh PNG không hợp lệ'));
      expect(entries, hasLength(2));
      final image = entries.singleWhere((entry) => entry.isImage);
      final text = entries.singleWhere((entry) => !entry.isImage);
      expect(text.text, 'fallback');
      expect(image.text, isEmpty);
      expect(await store.loadImage(image.id), orderedEquals(png));
    } finally {
      try {
        await session.dispose();
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    }
  });
}
