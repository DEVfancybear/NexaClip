#include "../runner/clipboard_snapshot.h"
#include "../runner/clipboard_privacy.h"
#include "../runner/clipboard_text.h"
#include <iostream>
#include <new>
#include <stdexcept>
#include <string>

#define CHECK(x) do { if (!(x)) { std::cerr << "Failed at line " << __LINE__ << '\n'; return 1; } } while (false)

int main() {
  std::string calls;
  calls.reserve(16);
  std::string captured_text;
  bool opens = false, allowed = false, fail_image = false, fail_privacy = false, fail_text = false, text_oom = false;
  auto run = [&] {
    CaptureClipboardSnapshot(
      [&] { calls += 'O'; return opens; },
      [&]() noexcept { calls += 'C'; },
      [&] { calls += 'P'; if (fail_privacy) throw std::runtime_error("privacy"); return allowed; },
      [&] { calls += 'T'; if (fail_text) throw std::runtime_error("text"); if (text_oom) throw std::bad_alloc(); captured_text = "synthetic"; },
      [&] { calls += 'I'; if (fail_image) throw std::bad_alloc(); });
  };
  run(); CHECK(calls == "O");
  calls.clear(); opens = true; run(); CHECK(calls == "OPC");
  calls.clear(); fail_privacy = true;
  try { run(); CHECK(false); } catch (const std::runtime_error&) {}
  CHECK(calls == "OPC");
  calls.clear(); fail_privacy = false; allowed = true; fail_text = true;
  try { run(); CHECK(false); } catch (const std::runtime_error&) {}
  CHECK(calls == "OPTC");
  calls.clear(); fail_text = false; text_oom = true; run(); CHECK(calls == "OPTIC");
  calls.clear(); text_oom = false; run(); CHECK(calls == "OPTIC");
  calls.clear(); captured_text.clear(); fail_image = true; run();
  CHECK(calls == "OPTIC" && captured_text == "synthetic");

  // Exercise the actual marker policy together with snapshot sequencing.
  unsigned failed_format = 0;
  bool excluded = false, has_history = false, history_allowed = false;
  int payload_reads = 0, closes = 0, marker_reads = 0, marker_unlocks = 0;
  bool marker_lock_fails = false, malformed_marker = false;
  auto capture_with_markers = [&] {
    CaptureClipboardSnapshotWithPrivacy(
      [] { return true; }, [&]() noexcept { ++closes; },
        [&](const wchar_t* name) -> unsigned {
          unsigned format = std::wstring(name) == L"CanIncludeInClipboardHistory" ? 2 : 1;
          return format == failed_format ? 0 : format;
        },
        [&](unsigned format) { return format == 1 ? excluded : has_history; },
        [&](unsigned) {
          ++marker_reads;
          uint32_t value = malformed_marker ? 42 : (history_allowed ? 1 : 0);
          return ReadClipboardHistoryMarker(1,
              [](int) { return sizeof(uint32_t); },
              [&](int) -> const void* { return marker_lock_fails ? nullptr : &value; },
              [&](int) noexcept { ++marker_unlocks; });
        },
      [&] { ++payload_reads; }, [&] { ++payload_reads; });
  };
  excluded = true; has_history = true; history_allowed = true;
  capture_with_markers();
  CHECK(payload_reads == 0 && closes == 1 && marker_reads == 0);
  excluded = false; history_allowed = false; capture_with_markers();
  CHECK(payload_reads == 0 && closes == 2 && marker_reads == 1);
  history_allowed = true; failed_format = 1; capture_with_markers();
  CHECK(payload_reads == 0 && closes == 3 && marker_reads == 1);
  failed_format = 2; capture_with_markers();
  CHECK(payload_reads == 0 && closes == 4 && marker_reads == 1);
  failed_format = 0; capture_with_markers();
  CHECK(payload_reads == 2 && closes == 5 && marker_reads == 2);
  has_history = false; capture_with_markers();
  CHECK(payload_reads == 4 && closes == 6 && marker_reads == 2);
  CHECK(marker_unlocks == 2);
  has_history = true; marker_lock_fails = true; capture_with_markers();
  CHECK(payload_reads == 4 && closes == 7 && marker_reads == 3 && marker_unlocks == 2);
  marker_lock_fails = false; malformed_marker = true; capture_with_markers();
  CHECK(payload_reads == 4 && closes == 8 && marker_reads == 4 && marker_unlocks == 3);
  // An oversized synthetic text reports a notice while image processing continues;
  // a privacy refusal reaches neither callback.
  bool notice = false, image_captured = false;
  std::wstring oversized(kMaxClipboardTextUtf8Bytes + 1, L'x');
  auto capture_notice = [&](bool permit) {
    CaptureClipboardSnapshot(
        [] { return true; }, []() noexcept {}, [permit] { return permit; },
        [&] {
          bool too_large = false;
          auto value = DecodeClipboardText(oversized.c_str(), oversized.size() + 1, &too_large);
          if (too_large && !value) notice = true;
        },
        [&] { image_captured = true; });
  };
  capture_notice(false);
  CHECK(!notice && !image_captured);
  capture_notice(true);
  CHECK(notice && image_captured);
  return 0;
}
