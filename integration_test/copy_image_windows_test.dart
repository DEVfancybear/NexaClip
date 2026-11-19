import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nexaclip/clipboard');
  final pixels = Uint8List.fromList([10, 20, 30, 255]);

  testWidgets('copies synthetic image without enabling clipboard capture',
      (tester) async {
    final sequence = await channel.invokeMethod<int>('clipboardSequence');
    expect(sequence, isNotNull);
    await channel.invokeMethod<void>('copyImage', {
      'sequence': sequence,
      'width': 1,
      'height': 1,
      'bgra': pixels,
    });
  }, skip: !const bool.fromEnvironment('NEXACLIP_ISOLATED_CLIPBOARD'));

  testWidgets('rejects a stale sequence without reading clipboard contents',
      (tester) async {
    final sequence = await channel.invokeMethod<int>('clipboardSequence');
    expect(sequence, isNotNull);
    await Clipboard.setData(
        const ClipboardData(text: 'NexaClip synthetic sequence test'));
    await expectLater(
      channel.invokeMethod<void>('copyImage', {
        'sequence': sequence,
        'width': 1,
        'height': 1,
        'bgra': pixels,
      }),
      throwsA(isA<PlatformException>()
          .having((e) => e.code, 'code', 'clipboard_changed')),
    );
  }, skip: !const bool.fromEnvironment('NEXACLIP_ISOLATED_CLIPBOARD'));
}
