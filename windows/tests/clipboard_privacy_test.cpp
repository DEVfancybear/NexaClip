#include "../runner/clipboard_privacy.h"
#include <iostream>
#include <string>

#define CHECK(x) do { if (!(x)) { std::cerr << "Failed at line " << __LINE__ << '\n'; return 1; } } while (false)

int main() {
  unsigned failed_format = 0;
  bool excluded = false, has_history = false;
  bool history_allowed = false;
  int reads = 0;
  auto reg = [&](const wchar_t* name) -> unsigned {
    const unsigned format = std::wstring(name) == L"CanIncludeInClipboardHistory" ? 2 : 1;
    return format == failed_format ? 0 : format;
  };
  auto available = [&](unsigned format) { return format == 1 ? excluded : has_history; };
  auto read = [&](unsigned format) { ++reads; return format == 2 && history_allowed; };
  auto allowed = [&] { return ClipboardHistoryAllowed(reg, available, read); };
  CHECK(allowed()); CHECK(reads == 0);
  excluded = true; has_history = true; history_allowed = true;
  CHECK(!allowed()); CHECK(reads == 0);
  excluded = false; history_allowed = false;
  CHECK(!allowed()); CHECK(reads == 1);
  history_allowed = true;
  CHECK(allowed()); CHECK(reads == 2);
  failed_format = 1;
  CHECK(!allowed()); CHECK(reads == 2);
  failed_format = 2;
  CHECK(!allowed()); CHECK(reads == 2);

  uint32_t marker = 0;
  size_t bytes = sizeof(marker);
  bool lock_fails = false;
  int sizes = 0, locks = 0, unlocks = 0;
  auto marker_allowed = [&](int handle) {
    return ReadClipboardHistoryMarker(handle,
      [&](int) { ++sizes; return bytes; },
      [&](int) -> const void* { ++locks; return lock_fails ? nullptr : &marker; },
      [&](int) noexcept { ++unlocks; });
  };
  CHECK(!marker_allowed(0)); CHECK(sizes == 0 && locks == 0 && unlocks == 0);
  bytes = sizeof(marker) - 1;
  CHECK(!marker_allowed(1)); CHECK(sizes == 1 && locks == 0 && unlocks == 0);
  bytes = sizeof(marker); lock_fails = true;
  CHECK(!marker_allowed(1)); CHECK(locks == 1 && unlocks == 0);
  lock_fails = false;
  CHECK(!marker_allowed(1)); CHECK(locks == 2 && unlocks == 1);
  marker = 1;
  CHECK(marker_allowed(1)); CHECK(locks == 3 && unlocks == 2);
  marker = 42;
  CHECK(!marker_allowed(1)); CHECK(locks == 4 && unlocks == 3);
  return 0;
}
