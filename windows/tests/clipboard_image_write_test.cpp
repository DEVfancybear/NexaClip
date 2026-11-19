#include "../runner/clipboard_image_write.h"
#include <iostream>
#include <string>
#include <vector>
#define CHECK(x) do { if (!(x)) { std::cerr << "Failed at line " << __LINE__ << '\n'; return 1; } } while (false)

struct FakeApi {
  using Handle = int;
  int allocations = 0, fail_alloc = 0;
  bool open_ok = true, empty_ok = true, png_ok = true, dib_ok = true;
  std::vector<std::string> calls;
  Handle Allocate(const std::vector<uint8_t>&) {
    calls.push_back("allocate");
    ++allocations;
    return allocations == fail_alloc ? 0 : allocations;
  }
  void Free(Handle h) { calls.push_back("free" + std::to_string(h)); }
  bool Open() { calls.push_back("open"); return open_ok; }
  bool Empty() { calls.push_back("empty"); return empty_ok; }
  bool Set(unsigned format, Handle) {
    calls.push_back("set" + std::to_string(format));
    return format == 1 ? png_ok : dib_ok;
  }
  void Close() { calls.push_back("close"); }
};

int main() {
  const std::vector<uint8_t> bytes{1};
  FakeApi success;
  CHECK(WriteClipboardImage(success, 1, 2, bytes, bytes) == ImageWriteResult::kSuccess);
  CHECK((success.calls == std::vector<std::string>{"allocate", "allocate", "open", "empty", "set1", "set2", "close"}));
  FakeApi stale;
  CHECK(WriteClipboardImageChecked(stale, 1, 2, bytes, bytes, [&] {
    stale.calls.push_back("check"); return false;
  }) == ImageWriteResult::kClipboardChanged);
  CHECK((stale.calls == std::vector<std::string>{"allocate", "allocate", "open", "check", "close", "free2", "free1"}));
  FakeApi current;
  CHECK(WriteClipboardImageChecked(current, 1, 2, bytes, bytes, [&] {
    current.calls.push_back("check"); return true;
  }) == ImageWriteResult::kSuccess);
  CHECK((current.calls == std::vector<std::string>{"allocate", "allocate", "open", "check", "empty", "set1", "set2", "close"}));
  FakeApi alloc; alloc.fail_alloc = 2;
  CHECK(WriteClipboardImage(alloc, 1, 2, bytes, bytes) == ImageWriteResult::kPrepareFailed);
  CHECK((alloc.calls == std::vector<std::string>{"allocate", "allocate", "free1"}));
  FakeApi open; open.open_ok = false;
  CHECK(WriteClipboardImage(open, 1, 2, bytes, bytes) == ImageWriteResult::kOpenFailed);
  CHECK((open.calls == std::vector<std::string>{"allocate", "allocate", "open", "free2", "free1"}));
  FakeApi empty; empty.empty_ok = false;
  CHECK(WriteClipboardImage(empty, 1, 2, bytes, bytes) == ImageWriteResult::kEmptyFailed);
  CHECK((empty.calls == std::vector<std::string>{"allocate", "allocate", "open", "empty", "close", "free2", "free1"}));
  FakeApi partial; partial.png_ok = false;
  CHECK(WriteClipboardImage(partial, 1, 2, bytes, bytes) == ImageWriteResult::kPartialWrite);
  CHECK((partial.calls == std::vector<std::string>{"allocate", "allocate", "open", "empty", "set1", "set2", "close", "free1"}));
  FakeApi partial_dib; partial_dib.dib_ok = false;
  CHECK(WriteClipboardImage(partial_dib, 1, 2, bytes, bytes) == ImageWriteResult::kPartialWrite);
  CHECK((partial_dib.calls == std::vector<std::string>{"allocate", "allocate", "open", "empty", "set1", "set2", "close", "free2"}));
  FakeApi both; both.png_ok = false; both.dib_ok = false;
  CHECK(WriteClipboardImage(both, 1, 2, bytes, bytes) == ImageWriteResult::kWriteFailed);
  CHECK((both.calls == std::vector<std::string>{"allocate", "allocate", "open", "empty", "set1", "set2", "close", "free2", "free1"}));
  return 0;
}
