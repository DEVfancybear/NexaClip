#include "../runner/clipboard_bytes.h"
#include "../runner/clipboard_image_attempt.h"
#include <cstdlib>
#include <iostream>
#include <new>
#include <stdexcept>

namespace { bool fail_next_allocation = false; }

void* operator new(std::size_t size) {
  if (fail_next_allocation) {
    fail_next_allocation = false;
    throw std::bad_alloc();
  }
  if (void* memory = std::malloc(size ? size : 1)) return memory;
  throw std::bad_alloc();
}
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete(void* memory, std::size_t) noexcept { std::free(memory); }

#define CHECK(x) do { if (!(x)) { std::cerr << "Failed at line " << __LINE__ << '\n'; return 1; } } while (false)

int main() {
  std::vector<uint8_t> source{1, 2, 3};
  size_t size = source.size();
  int locks = 0, unlocks = 0;
  bool fail_lock = false;
  auto size_of = [&](int) { return size; };
  auto lock = [&](int) -> const void* { ++locks; return fail_lock ? nullptr : source.data(); };
  auto unlock = [&](int) { ++unlocks; };
  auto copy = [&](int handle) { return CopyClipboardBytes(handle, 3, size_of, lock, unlock); };
  CHECK(!copy(0)); CHECK(locks == 0);
  size = 0; CHECK(!copy(1)); CHECK(locks == 0);
  size = 4; CHECK(!copy(1)); CHECK(locks == 0);
  size = 3; fail_lock = true; CHECK(!copy(1)); CHECK(locks == 1 && unlocks == 0);
  fail_lock = false; auto result = copy(1);
  CHECK(result && *result == source); CHECK(locks == 2 && unlocks == 1);
  source[0] = 9; CHECK((*result)[0] == 1);
  constexpr size_t image_limit = 10 * 1024 * 1024;
  source.assign(image_limit, 42);
  size = source.size();
  auto boundary = CopyClipboardBytes(1, image_limit, size_of, lock, unlock);
  CHECK(boundary && boundary->size() == image_limit);
  CHECK(boundary->front() == 42 && boundary->back() == 42);
  CHECK(locks == 3 && unlocks == 2);
  size = image_limit + 1;
  CHECK(!CopyClipboardBytes(1, image_limit, size_of, lock, unlock));
  CHECK(locks == 3 && unlocks == 2);
  size = 3;
  bool caught = false;
  fail_next_allocation = true;
  try {
    copy(1);
  } catch (const std::bad_alloc&) {
    caught = true;
  }
  fail_next_allocation = false;
  CHECK(caught);
  CHECK(locks == 4 && unlocks == 3);
  bool reached_text = false;
  fail_next_allocation = true;
  AttemptClipboardImage([&] { copy(1); });
  reached_text = true;
  CHECK(reached_text && !fail_next_allocation);
  CHECK(locks == 5 && unlocks == 4);
  bool completed = false;
  AttemptClipboardImage([&] { completed = true; });
  CHECK(completed);
  bool other_error = false;
  try {
    AttemptClipboardImage([] { throw std::runtime_error("test"); });
  } catch (const std::runtime_error&) {
    other_error = true;
  }
  CHECK(other_error);
  return 0;
}
