import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/windows_clipboard_source.dart';
import 'package:nexaclip/clipboard/text_history_recorder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nexaclip/clipboard');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('urgent diagnostics are fenced across source instances', () async {
    final generations = <int>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') generations.add(call.arguments as int);
      return null;
    });
    Future<void> send(Object? generation) async {
      final reply = Completer<ByteData?>();
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(MethodCall('captureFailed', generation)),
          reply.complete);
      const StandardMethodCodec().decodeEnvelope((await reply.future)!);
    }

    final first = WindowsClipboardSource(channel: channel);
    final firstErrors = <Object>[];
    final firstSubscription = first.urgentDiagnostics.listen(firstErrors.add);
    await first.start();
    await send(generations.single);
    expect(firstErrors, hasLength(1));
    await first.stop();
    await firstSubscription.cancel();
    await first.dispose();

    final second = WindowsClipboardSource(channel: channel);
    final secondErrors = <Object>[];
    final secondSubscription =
        second.urgentDiagnostics.listen(secondErrors.add);
    await second.start();
    expect(generations[1], isNot(generations[0]));
    await send(generations[0]);
    await send(null);
    await send('invalid');
    expect(secondErrors, isEmpty);
    await send(generations[1]);
    expect(secondErrors, hasLength(1));
    await secondSubscription.cancel();
    await second.dispose();
  });

  test('starts and stops the native listener', () async {
    final source = WindowsClipboardSource(channel: channel);
    await source.start();
    await expectLater(source.start(), throwsStateError);
    await source.stop();
    await source.dispose();
    expect(calls, ['start', 'stop']);
  });

  test('stop waits for a pending start before unregistering', () async {
    final gate = Completer<void>();
    final invoked = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      invoked.add(call.method);
      if (call.method == 'start') await gate.future;
      return null;
    });
    final source = WindowsClipboardSource(channel: channel);
    try {
      final start = source.start();
      final stop = source.stop();
      await Future<void>.delayed(Duration.zero);
      expect(invoked, ['start']);
      gate.complete();
      await Future.wait([start, stop]);
      expect(invoked, ['start', 'stop']);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await source.dispose();
    }
  });

  test('failed start may have registered and requires cleanup', () async {
    var registered = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        registered = true;
        throw PlatformException(code: 'reply_failed');
      }
      if (call.method == 'stop') registered = false;
      return null;
    });
    final source = WindowsClipboardSource(channel: channel);
    try {
      await expectLater(source.start(), throwsA(isA<PlatformException>()));
      expect(registered, isTrue);
      await source.stop();
      expect(registered, isFalse);
    } finally {
      await source.dispose();
    }
  });

  test('failed stop fences new snapshots while cleanup can be retried',
      () async {
    var stops = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop' && ++stops == 1) {
        throw PlatformException(code: 'listener_failed');
      }
      return null;
    });
    final source = WindowsClipboardSource(channel: channel);
    final snapshots = <ClipboardSnapshot>[];
    final subscription = source.snapshots.listen(snapshots.add);
    try {
      await source.start();
      await expectLater(source.stop(), throwsA(isA<PlatformException>()));
      final delivered = Completer<ByteData?>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('changed', 'late synthetic')),
        delivered.complete,
      );
      final response = await delivered.future;
      expect(response, isNotNull);
      expect(() => const StandardMethodCodec().decodeEnvelope(response!),
          throwsA(isA<PlatformException>()));
      expect(snapshots, isEmpty);
      await expectLater(source.start(), throwsStateError);
      await source.stop();
      expect(stops, 2);
    } finally {
      await subscription.cancel();
      await source.dispose();
    }
  });

  test('concurrent stops share the drain and accept its snapshots', () async {
    final stopGate = Completer<void>();
    var stops = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop') {
        stops++;
        await stopGate.future;
      }
      return null;
    });
    final source = WindowsClipboardSource(channel: channel);
    final snapshots = <ClipboardSnapshot>[];
    final subscription = source.snapshots.listen(snapshots.add);
    try {
      await source.start();
      final first = source.stop();
      final second = source.stop();
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('changed', 'during drain')),
        (_) => delivered.complete(),
      );
      await delivered.future;
      expect(snapshots.single.value, 'during drain');
      expect(stops, 1);
      stopGate.complete();
      await Future.wait([first, second]);
    } finally {
      if (!stopGate.isCompleted) stopGate.complete();
      await subscription.cancel();
      await source.dispose();
    }
  });

  test('concurrent failed stops share error and allow cleanup retry', () async {
    final stopGate = Completer<void>();
    var stops = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop' && ++stops == 1) {
        await stopGate.future;
        throw PlatformException(code: 'listener_failed');
      }
      return null;
    });
    final source = WindowsClipboardSource(channel: channel);
    try {
      await source.start();
      final first = source.stop();
      final second = source.stop();
      final firstError = expectLater(first, throwsA(isA<PlatformException>()));
      final secondError =
          expectLater(second, throwsA(isA<PlatformException>()));
      stopGate.complete();
      await Future.wait([firstError, secondError]);
      expect(stops, 1);
      await source.stop();
      expect(stops, 2);
    } finally {
      if (!stopGate.isCompleted) stopGate.complete();
      await source.dispose();
    }
  });

  test('reentrant stop shares the in-progress native stop', () async {
    final gate = Completer<void>();
    final invoked = Completer<void>();
    var stops = 0;
    final source = WindowsClipboardSource(channel: channel);
    Future<void>? nested;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop') {
        stops++;
        nested = source.stop();
        invoked.complete();
        await gate.future;
      }
      return null;
    });
    try {
      await source.start();
      final first = source.stop();
      await invoked.future;
      expect(stops, 1);
      expect(nested, isNotNull);
      gate.complete();
      await Future.wait([first, nested!]);
      expect(stops, 1);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await source.dispose();
    }
  });

  test('forwards each native snapshot in order', () async {
    final values = <Object?>[];
    final source = WindowsClipboardSource(channel: channel);
    final subscription = source.events.listen(values.add);
    await source.start();
    for (final text in ['first', 'second']) {
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('changed', text)),
        (_) => delivered.complete(),
      );
      await delivered.future;
    }
    await Future<void>.delayed(Duration.zero);
    expect(values, ['first', 'second']);
    await subscription.cancel();
    await source.dispose();
  });

  test('snapshot is delivered before native channel reply', () async {
    final source = WindowsClipboardSource(channel: channel);
    final snapshots = <ClipboardSnapshot>[];
    final subscription = source.snapshots.listen(snapshots.add);
    try {
      await source.start();
      final delivered = Completer<bool>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall(
            'changed', {'text': 'synthetic', 'textTooLarge': true})),
        (_) => delivered.complete(snapshots.length == 1),
      );
      expect(await delivered.future, isTrue);
      expect(snapshots.single.value, 'synthetic');
      expect(snapshots.single.warning.toString(), contains('1 MiB'));
    } finally {
      await subscription.cancel();
      await source.dispose();
    }
  });

  test('rejects unclaimed snapshot when recording acknowledgement is required',
      () async {
    final source = WindowsClipboardSource(channel: channel)
      ..requireRecordingAcknowledgement = true;
    try {
      await source.start();
      final reply = Completer<ByteData?>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('changed', 'synthetic')),
        reply.complete,
      );
      final envelope = await reply.future;
      expect(
        () => const StandardMethodCodec().decodeEnvelope(envelope!),
        throwsA(isA<PlatformException>()),
      );
    } finally {
      await source.dispose();
    }
  });

  test('reports a native capture overflow without payload', () async {
    final source = WindowsClipboardSource(channel: channel);
    final snapshots = <ClipboardSnapshot>[];
    final subscription = source.snapshots.listen(snapshots.add);
    try {
      await source.start();
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
              const MethodCall('changed', {'captureDropped': true})),
          (_) => delivered.complete());
      await delivered.future;
      expect(snapshots, hasLength(1));
      expect(snapshots.single.value, isNull);
      expect(snapshots.single.warning.toString(), contains('hàng đợi đầy'));
    } finally {
      await subscription.cancel();
      await source.dispose();
    }
  });

  test('forwards image bytes only while listener is active', () async {
    final values = <Object?>[];
    final errors = <Object>[];
    final source = WindowsClipboardSource(channel: channel);
    final subscription = source.events.listen(values.add, onError: errors.add);
    Future<void> send(Object value) async {
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('changed', value)),
        (_) => delivered.complete(),
      );
      await delivered.future;
      await Future<void>.delayed(Duration.zero);
    }

    try {
      await source.start();
      await send(Uint8List.fromList([1, 2, 3]));
      await send(42);
      await send(Uint8List(10 * 1024 * 1024 + 1));
      await send(Uint8List(0));
      expect(errors, hasLength(2));
      expect(values, hasLength(1));
      expect(values.single, orderedEquals([1, 2, 3]));
      await source.stop();
      await send(Uint8List.fromList([4, 5, 6]));
      expect(values, hasLength(1));
    } finally {
      await subscription.cancel();
      await source.dispose();
    }
  });

  test('forwards a combined snapshot and retains text for invalid image',
      () async {
    final values = <Object?>[];
    final errors = <Object>[];
    final source = WindowsClipboardSource(channel: channel);
    final subscription = source.events.listen(values.add, onError: errors.add);
    Future<void> send(Map<String, Object> value) async {
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('changed', value)),
        (_) => delivered.complete(),
      );
      await delivered.future;
      await Future<void>.delayed(Duration.zero);
    }

    try {
      await source.start();
      await send({
        'png': Uint8List.fromList([1, 2, 3]),
        'text': 'fallback'
      });
      await send({'png': Uint8List(10 * 1024 * 1024 + 1), 'text': 'large'});
      final snapshot = values.first as ClipboardImageWithText;
      expect(snapshot.image, orderedEquals([1, 2, 3]));
      expect(snapshot.text, 'fallback');
      expect(values.last, 'large');
      expect(errors, hasLength(1));
      expect(values, hasLength(2));
      await send({
        'png': Uint8List(0),
        'fallbackPng': Uint8List.fromList([4, 5, 6])
      });
      final promoted = values.last as ClipboardImageWithText;
      expect(promoted.image, orderedEquals([4, 5, 6]));
      expect(promoted.fallbackImage, isNull);
      expect(errors, hasLength(1));
      await send({
        'png': Uint8List.fromList([1]),
        'fallbackPng': Uint8List.fromList([2])
      });
      final both = values.last as ClipboardImageWithText;
      expect(both.image, orderedEquals([1]));
      expect(both.fallbackImage, orderedEquals([2]));
      await send({
        'png': Uint8List.fromList([3]),
        'fallbackUnavailable': true
      });
      expect((values.last as ClipboardImageWithText).image, orderedEquals([3]));
      expect(errors, hasLength(2));
      expect(errors.last.toString(), contains('ảnh dự phòng'));
      expect(errors.last.toString(), isNot(contains('Không thể nhận ảnh PNG')));
    } finally {
      await subscription.cancel();
      await source.dispose();
    }
  });

  test('reports oversized text and still forwards image', () async {
    final source = WindowsClipboardSource(channel: channel);
    final values = <Object?>[];
    final errors = <Object>[];
    final subscription = source.events.listen(values.add, onError: errors.add);
    try {
      await source.start();
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall('changed', {
          'textTooLarge': true,
          'png': Uint8List.fromList([1, 2, 3]),
        })),
        (_) => delivered.complete(),
      );
      await delivered.future;
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('1 MiB'));
      expect(values, hasLength(1));
      expect((values.single as ClipboardImageWithText).image, [1, 2, 3]);
    } finally {
      await subscription.cancel();
      await source.dispose();
    }
  });

  test('warns for a text-only oversized snapshot, not malformed flags',
      () async {
    final source = WindowsClipboardSource(channel: channel);
    final values = <Object?>[];
    final errors = <Object>[];
    final subscription = source.events.listen(values.add, onError: errors.add);
    Future<void> send(Map<String, Object> value) async {
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(MethodCall('changed', value)),
          (_) => delivered.complete());
      await delivered.future;
      await Future<void>.delayed(Duration.zero);
    }

    try {
      await source.start();
      await send({'textTooLarge': true});
      await send({'textTooLarge': false});
      await send({'textTooLarge': 'true'});
      expect(errors, hasLength(1));
      expect(values, isEmpty);
      await source.stop();
      await send({'textTooLarge': true});
      expect(errors, hasLength(1));
    } finally {
      await subscription.cancel();
      await source.dispose();
    }
  });

  test('reports native PNG rejection while preserving text', () async {
    final source = WindowsClipboardSource(channel: channel);
    final values = <Object?>[];
    final errors = <Object>[];
    final subscription = source.events.listen(values.add, onError: errors.add);
    try {
      await source.start();
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(const MethodCall('changed', {
            'pngRejected': true,
            'text': 'synthetic fallback',
          })),
          (_) => delivered.complete());
      await delivered.future;
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('Không thể nhận ảnh PNG'));
      expect(values, ['synthetic fallback']);
    } finally {
      await subscription.cancel();
      await source.dispose();
    }
  });

  test('reports both losses together for one snapshot', () async {
    final source = WindowsClipboardSource(channel: channel);
    final errors = <Object>[];
    final subscription = source.events.listen((_) {}, onError: errors.add);
    try {
      await source.start();
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(const MethodCall('changed', {
            'pngRejected': true,
            'textTooLarge': true,
          })),
          (_) => delivered.complete());
      await delivered.future;
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('1 MiB'));
      expect(errors.single.toString(), contains('ảnh PNG'));
    } finally {
      await subscription.cancel();
      await source.dispose();
    }
  });

  test('cleans up when native start fails', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        throw PlatformException(code: 'listener_failed');
      }
      return null;
    });
    final source = WindowsClipboardSource(channel: channel);
    await expectLater(
        source.start(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'listener_failed')));
    await source.dispose();
  });
}
