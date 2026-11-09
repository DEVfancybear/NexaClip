import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'clipboard/history_session.dart';
import 'clipboard/text_history_store.dart';
import 'clipboard/windows_clipboard_source.dart';

void main() => runApp(const ClipboardApp());

class ClipboardApp extends StatelessWidget {
  const ClipboardApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'NexaClip',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const ClipboardHomePage(),
      );
}

class ClipboardHomePage extends StatefulWidget {
  const ClipboardHomePage(
      {super.key, this.supportDirectory, this.storeFactory});

  final Future<Directory> Function()? supportDirectory;
  final TextHistoryStore Function(Database)? storeFactory;

  @override
  State<ClipboardHomePage> createState() => _ClipboardHomePageState();
}

class _ClipboardHomePageState extends State<ClipboardHomePage> {
  Database? _database;
  TextHistoryStore? _store;
  HistorySession? _session;
  List<TextHistoryEntry> _entries = [];
  String? _error;
  bool _busy = true;
  int _refreshGeneration = 0;
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onExitRequested: _requestExit);
    _initialize();
  }

  Future<void> _initialize() async {
    Database? openedDatabase;
    try {
      sqfliteFfiInit();
      final directory =
          await (widget.supportDirectory ?? getApplicationSupportDirectory)();
      await directory.create(recursive: true);
      final db = await databaseFactoryFfi
          .openDatabase(p.join(directory.path, 'history.db'));
      openedDatabase = db;
      if (!mounted) {
        await db.close();
        openedDatabase = null;
        return;
      }
      final store = widget.storeFactory?.call(db) ?? TextHistoryStore(db);
      await store.initialize();
      if (!mounted) {
        await db.close();
        openedDatabase = null;
        return;
      }
      _database = db;
      openedDatabase = null;
      _store = store;
      _session = HistorySession(
        store: store,
        source: WindowsClipboardSource(),
        onError: (error, _) => _showError(error),
        onRecorded: () => unawaited(_refresh()),
      );
      await _refresh();
    } catch (error) {
      await openedDatabase?.close();
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(Object error) {
    if (mounted) setState(() => _error = 'Có lỗi: $error');
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    try {
      final entries = await _store!.list();
      if (mounted && generation == _refreshGeneration) {
        setState(() => _entries = entries);
      }
    } catch (error) {
      if (generation == _refreshGeneration) _showError(error);
    }
  }

  Future<AppExitResponse> _requestExit() async {
    if (_busy) return AppExitResponse.cancel;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _session?.stop();
      return AppExitResponse.exit;
    } catch (error) {
      _showError(error);
      if (mounted) setState(() => _busy = false);
      return AppExitResponse.cancel;
    }
  }

  Future<void> _toggle() async {
    final session = _session!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (session.isActive) {
        await session.stop();
      } else {
        await session.start();
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    final session = _session;
    final db = _database;
    unawaited(() async {
      try {
        await session?.dispose();
      } catch (error, stack) {
        FlutterError.reportError(FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'NexaClip',
          context: ErrorDescription('while stopping clipboard capture'),
        ));
      } finally {
        await db?.close();
      }
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _session?.isActive ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('NexaClip')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Lịch sử văn bản', style: TextStyle(fontSize: 22)),
          const SizedBox(height: 8),
          const Text(
              'Lịch sử văn bản được lưu trên máy mà không mã hóa. Nội dung có thể chứa mật khẩu hoặc thông tin nhạy cảm.'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy || _session == null ? null : _toggle,
            child: Text(active ? 'Dừng theo dõi' : 'Bắt đầu theo dõi'),
          ),
          if (_error != null)
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 16),
          Expanded(
              child: _entries.isEmpty
                  ? const Center(child: Text('Chưa có lịch sử văn bản.'))
                  : ListView.builder(
                      itemCount: _entries.length,
                      itemBuilder: (context, index) => ListTile(
                        title: Text(_entries[index].text,
                            maxLines: 3, overflow: TextOverflow.ellipsis),
                        subtitle:
                            Text(_entries[index].copiedAt.toLocal().toString()),
                      ),
                    )),
        ]),
      ),
    );
  }
}
