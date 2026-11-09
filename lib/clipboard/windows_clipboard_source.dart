import 'dart:async';

import 'package:flutter/services.dart';

/// Emits the text available when Windows reports a clipboard change.
class WindowsClipboardSource {
  WindowsClipboardSource({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('nexaclip/clipboard');

  final MethodChannel _channel;
  final StreamController<String?> _events = StreamController.broadcast();
  bool _active = false;

  Stream<String?> get events => _events.stream;

  Future<void> start() async {
    if (_active) throw StateError('Clipboard source is already active');
    _channel.setMethodCallHandler(_handleCall);
    _active = true;
    try {
      await _channel.invokeMethod<void>('start');
    } catch (_) {
      _active = false;
      _channel.setMethodCallHandler(null);
      rethrow;
    }
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method != 'changed') throw MissingPluginException();
    if (_active && !_events.isClosed && call.arguments is String) {
      _events.add(call.arguments as String);
    }
  }

  Future<void> stop() async {
    if (!_active) return;
    await _channel.invokeMethod<void>('stop');
    _active = false;
    _channel.setMethodCallHandler(null);
  }

  Future<void> dispose() async {
    try {
      await stop();
    } finally {
      _channel.setMethodCallHandler(null);
      await _events.close();
    }
  }
}
