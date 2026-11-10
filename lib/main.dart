import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  String _query = '';
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
    if (_busy) return;
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

  Future<void> _copyText(String text) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    ScaffoldMessenger.of(context).clearSnackBars();
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã sao chép vào clipboard.')),
        );
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePin(TextHistoryEntry entry) async {
    if (_busy) return;
    if (entry.pinned) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Bỏ ghim?'),
          content: const Text(
              'Mục cũ có thể bị xóa ngay nếu vượt giới hạn 500 mục không ghim.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Hủy')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Bỏ ghim')),
          ],
        ),
      );
      if (!mounted || _busy || confirmed != true) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _store!.setPinned(entry.id, !entry.pinned);
      await _refresh();
    } catch (error) {
      await _refresh();
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearHistory() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xóa lịch sử?'),
        content: const Text(
            'Thao tác này xóa toàn bộ lịch sử và dừng theo dõi clipboard. Dữ liệu có thể vẫn khôi phục được từ tệp hoặc bản sao lưu; đây không phải xóa an toàn.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Hủy')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Xóa')),
        ],
      ),
    );
    if (confirmed != true || !mounted || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _session!.stop();
      await _store!.clear();
      _refreshGeneration++;
      if (mounted) setState(() => _entries = []);
      await _refresh();
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
    final query = _query.toLowerCase();
    final visibleEntries = _entries
        .where((entry) => entry.text.toLowerCase().contains(query))
        .toList();
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
          TextButton.icon(
            onPressed: _busy || _session == null ? null : _clearHistory,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Xóa toàn bộ lịch sử'),
          ),
          if (_error != null)
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 16),
          TextField(
            decoration: const InputDecoration(
              labelText: 'Tìm trong lịch sử',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 12),
          Expanded(
              child: visibleEntries.isEmpty
                  ? Center(
                      child: Text(_query.isEmpty
                          ? 'Chưa có lịch sử văn bản.'
                          : 'Không tìm thấy kết quả.'))
                  : ListView.builder(
                      itemCount: visibleEntries.length,
                      itemBuilder: (context, index) => ListTile(
                        trailing:
                            Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            tooltip: visibleEntries[index].pinned
                                ? 'Bỏ ghim'
                                : 'Ghim',
                            onPressed: _busy
                                ? null
                                : () => _togglePin(visibleEntries[index]),
                            icon: Icon(visibleEntries[index].pinned
                                ? Icons.push_pin
                                : Icons.push_pin_outlined),
                          ),
                          IconButton(
                            tooltip: 'Sao chép',
                            onPressed: _busy
                                ? null
                                : () => _copyText(visibleEntries[index].text),
                            icon: const Icon(Icons.copy),
                          ),
                        ]),
                        title: Text(visibleEntries[index].text,
                            maxLines: _query.isEmpty ? 3 : null,
                            overflow:
                                _query.isEmpty ? TextOverflow.ellipsis : null),
                        subtitle: Text(visibleEntries[index]
                            .copiedAt
                            .toLocal()
                            .toString()),
                      ),
                    )),
        ]),
      ),
    );
  }
}
