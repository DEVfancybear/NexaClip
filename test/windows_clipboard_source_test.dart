import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexaclip/clipboard/windows_clipboard_source.dart';

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

  test('starts and stops the native listener', () async {
    final source = WindowsClipboardSource(channel: channel);
    await source.start();
    await expectLater(source.start(), throwsStateError);
    await source.stop();
    await source.dispose();
    expect(calls, ['start', 'stop']);
  });

  test('forwards each native snapshot in order', () async {
    final values = <String?>[];
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

  test('clears its handler when native start fails', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'listener_failed');
    });
    final source = WindowsClipboardSource(channel: channel);
    await expectLater(
        source.start(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'listener_failed')));
    await source.dispose();
  });
}
