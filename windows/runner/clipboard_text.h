#ifndef RUNNER_CLIPBOARD_TEXT_H_
#define RUNNER_CLIPBOARD_TEXT_H_

#include <windows.h>

#include <algorithm>
#include <cstddef>
#include <optional>
#include <string>

// Limit the scan and the resulting UTF-8 allocation. Never truncate text.
constexpr size_t kMaxClipboardTextUtf8Bytes = 1024 * 1024;

inline std::optional<std::string> DecodeClipboardText(
    const wchar_t* chars, size_t available_chars, bool* too_large = nullptr) {
  if (too_large) *too_large = false;
  if (!chars) return std::nullopt;
  const size_t scan_count = (std::min)(available_chars, kMaxClipboardTextUtf8Bytes + 1);
  size_t length = 0;
  while (length < scan_count && chars[length] != L'\0') ++length;
  if (length == scan_count) {
    if (too_large && scan_count > kMaxClipboardTextUtf8Bytes) *too_large = true;
    return std::nullopt;
  }
  if (length == 0) return std::nullopt;
  const int input_length = static_cast<int>(length);
  const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, chars,
                                        input_length, nullptr, 0, nullptr, nullptr);
  if (bytes <= 0) return std::nullopt;
  if (static_cast<size_t>(bytes) > kMaxClipboardTextUtf8Bytes) {
    if (too_large) *too_large = true;
    return std::nullopt;
  }
  std::string copy(bytes, '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, chars, input_length,
                          copy.data(), bytes, nullptr, nullptr) != bytes)
    return std::nullopt;
  return copy;
}

#endif  // RUNNER_CLIPBOARD_TEXT_H_
