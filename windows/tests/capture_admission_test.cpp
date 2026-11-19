#include "../runner/capture_admission.h"
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <vector>
#define CHECK(x) do { if (!(x)) { std::cerr << "CHECK failed: " #x << " at " << __LINE__ << '\n'; std::abort(); } } while (false)
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Delivery = CaptureDelivery<Value>;

int main() {
  std::vector<Map> emitted;
  std::vector<Delivery::Ack> acks;
  auto delivery = Delivery::Create(4, 32 * 1024 * 1024, [&](Delivery::Item item, Delivery::Ack ack) {
    CHECK(!item.overflow);
    emitted.push_back(std::get<Map>(*item.value));
    acks.push_back(std::move(ack));
  });
  Map first{{Value("png"), Value(std::vector<uint8_t>{1})},
            {Value("_dibV5"), Value(std::vector<uint8_t>{2})},
            {Value("_dib"), Value(std::vector<uint8_t>{3})}};
  uint64_t pending = 0;
  size_t pending_weight = 0;
  Map pending_map;
  AdmitCapture(Value(std::move(first)), delivery, false, [] { return true; },
      [&](uint64_t slot, size_t weight, Map& map, std::vector<std::vector<uint8_t>> dib) {
        CHECK(dib.size() == 2 && dib[0][0] == 2 && dib[1][0] == 3);
        pending = slot; pending_weight = weight; pending_map = std::move(map); return true;
      });
  Map second{{Value("png"), Value(std::vector<uint8_t>{4})},
             {Value("_dib"), Value(std::vector<uint8_t>{5})}};
  AdmitCapture(Value(std::move(second)), delivery, true, [] { std::abort(); return true; },
      [](uint64_t, size_t, Map&, std::vector<std::vector<uint8_t>>) { std::abort(); return false; });
  CHECK(emitted.empty());
  bool stopped = false;
  delivery->Stop([&](bool ok) { CHECK(ok); stopped = true; });
  pending_map[Value("fallbackPng")] = Value(std::vector<uint8_t>{6});
  CHECK(delivery->Complete(pending, Value(std::move(pending_map)), pending_weight + 1));
  CHECK(emitted.size() == 1 && !stopped);
  acks[0](true);
  CHECK(emitted.size() == 2 && emitted[1].count(Value("fallbackUnavailable")) == 1);
  acks[1](true);
  CHECK(stopped);

  std::vector<Map> failures;
  auto failed_start = Delivery::Create(4, 32 * 1024 * 1024, [&](Delivery::Item item, Delivery::Ack ack) {
    CHECK(!item.overflow);
    failures.push_back(std::get<Map>(*item.value));
    ack(true);
  });
  int starts = 0;
  auto reject = [&](uint64_t, size_t, Map&, std::vector<std::vector<uint8_t>>) {
    ++starts; return false;
  };
  Map with_png{{Value("png"), Value(std::vector<uint8_t>{1})},
               {Value("_dib"), Value(std::vector<uint8_t>{2})}};
  AdmitCapture(Value(std::move(with_png)), failed_start, false, [] { return true; }, reject);
  Map no_png{{Value("_dib"), Value(std::vector<uint8_t>{3})}};
  AdmitCapture(Value(std::move(no_png)), failed_start, false, [] { return true; }, reject);
  CHECK(starts == 2 && failures.size() == 2);
  CHECK(failures[0].count(Value("fallbackUnavailable")) == 1);
  CHECK(failures[0].count(Value("pngRejected")) == 0);
  CHECK(failures[1].count(Value("pngRejected")) == 1);
  CHECK(failures[1].count(Value("_dib")) == 0);
  Map unavailable{{Value("_dib"), Value(std::vector<uint8_t>{7})}};
  AdmitCapture(Value(std::move(unavailable)), failed_start, false, [] { return false; },
      [](uint64_t, size_t, Map&, std::vector<std::vector<uint8_t>>) { std::abort(); return false; });
  CHECK(failures.size() == 3 && failures[2].count(Value("pngRejected")) == 1);
  bool threw = false;
  try {
    Map throwing{{Value("_dib"), Value(std::vector<uint8_t>{8})}};
    AdmitCapture(Value(std::move(throwing)), failed_start, false,
        []() -> bool { throw std::runtime_error("synthetic worker failure"); },
        [](uint64_t, size_t, Map&, std::vector<std::vector<uint8_t>>) { std::abort(); return false; });
  } catch (const std::runtime_error&) { threw = true; }
  CHECK(threw && failures.size() == 3);

  bool overflow = false;
  auto bounded = Delivery::Create(4, 10 * 1024 * 1024, [&](Delivery::Item item, Delivery::Ack ack) {
    CHECK(item.overflow); overflow = true; ack(true);
  });
  Map too_large{{Value("_dib"), Value(std::vector<uint8_t>{1})}};
  AdmitCapture(Value(std::move(too_large)), bounded, false, [] { return true; },
      [](uint64_t, size_t, Map&, std::vector<std::vector<uint8_t>>) { std::abort(); return false; });
  CHECK(overflow);
}
