#pragma once

#include "clipboard_image_attempt.h"
#include "clipboard_privacy.h"

// Callbacks execute only while the clipboard is open. A refused privacy check
// never reaches either payload callback. Close must not throw.
template <typename Open, typename Close, typename Allowed, typename Text, typename Image>
void CaptureClipboardSnapshot(Open open, Close close, Allowed allowed,
                              Text read_text, Image read_image) {
  if (!open()) return;
  struct Guard {
    Close& close;
    ~Guard() { close(); }
  } guard{close};
  if (!allowed()) return;
  try {
    read_text();
  } catch (const std::bad_alloc&) {
    // An optional text payload must not prevent an image capture.
  }
  AttemptClipboardImage(read_image);
}

template <typename Open, typename Close, typename Register, typename Available,
          typename ReadHistory, typename Text, typename Image>
void CaptureClipboardSnapshotWithPrivacy(Open open, Close close, Register reg,
                                         Available available, ReadHistory history,
                                         Text text, Image image) {
  CaptureClipboardSnapshot(open, close,
      [&] { return ClipboardHistoryAllowed(reg, available, history); },
      text, image);
}
