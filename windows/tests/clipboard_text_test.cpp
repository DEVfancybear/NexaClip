#include "../runner/clipboard_text.h"

#include <iostream>
#define CHECK(x) do { if (!(x)) { std::cerr << "Failed at line " << __LINE__ << '\n'; return 1; } } while (false)
#include <string>

int main() {
  const size_t limit = kMaxClipboardTextUtf8Bytes;
  std::wstring ascii(limit, L'a');
  auto decoded = DecodeClipboardText(ascii.c_str(), ascii.size() + 1);
  CHECK(decoded && decoded->size() == limit);
  ascii.push_back(L'a');
  bool too_large = false;
  CHECK(!DecodeClipboardText(ascii.c_str(), ascii.size() + 1, &too_large));
  CHECK(too_large);
  std::wstring multibyte(limit / 3, L'\u0800');
  decoded = DecodeClipboardText(multibyte.c_str(), multibyte.size() + 1);
  CHECK(decoded && decoded->size() == (limit / 3) * 3);
  multibyte.push_back(L'\u0800');
  CHECK(!DecodeClipboardText(multibyte.c_str(), multibyte.size() + 1, &too_large));
  CHECK(too_large);
  std::wstring surrogate;
  surrogate.reserve(limit / 2 + 2);
  for (size_t i = 0; i < limit / 4; ++i) {
    surrogate.push_back(static_cast<wchar_t>(0xd83d));
    surrogate.push_back(static_cast<wchar_t>(0xde00));
  }
  decoded = DecodeClipboardText(surrogate.c_str(), surrogate.size() + 1);
  CHECK(decoded && decoded->size() == limit);
  surrogate.push_back(L'a');
  CHECK(!DecodeClipboardText(surrogate.c_str(), surrogate.size() + 1));
  const wchar_t invalid[] = {static_cast<wchar_t>(0xd800), 0};
  CHECK(!DecodeClipboardText(invalid, 2, &too_large));
  CHECK(!too_large);
  const wchar_t unterminated[] = {L'a', L'b'};
  CHECK(!DecodeClipboardText(unterminated, 2, &too_large));
  CHECK(!too_large);
  const wchar_t padded[] = {L'a', 0, L'b'};
  CHECK(DecodeClipboardText(padded, 3) == std::optional<std::string>("a"));
  CHECK(!DecodeClipboardText(nullptr, 0));
}
