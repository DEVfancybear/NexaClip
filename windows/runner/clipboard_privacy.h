#ifndef RUNNER_CLIPBOARD_PRIVACY_H_
#define RUNNER_CLIPBOARD_PRIVACY_H_

#include <cstdint>
#include <cstring>

// Read the history marker while the clipboard is open. Unlock must not throw.
template <typename Handle, typename Size, typename Lock, typename Unlock>
bool ReadClipboardHistoryMarker(Handle handle, Size size, Lock lock, Unlock unlock) {
  if (!handle || size(handle) < sizeof(uint32_t)) return false;
  const void* value = lock(handle);
  if (!value) return false;
  struct Guard {
    Handle handle;
    Unlock& unlock;
    ~Guard() { unlock(handle); }
  } guard{handle, unlock};
  uint32_t marker;
  std::memcpy(&marker, value, sizeof(marker));
  return marker == 1;
}

// Call while the clipboard is open. An unreadable marker is private.
template <typename Register, typename Available, typename ReadHistory>
bool ClipboardHistoryAllowed(Register register_format, Available available,
                             ReadHistory read_history) {
  const auto exclude = register_format(L"ExcludeClipboardContentFromMonitorProcessing");
  const auto history = register_format(L"CanIncludeInClipboardHistory");
  if (!exclude || !history || available(exclude)) return false;
  if (!available(history)) return true;
  return read_history(history);
}

#endif  // RUNNER_CLIPBOARD_PRIVACY_H_
