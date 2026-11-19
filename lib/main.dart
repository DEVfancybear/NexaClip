import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'clipboard/history_session.dart';
import 'clipboard/image_pixels.dart';
import 'clipboard/png_validation.dart';
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
      {super.key,
      this.supportDirectory,
      this.storeFactory,
      this.closeDatabase,
      this.onExitCallbackReady});

  final Future<Directory> Function()? supportDirectory;
  final TextHistoryStore Function(Database)? storeFactory;
  final Future<void> Function(Database)? closeDatabase;
  @visibleForTesting
  final void Function(Future<AppExitResponse> Function())? onExitCallbackReady;

  @override
  State<ClipboardHomePage> createState() => _ClipboardHomePageState();
}

class _ClipboardHomePageState extends State<ClipboardHomePage>
    with WidgetsBindingObserver {
  Database? _database;
  TextHistoryStore? _store;
  HistorySession? _session;
  List<TextHistoryEntry> _entries = [];
  String _query = '';
  String? _error;
  ClipboardCaptureFailure? _captureFailure;
  bool _busy = true;
  bool _closeFailed = false;
  Future<AppExitResponse>? _exitOperation;
  final Set<Future<void>> _refreshes = {};
  bool _shuttingDown = false;
  bool get _unavailable => _busy || _closeFailed;
  bool _previewOpen = false;
  int _refreshGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.onExitCallbackReady?.call(_requestExit);
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
    if (!mounted) return;
    setState(() {
      if (error is ClipboardCaptureFailure) {
        _captureFailure = error;
      } else {
        _error = 'Có lỗi: $error';
      }
    });
  }

  Future<void> _refresh() {
    if (_shuttingDown) return Future.value();
    late final Future<void> operation;
    operation = _doRefresh().whenComplete(() => _refreshes.remove(operation));
    _refreshes.add(operation);
    return operation;
  }

  Future<void> _doRefresh() async {
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

  @override
  Future<AppExitResponse> didRequestAppExit() => _requestExit();

  Future<AppExitResponse> _requestExit() {
    if (!mounted || _busy) return Future.value(AppExitResponse.cancel);
    final operation = _performExit();
    _exitOperation = operation;
    return operation.whenComplete(() {
      if (identical(_exitOperation, operation)) _exitOperation = null;
    });
  }

  Future<AppExitResponse> _performExit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    _shuttingDown = true;
    _refreshGeneration++;
    try {
      if (!_closeFailed) await _session?.stop();
      await Future.wait(_refreshes.toList());
      final db = _database;
      if (db != null && db.isOpen) {
        _closeFailed = true;
        await (widget.closeDatabase?.call(db) ?? db.close());
      }
      _database = null;
      return AppExitResponse.exit;
    } catch (error) {
      if (!_closeFailed && mounted) _shuttingDown = false;
      _showError(error);
      if (mounted) setState(() => _busy = false);
      return AppExitResponse.cancel;
    }
  }

  Future<void> _toggle() async {
    if (_unavailable) return;
    final session = _session!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (session.isActive) {
        await session.stop();
      } else {
        final previousFailure = _captureFailure;
        if (mounted) setState(() => _captureFailure = null);
        try {
          await session.start();
        } catch (_) {
          if (mounted) setState(() => _captureFailure ??= previousFailure);
          rethrow;
        }
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyText(String text) async {
    if (_unavailable) return;
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

  Future<void> _copyImage(TextHistoryEntry entry) async {
    if (_unavailable) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    ScaffoldMessenger.of(context).clearSnackBars();
    try {
      final sequence = await const MethodChannel('nexaclip/clipboard')
          .invokeMethod<int>('clipboardSequence');
      if (sequence == null || sequence == 0) {
        throw StateError('Không thể kiểm tra trạng thái clipboard.');
      }
      final png = await _store!.loadImage(entry.id);
      if (png == null) throw StateError('Ảnh không còn trong lịch sử.');
      final pixels = await decodeImagePixels(png);
      await const MethodChannel('nexaclip/clipboard').invokeMethod<void>(
        'copyImage',
        {
          'bgra': pixels.bgra,
          'width': pixels.width,
          'height': pixels.height,
          'sequence': sequence
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã sao chép vào clipboard.')),
        );
      }
    } on PlatformException catch (error) {
      if (error.code == 'clipboard_changed') {
        _showError(
            'Clipboard đã thay đổi trong khi chuẩn bị ảnh; hãy thử lại.');
      } else if (error.code == 'partial_write') {
        _showError(
            'Chỉ sao chép được một định dạng ảnh; clipboard đã thay đổi.');
      } else if (error.code == 'write_failed_after_empty') {
        _showError('Không sao chép được ảnh; clipboard đã bị xóa.');
      } else if (error.code == 'image_encode_failed') {
        _showError(
            'Không mã hóa được ảnh hoặc ảnh PNG vượt giới hạn 10 MiB; NexaClip chưa ghi clipboard.');
      } else {
        _showError(error);
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _viewImage(TextHistoryEntry entry) async {
    if (_unavailable || _previewOpen) return;
    setState(() {
      _busy = true;
      _previewOpen = true;
      _error = null;
    });
    MemoryImage? image;
    var loading = true;
    try {
      final bytes = await _store!.loadImage(entry.id);
      if (!mounted) return;
      if (bytes == null) {
        _showError('Ảnh không còn trong lịch sử.');
        return;
      }
      if (supportedPngDimensions(bytes) == null) {
        _showError('Ảnh PNG không hợp lệ hoặc quá lớn.');
        return;
      }
      image = MemoryImage(bytes);
      loading = false;
      setState(() => _busy = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Xem ảnh'),
          content: InteractiveViewer(
            child: Image(
                image: image!,
                errorBuilder: (_, __, ___) =>
                    const Text('Không thể hiển thị ảnh.')),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'))
          ],
        ),
      );
    } catch (error) {
      _showError(error);
    } finally {
      await image?.evict();
      _previewOpen = false;
      if (mounted && loading) setState(() => _busy = false);
    }
  }

  Future<void> _togglePin(TextHistoryEntry entry) async {
    if (_unavailable) return;
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
      if (!mounted || _unavailable || confirmed != true) return;
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

  Future<void> _deleteEntry(TextHistoryEntry entry) async {
    if (_unavailable) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xóa mục này?'),
        content: Text(entry.pinned
            ? 'Mục này đã được ghim. Dữ liệu có thể vẫn khôi phục được từ tệp hoặc bản sao lưu.'
            : 'Dữ liệu có thể vẫn khôi phục được từ tệp hoặc bản sao lưu.'),
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
    if (!mounted || _unavailable || confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _store!.delete(entry.id);
      _refreshGeneration++;
      if (mounted) {
        setState(
            () => _entries = _entries.where((e) => e.id != entry.id).toList());
      }
      await _refresh();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearHistory() async {
    if (_unavailable) return;
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
    if (confirmed != true || !mounted || _unavailable) return;
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
    final session = _session;
    final db = _database;
    final exitOperation = _exitOperation;
    WidgetsBinding.instance.removeObserver(this);
    _shuttingDown = true;
    _refreshGeneration++;
    unawaited(() async {
      try {
        try {
          if (exitOperation != null) await exitOperation;
          if (_refreshes.isNotEmpty) await Future.wait(_refreshes.toList());
        } catch (_) {
          // Cleanup below retries an incomplete close.
        }
        await session?.dispose();
      } catch (error, stack) {
        FlutterError.reportError(FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'NexaClip',
          context: ErrorDescription('while stopping clipboard capture'),
        ));
      } finally {
        try {
          if (db != null && db.isOpen) await db.close();
        } catch (error, stack) {
          FlutterError.reportError(FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'NexaClip',
            context: ErrorDescription('while closing the history database'),
          ));
        }
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
          const Text('Lịch sử clipboard', style: TextStyle(fontSize: 22)),
          const SizedBox(height: 8),
          const Text(
              'Lịch sử văn bản và ảnh được lưu trên máy mà không mã hóa. Nội dung có thể chứa mật khẩu hoặc thông tin nhạy cảm.'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _unavailable || _session == null ? null : _toggle,
            child: Text(active ? 'Dừng theo dõi' : 'Bắt đầu theo dõi'),
          ),
          TextButton.icon(
            onPressed: _unavailable || _session == null ? null : _clearHistory,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Xóa toàn bộ lịch sử'),
          ),
          if (_captureFailure != null)
            Text(
                active
                    ? '$_captureFailure Hãy dừng rồi bắt đầu theo dõi lại.'
                    : '$_captureFailure Hãy bắt đầu theo dõi lại.',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (_error != null)
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 16),
          TextField(
            decoration: const InputDecoration(
              labelText: 'Tìm văn bản trong lịch sử',
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
                          ? 'Chưa có lịch sử clipboard.'
                          : 'Không tìm thấy kết quả.'))
                  : ListView.builder(
                      itemCount: visibleEntries.length,
                      itemBuilder: (context, index) => ListTile(
                        onTap: _unavailable || !visibleEntries[index].isImage
                            ? null
                            : () => _viewImage(visibleEntries[index]),
                        trailing:
                            Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            tooltip: visibleEntries[index].pinned
                                ? 'Bỏ ghim'
                                : 'Ghim',
                            onPressed: _unavailable
                                ? null
                                : () => _togglePin(visibleEntries[index]),
                            icon: Icon(visibleEntries[index].pinned
                                ? Icons.push_pin
                                : Icons.push_pin_outlined),
                          ),
                          IconButton(
                            tooltip: 'Xóa mục',
                            onPressed: _unavailable
                                ? null
                                : () => _deleteEntry(visibleEntries[index]),
                            icon: const Icon(Icons.delete_outline),
                          ),
                          IconButton(
                            tooltip: 'Sao chép',
                            onPressed: _unavailable
                                ? null
                                : () => visibleEntries[index].isImage
                                    ? _copyImage(visibleEntries[index])
                                    : _copyText(visibleEntries[index].text),
                            icon: const Icon(Icons.copy),
                          ),
                        ]),
                        title: Text(
                            visibleEntries[index].isImage
                                ? 'Ảnh'
                                : visibleEntries[index].text,
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
