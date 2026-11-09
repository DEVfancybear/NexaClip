// Test-only Windows entrypoint for close_pending_write.py.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:nexaclip/main.dart';

const token = 'NexaClip-close-pending-synthetic';
const directoryPath = String.fromEnvironment('CLOSE_TEST_DIRECTORY');

class GatedStore extends TextHistoryStore {
  GatedStore(super.database);

  @override
  Future<void> add(String text, DateTime copiedAt) async {
    if (text != token) return;
    await File('$directoryPath/write_started').writeAsString('ready');
    while (!await File('$directoryPath/release').exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    await super.add(text, copiedAt);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('close waits for the pending write', (tester) async {
    if (directoryPath.isEmpty) {
      throw StateError('CLOSE_TEST_DIRECTORY required');
    }
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('nexaclip/clipboard'),
      (call) async {
        if (call.method != 'start' && call.method != 'stop') {
          throw MissingPluginException();
        }
        await File('$directoryPath/mock_${call.method}')
            .writeAsString('called');
        return null;
      },
    );
    await tester.pumpWidget(MaterialApp(
      home: ClipboardHomePage(
        supportDirectory: () async => Directory(directoryPath),
        storeFactory: GatedStore.new,
      ),
    ));
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final button =
          tester.widget<FilledButton>(find.byType(FilledButton).first);
      if (button.onPressed != null) break;
    }
    await tester.tap(find.text('Bắt đầu theo dõi'));
    await tester.pumpAndSettle();
    expect(find.text('Dừng theo dõi'), findsOneWidget);
    final message = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('changed', token),
    );
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'nexaclip/clipboard',
      message,
      (_) {},
    );
    while (!await File('$directoryPath/write_started').exists()) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    while (true) {
      await tester.pump(const Duration(milliseconds: 25));
      final button =
          tester.widget<FilledButton>(find.byType(FilledButton).first);
      if (button.onPressed == null) {
        await File('$directoryPath/exit_started').writeAsString('ready');
        break;
      }
    }
    while (true) {
      await tester.pump(const Duration(milliseconds: 25));
    }
  });
}
