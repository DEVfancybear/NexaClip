#ifndef RUNNER_CLIPBOARD_BYTES_H_
#define RUNNER_CLIPBOARD_BYTES_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

// The clipboard remains open and owns the handle throughout this call.
// The unlock callback must not throw, including during exception unwinding.
template <typename Handle, typename Size, typename Lock, typename Unlock>
std::optional<std::vector<uint8_t>> CopyClipboardBytes(
    Handle handle, size_t limit, Size size_of, Lock lock, Unlock unlock) {
  if (!handle) return std::nullopt;
  const size_t size = size_of(handle);
  if (size == 0 || size > limit) return std::nullopt;
  const auto* data = static_cast<const uint8_t*>(lock(handle));
  if (!data) return std::nullopt;
  struct UnlockGuard {
    Handle handle;
    Unlock& unlock;
    ~UnlockGuard() { unlock(handle); }
  } guard{handle, unlock};
  return std::vector<uint8_t>(data, data + size);
}

#endif  // RUNNER_CLIPBOARD_BYTES_H_
