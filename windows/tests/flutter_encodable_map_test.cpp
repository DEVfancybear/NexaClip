#include "../runner/capture_snapshot_prepare.h"

#include <cstdlib>
#include <iostream>

#define CHECK(x) do { if (!(x)) { std::cerr << "CHECK failed: " #x << " at " << __LINE__ << '\n'; std::abort(); } } while (false)
#include <type_traits>
#include <utility>
#include <vector>

int main() {
  static_assert(std::is_nothrow_move_assignable_v<flutter::EncodableMap>);
  flutter::EncodableMap snapshot;
  snapshot.emplace(flutter::EncodableValue("png"),
                   flutter::EncodableValue(std::vector<uint8_t>{1, 2, 3}));
  auto copy = std::move(snapshot);
  const auto item = copy.find(flutter::EncodableValue("png"));
  CHECK(item != copy.end());
  CHECK(std::get<std::vector<uint8_t>>(item->second).size() == 3);
  copy.emplace(flutter::EncodableValue("text"), flutter::EncodableValue("hi"));
  copy.emplace(flutter::EncodableValue("_dib"), flutter::EncodableValue(std::vector<uint8_t>{4}));
  copy.emplace(flutter::EncodableValue("_dibV5"), flutter::EncodableValue(std::vector<uint8_t>{5, 6}));
  auto prepared = PrepareCaptureSnapshot(copy);
  CHECK(prepared.weight == 69 && prepared.dib_bytes == 3);
  CHECK(prepared.dib.size() == 2);
  CHECK(prepared.dib[0] == std::vector<uint8_t>({5, 6}));
  CHECK(prepared.dib[1] == std::vector<uint8_t>({4}));
  CHECK(copy.count(flutter::EncodableValue("_dibV5")) == 0);
  CHECK(copy.count(flutter::EncodableValue("_dib")) == 0);
  CHECK(copy.count(flutter::EncodableValue("png")) == 1);
}
