import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nexaclip/main.dart';
import 'package:nexaclip/clipboard/text_history_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class SyntheticOnlyStore extends TextHistoryStore {
  SyntheticOnlyStore(super.database);

  @override
  Future<void> add(String text, DateTime copiedAt) async {
    final allowed = <String>{
      'NexaClip-test-unicode-đ-😀',
      'NexaClip-long-${'x' * 40000}',
      'NexaClip-private-exclude',
      'NexaClip-private-zero',
      'NexaClip-private-both',
      'NexaClip-sentinel-both',
      'NexaClip-sentinel-exclude',
      'NexaClip-sentinel-zero',
      'NexaClip-allowed-one',
      'NexaClip-stopped',
      'NexaClip-restarted',
    };
    if (allowed.contains(text)) await super.add(text, copiedAt);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows clipboard snapshots and privacy markers',
      (tester) async {
    const python = String.fromEnvironment('TEST_PYTHON');
    expect(python, isNotEmpty,
        reason: 'Set TEST_PYTHON to a Windows Python executable');
    final directory =
        await Directory.systemTemp.createTemp('nexaclip_integration_');
    sqfliteFfiInit();
    Database? db;
    try {
      await tester.pumpWidget(MaterialApp(
        home: ClipboardHomePage(
          supportDirectory: () async => directory,
          storeFactory: SyntheticOnlyStore.new,
        ),
      ));
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        final button =
            tester.widget<FilledButton>(find.byType(FilledButton).first);
        if (button.onPressed != null) break;
      }
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await tester.pumpAndSettle();
      expect(find.text('Dừng theo dõi'), findsOneWidget);
      db = await databaseFactoryFfi
          .openDatabase('${directory.path}${Platform.pathSeparator}history.db');
      Future<List<String>> texts() async => (await db!.query('text_history'))
          .map((e) => e['text'] as String)
          .toList();
      Future<void> copy(String kind) async {
        final result = await Process.run(
            python, ['integration_test/set_clipboard.py', kind]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      Future<void> waitFor(String text) async {
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if ((await texts()).contains(text)) return;
        }
        fail('Did not record expected test value');
      }

      await copy('normal');
      await waitFor('NexaClip-test-unicode-đ-😀');
      await copy('long');
      await waitFor('NexaClip-long-${'x' * 40000}');
      await copy('exclude');
      await tester.pump(const Duration(milliseconds: 500));
      await copy('sentinel-exclude');
      await waitFor('NexaClip-sentinel-exclude');
      expect(await texts(), isNot(contains('NexaClip-private-exclude')));
      await copy('zero');
      await tester.pump(const Duration(milliseconds: 500));
      await copy('sentinel-zero');
      await waitFor('NexaClip-sentinel-zero');
      expect(await texts(), isNot(contains('NexaClip-private-zero')));
      await copy('both');
      await tester.pump(const Duration(milliseconds: 500));
      await copy('sentinel-both');
      await waitFor('NexaClip-sentinel-both');
      expect(await texts(), isNot(contains('NexaClip-private-both')));
      await copy('one');
      await waitFor('NexaClip-allowed-one');
      var values = await texts();
      expect(values, isNot(contains('NexaClip-private-exclude')));
      expect(values, isNot(contains('NexaClip-private-zero')));
      await tester.tap(find.text('Dừng theo dõi'));
      await tester.pumpAndSettle();
      await copy('stopped');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Bắt đầu theo dõi'));
      await tester.pumpAndSettle();
      await copy('restart');
      await waitFor('NexaClip-restarted');
      values = await texts();
      expect(values, isNot(contains('NexaClip-stopped')));
    } finally {
      try {
        await db?.close();
      } finally {
        try {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await Future<void>.delayed(const Duration(milliseconds: 300));
        } finally {
          await directory.delete(recursive: true);
        }
      }
    }
  });
}
