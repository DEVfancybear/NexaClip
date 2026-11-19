import 'dart:typed_data';

import 'png_validation.dart';
import 'text_history_store.dart';

/// Image and text captured from the same clipboard change.
class ClipboardImageWithText {
  const ClipboardImageWithText(this.image, this.text, {this.fallbackImage});
  final Uint8List image;
  final String? text;
  final Uint8List? fallbackImage;
}

/// Serializes clipboard events so database writes keep their observed order.
class TextHistoryRecorder {
  TextHistoryRecorder(this.store,
      {DateTime Function()? clock, this.onImageRejected})
      : _clock = clock ?? DateTime.now;

  final void Function()? onImageRejected;

  final TextHistoryStore store;
  final DateTime Function() _clock;
  static const maxPendingImageBytes = 20 * 1024 * 1024;
  int _pendingImageBytes = 0;
  Future<void> _pending = Future.value();
  Object? _writeError;
  StackTrace? _writeStack;

  /// Queues one observed clipboard value. Null and empty values are ignored.
  Future<bool> record(Object? value,
      {void Function(Object, StackTrace)? onFailure,
      void Function()? onRejected,
      void Function(bool)? onComplete}) {
    final text = value is String
        ? value
        : value is ClipboardImageWithText
            ? value.text
            : null;
    final bytes = value is Uint8List
        ? value
        : value is ClipboardImageWithText
            ? value.image
            : null;
    final fallback =
        value is ClipboardImageWithText ? value.fallbackImage : null;
    if ((bytes == null || bytes.isEmpty || bytes.length > maxPngBytes) &&
        (fallback == null ||
            fallback.isEmpty ||
            fallback.length > maxPngBytes) &&
        (text == null || text.isEmpty)) {
      if (onComplete == null &&
          (bytes == null || (onRejected == null && onImageRejected == null))) {
        return Future.value(false);
      }
      final imageWasRejected = bytes != null;
      final result = _pending.then((_) {
        try {
          if (imageWasRejected) (onRejected ?? onImageRejected)?.call();
        } catch (_) {}
        try {
          onComplete?.call(false);
        } catch (_) {}
        return false;
      });
      _pending =
          result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
      return result;
    }
    var validBytes =
        bytes != null && bytes.isNotEmpty && bytes.length <= maxPngBytes
            ? bytes
            : null;
    var validFallback = fallback != null &&
            fallback.isNotEmpty &&
            fallback.length <= maxPngBytes
        ? fallback
        : null;
    var imageDropped =
        bytes != null && validBytes == null && validFallback == null;
    if (_pendingImageBytes +
            (validBytes?.length ?? 0) +
            (validFallback?.length ?? 0) >
        maxPendingImageBytes) {
      if (text == null || text.isEmpty) {
        final result = _pending
            .then<bool>((_) => throw StateError('Hàng đợi ảnh đã đầy.'));
        _pending = result.then<void>((_) {},
            onError: (Object error, StackTrace stack) {
          try {
            onFailure?.call(error, stack);
          } catch (_) {}
        });
        return result;
      }
      validBytes = null;
      validFallback = null;
      imageDropped = true;
    }
    final timestamp = _clock();
    final image = validBytes == null ? null : Uint8List.fromList(validBytes);
    final fallbackImage =
        validFallback == null ? null : Uint8List.fromList(validFallback);
    final reservedBytes = (image?.length ?? 0) + (fallbackImage?.length ?? 0);
    _pendingImageBytes += reservedBytes;
    final result = _pending.then((_) async {
      try {
        if (imageDropped) {
          try {
            (onRejected ?? onImageRejected)?.call();
          } catch (_) {
            // Diagnostics must not change the write outcome.
          }
        }
        if (image != null) {
          if (await isSupportedPng(image)) {
            await store.addImage(image, timestamp);
            return true;
          }
        }
        if (fallbackImage != null && await isSupportedPng(fallbackImage)) {
          await store.addImage(fallbackImage, timestamp);
          return true;
        }
        if (image != null || fallbackImage != null) {
          try {
            (onRejected ?? onImageRejected)?.call();
          } catch (_) {}
        }
        if (text == null || text.isEmpty) return false;
        await store.add(text, timestamp);
        return true;
      } finally {
        _pendingImageBytes -= reservedBytes;
      }
    });
    // A failed write is reported to its caller, but does not stop later writes.
    _pending = result.then<void>((recorded) {
      try {
        onComplete?.call(recorded);
      } catch (_) {}
    }, onError: (Object error, StackTrace stack) {
      _writeError ??= error;
      _writeStack ??= stack;
      try {
        onFailure?.call(error, stack);
      } catch (_) {}
    });
    return result;
  }

  /// Delivers a source diagnostic after earlier snapshot work has completed.
  void enqueueDiagnostic(void Function() deliver) {
    _pending = _pending.then((_) {
      try {
        deliver();
      } catch (_) {
        // Diagnostics must not turn into persistence failures.
      }
    });
  }

  /// Waits for all writes that were queued before this call.
  Future<void> flush() async {
    await _pending;
    final error = _writeError;
    final stack = _writeStack;
    _writeError = null;
    _writeStack = null;
    if (error != null) Error.throwWithStackTrace(error, stack!);
  }
}
