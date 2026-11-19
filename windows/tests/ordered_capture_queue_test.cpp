#include "../runner/ordered_capture_queue.h"

#include <cstdlib>
#include <iostream>
#include <string>

#define CHECK(x) do { if (!(x)) { std::cerr << "CHECK failed: " #x << " at " << __LINE__ << '\n'; std::abort(); } } while (false)

int main() {
  OrderedCaptureQueue<std::string> queue(3, 20);
  auto image = queue.Reserve(10);
  auto text = queue.Reserve(4);
  auto png = queue.Reserve(6);
  CHECK(image && text && png && queue.bytes() == 20);
  CHECK(queue.Complete(*text, "text", 4));
  CHECK(queue.Complete(*png, "png", 3));
  CHECK(!queue.Take());
  CHECK(!queue.Reserve(1));
  CHECK(!queue.Reserve(1));
  CHECK(!queue.Complete(*image, "oversize", 11));
  CHECK(queue.Complete(*image, "image", 5));
  CHECK(!queue.Complete(*image, "again", 1));
  CHECK(queue.Take()->value == "image");
  CHECK(queue.Take()->value == "text");
  CHECK(queue.Take()->value == "png");
  CHECK(!queue.Reserve(1));  // Marker is still ahead of new snapshots.
  auto overflow = queue.Take();
  CHECK(overflow && overflow->overflow && !overflow->value);
  CHECK(!queue.Take() && queue.bytes() == 0 && queue.size() == 0);
  auto next = queue.Reserve(20);
  CHECK(next && queue.Complete(*next, "next", 4));
  CHECK(queue.Take()->value == "next");
  CHECK(!queue.Complete(*next, "old", 1));
  auto failed = queue.Reserve(4);
  auto following = queue.Reserve(4);
  CHECK(failed && following);
  CHECK(queue.Complete(*following, "late", 4));
  CHECK(!queue.Take());
  CHECK(queue.Complete(*failed, "err", 3));
  CHECK(queue.Take()->value == "err");
  CHECK(queue.Take()->value == "late");
  CHECK(!queue.Reserve(21));
  CHECK(queue.Take()->overflow);
  CHECK(queue.bytes() == 0);

  auto discarded = queue.Reserve(10);
  auto ready = queue.Reserve(10);
  CHECK(discarded && ready);
  CHECK(queue.Complete(*ready, "ready", 5));
  CHECK(!queue.Reserve(6));
  queue.Discard();
  CHECK(queue.size() == 0 && queue.bytes() == 0 && !queue.Take());
  CHECK(!queue.Complete(*discarded, "stale", 1));
  auto fresh = queue.Reserve(20);
  CHECK(fresh && *fresh != *discarded);
  CHECK(queue.Complete(*fresh, "fresh", 5));
  CHECK(queue.Take()->value == "fresh");
}
