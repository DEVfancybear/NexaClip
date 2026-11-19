import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:nexaclip/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MissingImageStore extends TextHistoryStore {
  MissingImageStore(super.database);

  bool fail = false;

  @override
  Future<Uint8List?> loadImage(int id) async {
    if (fail) throw StateError('image read failed');
    return null;
  }
}

class GatedImageStore extends TextHistoryStore {
  GatedImageStore(super.database);

  final started = Completer<void>();
  final gate = Completer<Uint8List?>();

  @override
  Future<Uint8List?> loadImage(int id) {
    started.complete();
    return gate.future;
  }
}

void main() {
  testWidgets('image copy sends decoded data to the image channel',
      (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_image_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.addImage(
          base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='),
          DateTime.utc(2026));
      await db.close();
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var copies = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copies++;
      return null;
    });
    final imageCalls = <MethodCall>[];
    String? imageFailure;
    Completer<void>? imageGate;
    const channel = MethodChannel('nexaclip/clipboard');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'clipboardSequence') return 123;
      if (call.method == 'copyImage') {
        imageCalls.add(call);
        if (imageFailure != null) throw PlatformException(code: imageFailure);
        await imageGate?.future;
      }
      return null;
    });
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory)));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && find.text('Ảnh').evaluate().isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('Ảnh'), findsOneWidget);
      final copyButton = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Sao chép',
      );
      expect(copyButton, findsOneWidget);
      expect(tester.widget<IconButton>(copyButton).onPressed, isNotNull);
      await tester.tap(copyButton);
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && imageCalls.isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(imageCalls, hasLength(1));
      final args = imageCalls.single.arguments as Map;
      expect(args['width'], 1);
      expect(args['height'], 1);
      expect(args['sequence'], 123);
      expect(args.containsKey('png'), isFalse);
      expect((args['bgra'] as Uint8List).length, 4);
      expect(copies, 0);
      await tester.pump();
      expect(find.text('Đã sao chép vào clipboard.'), findsOneWidget);
      imageFailure = 'partial_write';
      await tester.tap(copyButton);
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 &&
                find.textContaining('clipboard đã thay đổi').evaluate().isEmpty;
            i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.textContaining('clipboard đã thay đổi'), findsOneWidget);
      expect(find.text('Đã sao chép vào clipboard.'), findsNothing);
      expect(tester.widget<IconButton>(copyButton).onPressed, isNotNull);
      imageFailure = 'write_failed_after_empty';
      await tester.tap(copyButton);
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 &&
                find.textContaining('clipboard đã bị xóa').evaluate().isEmpty;
            i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.textContaining('clipboard đã bị xóa'), findsOneWidget);
      expect(find.text('Đã sao chép vào clipboard.'), findsNothing);
      imageFailure = 'image_encode_failed';
      await tester.tap(copyButton);
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 &&
                find
                    .textContaining('NexaClip chưa ghi clipboard')
                    .evaluate()
                    .isEmpty;
            i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(
          find.textContaining('NexaClip chưa ghi clipboard'), findsOneWidget);
      imageFailure = 'clipboard_changed';
      await tester.tap(copyButton);
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 &&
                find
                    .textContaining(
                        'Clipboard đã thay đổi trong khi chuẩn bị ảnh')
                    .evaluate()
                    .isEmpty;
            i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(
          find.textContaining('Clipboard đã thay đổi trong khi chuẩn bị ảnh'),
          findsOneWidget);
      imageFailure = null;
      imageGate = Completer<void>();
      await tester.tap(copyButton);
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && imageCalls.length < 6; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(imageCalls, hasLength(6));
      expect(tester.widget<IconButton>(copyButton).onPressed, isNull);
      expect(
          await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
      imageGate.complete();
      await tester.pump();
      expect(tester.widget<IconButton>(copyButton).onPressed, isNotNull);
    } finally {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
  testWidgets('keeps the sequence captured before loading an image',
      (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_sequence_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.addImage(png, DateTime.utc(2026));
      await db.close();
    });
    late GatedImageStore store;
    var currentSequence = 123;
    int? receivedSequence;
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'clipboardSequence') return currentSequence;
      if (call.method == 'copyImage') {
        receivedSequence = (call.arguments as Map)['sequence'] as int;
        if (receivedSequence != currentSequence) {
          throw PlatformException(code: 'clipboard_changed');
        }
      }
      return null;
    });
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(
        supportDirectory: () async => directory,
        storeFactory: (db) => store = GatedImageStore(db),
      )));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && find.text('Ảnh').evaluate().isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('Ảnh'), findsOneWidget);
      await tester.tap(find.byTooltip('Sao chép'));
      await tester.pump();
      expect(store.started.isCompleted, isTrue);
      currentSequence = 124;
      store.gate.complete(png);
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && receivedSequence == null; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(receivedSequence, 123);
      await tester.pump();
      expect(
          find.textContaining('Clipboard đã thay đổi trong khi chuẩn bị ảnh'),
          findsOneWidget);
      expect(find.text('Đã sao chép vào clipboard.'), findsNothing);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
    }
  });

  testWidgets('opens and closes a stored image preview', (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_preview_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.addImage(
          base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='),
          DateTime.utc(2026));
      await db.close();
    });
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory)));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && find.text('Ảnh').evaluate().isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.tap(find.text('Ảnh'));
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 && find.text('Xem ảnh').evaluate().isEmpty;
            i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('Xem ảnh'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      final image = tester.widget<Image>(find.descendant(
          of: find.byType(InteractiveViewer), matching: find.byType(Image)));
      final provider = image.image;
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      expect(find.text('Xem ảnh'), findsNothing);
      final status = await provider.obtainCacheStatus(
          configuration: ImageConfiguration.empty);
      expect(status?.keepAlive, isFalse);
      await tester.tap(find.text('Ảnh'));
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 && find.text('Xem ảnh').evaluate().isEmpty;
            i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('Xem ảnh'), findsOneWidget);
      AppExitResponse? exit;
      tester.binding.handleRequestAppExit().then((value) => exit = value);
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && exit == null; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(exit, AppExitResponse.exit);
    } finally {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
    }
  });

  testWidgets('reports a missing image and unlocks the controls',
      (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_missing_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.addImage(Uint8List.fromList([1]), DateTime.utc(2026));
      await db.close();
    });
    late MissingImageStore missingStore;
    const channel = MethodChannel('nexaclip/clipboard');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel,
        (call) async => call.method == 'clipboardSequence' ? 123 : null);
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(
              supportDirectory: () async => directory,
              storeFactory: (db) => missingStore = MissingImageStore(db))));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && find.text('Ảnh').evaluate().isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.tap(find.text('Ảnh'));
      await tester.pump();
      expect(
          find.textContaining('Ảnh không còn trong lịch sử.'), findsOneWidget);
      expect(find.text('Xem ảnh'), findsNothing);
      final deleteButton = find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Xóa mục');
      expect(deleteButton, findsOneWidget);
      expect(tester.widget<IconButton>(deleteButton).onPressed, isNotNull);
      await tester.tap(find.byTooltip('Sao chép'));
      await tester.pump();
      expect(
          find.textContaining('Ảnh không còn trong lịch sử.'), findsOneWidget);
      expect(tester.widget<IconButton>(deleteButton).onPressed, isNotNull);
      missingStore.fail = true;
      await tester.tap(find.byTooltip('Sao chép'));
      await tester.pump();
      expect(find.textContaining('image read failed'), findsOneWidget);
      expect(tester.widget<IconButton>(deleteButton).onPressed, isNotNull);
      await tester.tap(find.text('Ảnh'));
      await tester.pump();
      expect(find.textContaining('image read failed'), findsOneWidget);
      expect(find.text('Xem ảnh'), findsNothing);
      expect(tester.widget<IconButton>(deleteButton).onPressed, isNotNull);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
    }
  });

  testWidgets('rejects corrupt stored image before calling native copy',
      (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_bad_image_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.addImage(Uint8List.fromList([1, 2, 3]), DateTime.utc(2026));
      await db.close();
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('nexaclip/clipboard');
    var imageCopies = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'clipboardSequence') return 123;
      if (call.method == 'copyImage') imageCopies++;
      return null;
    });
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory)));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && find.text('Ảnh').evaluate().isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('Ảnh'), findsOneWidget);
      await tester.tap(find.byTooltip('Sao chép'));
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 &&
                find.textContaining('Ảnh PNG không hợp lệ').evaluate().isEmpty;
            i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.textContaining('Ảnh PNG không hợp lệ'), findsOneWidget);
      expect(imageCopies, 0);
      await tester.tap(find.text('Ảnh'));
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 &&
                find.textContaining('Ảnh PNG không hợp lệ').evaluate().isEmpty;
            i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('Xem ảnh'), findsNothing);
      expect(find.textContaining('Ảnh PNG không hợp lệ'), findsOneWidget);
      final copyButton = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Sao chép',
      );
      expect(tester.widget<IconButton>(copyButton).onPressed, isNotNull);
    } finally {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('preview shows an error for corrupt image data', (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory =
          await Directory.systemTemp.createTemp('nexaclip_preview_corrupt_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');
      await store.addImage(
          Uint8List.sublistView(bytes, 0, 33), DateTime.utc(2026));
      await db.close();
    });
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory)));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && find.text('Ảnh').evaluate().isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('Ảnh'), findsOneWidget);
      await tester.tap(find.text('Ảnh'));
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 && find.text('Không thể hiển thị ảnh.').evaluate().isEmpty;
            i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('Không thể hiển thị ảnh.'), findsOneWidget);
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      expect(find.text('Xem ảnh'), findsNothing);
    } finally {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
    }
  });

  testWidgets('exit is cancelled while preview loads', (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory =
          await Directory.systemTemp.createTemp('nexaclip_preview_gate_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.addImage(Uint8List.fromList([1]), DateTime.utc(2026));
      await db.close();
    });
    late GatedImageStore gated;
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(
              supportDirectory: () async => directory,
              storeFactory: (db) => gated = GatedImageStore(db))));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && find.text('Ảnh').evaluate().isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('Ảnh'), findsOneWidget);
      await tester.tap(find.text('Ảnh'));
      await tester.pump();
      expect(gated.started.isCompleted, isTrue);
      expect(
          await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
      gated.gate.complete(null);
      await tester.pump();
      expect(
          find.textContaining('Ảnh không còn trong lịch sử.'), findsOneWidget);
      expect(find.text('Xem ảnh'), findsNothing);
    } finally {
      if (!gated.gate.isCompleted) gated.gate.complete(null);
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
    }
  });

  testWidgets('disposing during preview load does not open a dialog',
      (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory =
          await Directory.systemTemp.createTemp('nexaclip_preview_dispose_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.addImage(Uint8List.fromList([1]), DateTime.utc(2026));
      await db.close();
    });
    late GatedImageStore gated;
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(
              supportDirectory: () async => directory,
              storeFactory: (db) => gated = GatedImageStore(db))));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && find.text('Ảnh').evaluate().isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('Ảnh'), findsOneWidget);
      await tester.tap(find.text('Ảnh'));
      await tester.pump();
      expect(gated.started.isCompleted, isTrue);
      await tester.runAsync(() => tester.pumpWidget(const SizedBox()));
      gated.gate.complete(Uint8List.fromList([1, 2, 3]));
      await tester.pump();
      expect(find.text('Xem ảnh'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      if (!gated.gate.isCompleted) gated.gate.complete(null);
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
    }
  });

  testWidgets('preview rejects an image with oversized dimensions',
      (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    await tester.runAsync(() async {
      directory =
          await Directory.systemTemp.createTemp('nexaclip_preview_limit_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');
      ByteData.sublistView(bytes).setUint32(16, 8193);
      await store.addImage(bytes, DateTime.utc(2026));
      await db.close();
    });
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory)));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && find.text('Ảnh').evaluate().isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('Ảnh'), findsOneWidget);
      await tester.tap(find.text('Ảnh'));
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 &&
                find.textContaining('Ảnh PNG không hợp lệ').evaluate().isEmpty;
            i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.textContaining('Ảnh PNG không hợp lệ'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(
          tester
              .widget<IconButton>(find.byWidgetPredicate((widget) =>
                  widget is IconButton && widget.tooltip == 'Sao chép'))
              .onPressed,
          isNotNull);
    } finally {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
    }
  });

  testWidgets('copies selected full text and reports failures', (tester) async {
    sqfliteFfiInit();
    late Directory directory;
    const value = 'Dữ liệu thử\nfull text';
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('nexaclip_copy_');
      final db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      final store = TextHistoryStore(db);
      await store.initialize();
      await store.add(value, DateTime.utc(2026));
      await store.add('another synthetic item', DateTime.utc(2026, 1, 2));
      await db.close();
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var fail = false;
    Completer<void>? gate;
    final values = <String>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        if (fail) throw PlatformException(code: 'copy_failed');
        values.add((call.arguments as Map)['text'] as String);
        await gate?.future;
      }
      return null;
    });
    try {
      await tester.pumpWidget(MaterialApp(
          home: ClipboardHomePage(supportDirectory: () async => directory)));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && find.text(value).evaluate().isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(find.text(value), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'full text');
      await tester.pump();
      expect(find.text('another synthetic item'), findsNothing);
      await tester.tap(find.byTooltip('Sao chép'));
      await tester.pump();
      expect(values, [value]);
      expect(find.text('Đã sao chép vào clipboard.'), findsOneWidget);
      fail = true;
      await tester.tap(find.byTooltip('Sao chép'));
      await tester.pump();
      expect(find.textContaining('copy_failed'), findsOneWidget);
      expect(values, [value]);
      fail = false;
      await tester.tap(find.byTooltip('Sao chép'));
      await tester.pump();
      expect(find.textContaining('copy_failed'), findsNothing);
      expect(values, [value, value]);
      gate = Completer<void>();
      final copyButton = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Sao chép',
      );
      final button = tester.widget<IconButton>(copyButton);
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(values, [value, value, value]);
      expect(tester.widget<IconButton>(copyButton).onPressed, isNull);
      final exit = await tester.binding.handleRequestAppExit();
      expect(exit, AppExitResponse.cancel);
      gate.complete();
      await tester.pump();
      expect(tester.widget<IconButton>(copyButton).onPressed, isNotNull);
    } finally {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await directory.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    }
  });
}
