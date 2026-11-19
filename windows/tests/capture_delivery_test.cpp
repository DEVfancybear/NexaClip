#include "../runner/capture_delivery.h"

#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#define CHECK(x) do { if (!(x)) { std::cerr << "CHECK failed: " #x << " at " << __LINE__ << '\n'; std::abort(); } } while (false)
using Delivery = CaptureDelivery<std::string>;

struct ThrowingPayload {
  inline static bool fail_move = false;
  inline static int moves_until_failure = 0;
  explicit ThrowingPayload(int value) : value(value) {}
  ThrowingPayload(ThrowingPayload&& other) {
    if (fail_move || (moves_until_failure > 0 && --moves_until_failure == 0))
      throw std::runtime_error("synthetic move failure");
    value = other.value;
  }
  ThrowingPayload& operator=(ThrowingPayload&& other) {
    if (fail_move) throw std::runtime_error("synthetic move failure");
    value = other.value;
    return *this;
  }
  int value;
};

int main() {
  std::vector<std::string> emitted;
  std::vector<Delivery::Ack> acknowledgements;
  auto delivery = Delivery::Create(3, 20, [&](Delivery::Item item, Delivery::Ack ack) {
    emitted.push_back(item.overflow ? "overflow" : *item.value);
    acknowledgements.push_back(std::move(ack));
  });
  auto image = delivery->Reserve(10);
  auto text = delivery->Reserve(4);
  CHECK(image && text);
  CHECK(delivery->Complete(*text, "text", 4));
  CHECK(emitted.empty());
  bool stopped = false;
  bool succeeded = false;
  CHECK(delivery->Stop([&](bool ok) { stopped = true; succeeded = ok; }));
  CHECK(!delivery->Reserve(1));
  int second_stop_calls = 0;
  CHECK(delivery->Stop([&](bool ok) { CHECK(ok); ++second_stop_calls; }));
  CHECK(second_stop_calls == 0);
  CHECK(delivery->Complete(*image, "image", 5));
  CHECK(emitted == std::vector<std::string>({"image"}));
  CHECK(!stopped);
  auto first_ack = acknowledgements[0];
  first_ack(true);
  CHECK(emitted == std::vector<std::string>({"image", "text"}));
  first_ack(true);  // A stale acknowledgement cannot release the next item.
  CHECK(!stopped);
  acknowledgements[1](true);
  CHECK(stopped && succeeded);
  CHECK(second_stop_calls == 1);
  int late_stop_calls = 0;
  CHECK(delivery->Stop([&](bool ok) { CHECK(ok); ++late_stop_calls; }));
  CHECK(late_stop_calls == 1);

  emitted.clear(); acknowledgements.clear();
  auto bounded = Delivery::Create(2, 10, [&](Delivery::Item item, Delivery::Ack ack) {
    emitted.push_back(item.overflow ? "overflow" : *item.value);
    acknowledgements.push_back(std::move(ack));
  });
  auto first = bounded->Reserve(6);
  CHECK(first && bounded->Complete(*first, "one", 6));
  auto second = bounded->Reserve(4);
  CHECK(second && bounded->Complete(*second, "two", 4));
  CHECK(!bounded->Reserve(1));
  bool finished = false;
  CHECK(bounded->Stop([&](bool ok) { finished = ok; }));
  auto ack_one = acknowledgements[0];
  ack_one(true);
  CHECK(emitted == std::vector<std::string>({"one", "two"}));
  auto ack_two = acknowledgements[1];
  ack_two(true);
  CHECK(emitted == std::vector<std::string>({"one", "two", "overflow"}));
  CHECK(!finished);
  auto ack_overflow = acknowledgements[2];
  ack_overflow(true);
  CHECK(finished);

  Delivery::Ack shared_ack;
  auto shared = Delivery::Create(1, 1, [&](Delivery::Item, Delivery::Ack ack) {
    shared_ack = std::move(ack);
  });
  auto shared_item = shared->Reserve(1);
  CHECK(shared_item && shared->Complete(*shared_item, "x", 1));
  int shared_replies = 0;
  CHECK(shared->Stop([&](bool ok) {
    CHECK(!ok);
    ++shared_replies;
    CHECK(shared->Stop([&](bool nested_ok) { CHECK(!nested_ok); ++shared_replies; }));
    throw std::runtime_error("synthetic reply failure");
  }));
  CHECK(shared->Stop([&](bool ok) { CHECK(!ok); ++shared_replies; }));
  CHECK(shared_replies == 0);
  shared_ack(false);
  CHECK(shared_replies == 3);
  shared_ack(true);
  CHECK(shared_replies == 3);

  using ThrowingDelivery = CaptureDelivery<ThrowingPayload>;
  ThrowingDelivery::Ack move_ack;
  int move_failures = 0;
  auto throwing = ThrowingDelivery::Create(2, 2,
      [&](ThrowingDelivery::Item, ThrowingDelivery::Ack ack) {
        move_ack = std::move(ack);
      }, [&] { ++move_failures; });
  auto move_first = throwing->Reserve(1);
  CHECK(move_first && throwing->Complete(*move_first, ThrowingPayload(1), 1));
  auto move_second = throwing->Reserve(1);
  CHECK(move_second && throwing->Complete(*move_second, ThrowingPayload(2), 1));
  int move_stop_calls = 0;
  CHECK(throwing->Stop([&](bool ok) { CHECK(!ok); ++move_stop_calls; }));
  ThrowingPayload::fail_move = true;
  move_ack(true);
  ThrowingPayload::fail_move = false;
  CHECK(move_stop_calls == 1);
  CHECK(move_failures == 1);
  throwing->FailQueue();
  CHECK(move_failures == 1);
  CHECK(!throwing->Reserve(1));
  CHECK(throwing->Stop([&](bool ok) { CHECK(!ok); ++move_stop_calls; }));
  CHECK(move_stop_calls == 2);

  ThrowingDelivery::Ack early_ack;
  auto early_failure = ThrowingDelivery::Create(3, 3,
      [&](ThrowingDelivery::Item, ThrowingDelivery::Ack ack) {
        early_ack = std::move(ack);
      });
  auto early_first = early_failure->Reserve(1);
  CHECK(early_first && early_failure->Complete(*early_first, ThrowingPayload(1), 1));
  auto early_second = early_failure->Reserve(1);
  CHECK(early_second && early_failure->Complete(*early_second, ThrowingPayload(2), 1));
  auto early_unresolved = early_failure->Reserve(1);
  CHECK(early_unresolved);
  ThrowingPayload::fail_move = true;
  early_ack(true);
  ThrowingPayload::fail_move = false;
  CHECK(!early_failure->accepting());
  CHECK(!early_failure->Complete(*early_unresolved, ThrowingPayload(3), 1));
  early_ack(true);
  CHECK(!early_failure->Reserve(1));
  bool early_stopped = false;
  CHECK(early_failure->Stop([&](bool ok) { CHECK(!ok); early_stopped = true; }));
  CHECK(early_stopped);

  ThrowingDelivery::Ack producer_ack;
  int producer_emitted = 0;
  auto producer_failure = ThrowingDelivery::Create(3, 3,
      [&](ThrowingDelivery::Item, ThrowingDelivery::Ack ack) {
        ++producer_emitted;
        producer_ack = std::move(ack);
      });
  auto producer_first = producer_failure->Reserve(1);
  CHECK(producer_first && producer_failure->Complete(*producer_first, ThrowingPayload(1), 1));
  auto producer_pending = producer_failure->Reserve(1);
  CHECK(producer_pending);
  ThrowingPayload pending_value(2);
  ThrowingPayload::fail_move = true;
  try {
    producer_failure->Complete(*producer_pending, std::move(pending_value), 1);
    CHECK(false);
  } catch (...) {
    producer_failure->FailQueue();
  }
  ThrowingPayload::fail_move = false;
  CHECK(!producer_failure->accepting());
  int producer_stops = 0;
  CHECK(producer_failure->Stop([&](bool ok) { CHECK(!ok); ++producer_stops; }));
  CHECK(producer_stops == 0);
  producer_ack(true);
  CHECK(producer_stops == 1 && producer_emitted == 1);
  producer_ack(true);
  CHECK(producer_stops == 1);
  CHECK(!producer_failure->Complete(*producer_pending, ThrowingPayload(2), 1));

  // A new capture session must not inherit a failed queue or stale acknowledgements.
  int restarted_emitted = 0;
  ThrowingDelivery::Ack restarted_ack;
  auto restarted = ThrowingDelivery::Create(2, 2,
      [&](ThrowingDelivery::Item item, ThrowingDelivery::Ack ack) {
        CHECK(item.value && item.value->value == 3);
        ++restarted_emitted;
        restarted_ack = std::move(ack);
      });
  auto restarted_slot = restarted->Reserve(1);
  CHECK(restarted_slot && restarted->Complete(*restarted_slot, ThrowingPayload(3), 1));
  CHECK(restarted_emitted == 1);
  bool restarted_stopped = false;
  CHECK(restarted->Stop([&](bool ok) { CHECK(ok); restarted_stopped = true; }));
  producer_ack(false);
  CHECK(!restarted_stopped);
  restarted_ack(true);
  CHECK(restarted_stopped);

  ThrowingDelivery::Ack emplace_ack;
  auto emplace_failure = ThrowingDelivery::Create(2, 2,
      [&](ThrowingDelivery::Item, ThrowingDelivery::Ack ack) {
        emplace_ack = std::move(ack);
      });
  auto emplace_first = emplace_failure->Reserve(1);
  CHECK(emplace_first && emplace_failure->Complete(*emplace_first, ThrowingPayload(1), 1));
  auto emplace_pending = emplace_failure->Reserve(1);
  CHECK(emplace_pending);
  ThrowingPayload emplace_value(2);
  ThrowingPayload::moves_until_failure = 3;
  try {
    emplace_failure->Complete(*emplace_pending, std::move(emplace_value), 1);
    CHECK(false);
  } catch (...) {
    CHECK(ThrowingPayload::moves_until_failure == 0);
    emplace_failure->FailQueue();
  }
  bool emplace_stopped = false;
  CHECK(emplace_failure->Stop([&](bool ok) { CHECK(!ok); emplace_stopped = true; }));
  CHECK(!emplace_stopped);
  emplace_ack(true);
  CHECK(emplace_stopped);

  Delivery::Ack failure_notice_ack;
  int failure_notices = 0;
  std::shared_ptr<Delivery> failure_notice;
  failure_notice = Delivery::Create(2, 2,
      [&](Delivery::Item, Delivery::Ack ack) { failure_notice_ack = std::move(ack); },
      [&] {
        ++failure_notices;
        CHECK(!failure_notice->accepting());
        failure_notice->FailQueue();
        throw std::runtime_error("synthetic notification failure");
      });
  auto notice_item = failure_notice->Reserve(1);
  CHECK(notice_item && failure_notice->Complete(*notice_item, "a", 1));
  failure_notice->FailQueue();
  CHECK(failure_notices == 1);
  bool notice_stopped = false;
  CHECK(failure_notice->Stop([&](bool ok) { CHECK(!ok); notice_stopped = true; }));
  CHECK(!notice_stopped);
  failure_notice_ack(true);
  CHECK(notice_stopped && failure_notices == 1);

  Delivery::Ack reentrant_failure_ack;
  std::shared_ptr<Delivery> reentrant_failure;
  std::weak_ptr<Delivery> weak_failure;
  int reentrant_failure_stops = 0;
  reentrant_failure = Delivery::Create(1, 1,
      [&](Delivery::Item, Delivery::Ack ack) { reentrant_failure_ack = std::move(ack); },
      [&] {
        CHECK(reentrant_failure->Stop([&](bool ok) {
          CHECK(!ok);
          ++reentrant_failure_stops;
        }));
        CHECK(reentrant_failure_stops == 0);
        reentrant_failure->Abort();
        CHECK(reentrant_failure_stops == 1);
        reentrant_failure.reset();
        CHECK(!weak_failure.expired());
      });
  weak_failure = reentrant_failure;
  auto reentrant_item = reentrant_failure->Reserve(1);
  CHECK(reentrant_item && reentrant_failure->Complete(*reentrant_item, "a", 1));
  reentrant_failure->FailQueue();
  CHECK(weak_failure.expired());
  reentrant_failure_ack(true);
  CHECK(reentrant_failure_stops == 1);

  ThrowingDelivery::Ack take_reentrant_ack;
  std::shared_ptr<ThrowingDelivery> take_reentrant;
  std::weak_ptr<ThrowingDelivery> take_reentrant_weak;
  int take_reentrant_stops = 0;
  take_reentrant = ThrowingDelivery::Create(2, 2,
      [&](ThrowingDelivery::Item, ThrowingDelivery::Ack ack) {
        take_reentrant_ack = std::move(ack);
      }, [&] {
        CHECK(!take_reentrant->accepting());
        CHECK(take_reentrant->Stop([&](bool ok) {
          CHECK(!ok);
          ++take_reentrant_stops;
        }));
        take_reentrant->Abort();
        take_reentrant.reset();
        CHECK(!take_reentrant_weak.expired());
      });
  take_reentrant_weak = take_reentrant;
  auto take_first = take_reentrant->Reserve(1);
  CHECK(take_first && take_reentrant->Complete(*take_first, ThrowingPayload(1), 1));
  auto take_second = take_reentrant->Reserve(1);
  CHECK(take_second && take_reentrant->Complete(*take_second, ThrowingPayload(2), 1));
  ThrowingPayload::fail_move = true;
  take_reentrant_ack(true);
  ThrowingPayload::fail_move = false;
  CHECK(take_reentrant_stops == 1);
  CHECK(take_reentrant_weak.expired());
  take_reentrant_ack(true);
  CHECK(take_reentrant_stops == 1);

  Delivery::Ack pending_stop_ack;
  auto failure_during_stop = Delivery::Create(2, 2,
      [&](Delivery::Item, Delivery::Ack ack) { pending_stop_ack = std::move(ack); });
  auto pending_stop_first = failure_during_stop->Reserve(1);
  CHECK(pending_stop_first && failure_during_stop->Complete(*pending_stop_first, "x", 1));
  auto pending_stop_slot = failure_during_stop->Reserve(1);
  CHECK(pending_stop_slot);
  int pending_stop_replies = 0;
  CHECK(failure_during_stop->Stop([&](bool ok) { CHECK(!ok); ++pending_stop_replies; }));
  failure_during_stop->FailQueue();
  failure_during_stop->FailQueue();
  CHECK(pending_stop_replies == 0);
  pending_stop_ack(true);
  CHECK(pending_stop_replies == 1);
  CHECK(!failure_during_stop->Complete(*pending_stop_slot, "y", 1));

  bool error_reported = false;
  auto failing = Delivery::Create(1, 10, [](Delivery::Item, Delivery::Ack) {
    throw std::runtime_error("synthetic transport failure");
  });
  auto item = failing->Reserve(1);
  CHECK(item && failing->Complete(*item, "x", 1));
  CHECK(failing->Stop([&](bool ok) { error_reported = !ok; }));
  CHECK(error_reported);

  std::shared_ptr<Delivery> reentrant;
  int emitted_inline = 0;
  reentrant = Delivery::Create(2, 4, [&](Delivery::Item item, Delivery::Ack ack) {
    CHECK(!item.overflow);
    if (++emitted_inline < 10000) {
      auto next = reentrant->Reserve(1);
      CHECK(next && reentrant->Complete(*next, "x", 1));
    }
    ack(true);
  });
  auto initial = reentrant->Reserve(1);
  CHECK(initial && reentrant->Complete(*initial, "x", 1));
  CHECK(emitted_inline == 10000);
  bool inline_stopped = false;
  CHECK(reentrant->Stop([&](bool ok) { inline_stopped = ok; }));
  CHECK(inline_stopped);

  bool stopped_inline = false;
  std::shared_ptr<Delivery> stopping_inline;
  stopping_inline = Delivery::Create(2, 4, [&](Delivery::Item, Delivery::Ack ack) {
    CHECK(stopping_inline->Stop([&](bool ok) { stopped_inline = ok; }));
    CHECK(!stopped_inline);
    ack(true);
  });
  auto stop_item = stopping_inline->Reserve(1);
  CHECK(stop_item && stopping_inline->Complete(*stop_item, "x", 1));
  CHECK(stopped_inline);

  std::vector<Delivery::Ack> marker_acks;
  std::vector<bool> marker_items;
  auto marker = Delivery::Create(1, 1, [&](Delivery::Item item, Delivery::Ack ack) {
    marker_items.push_back(item.overflow);
    marker_acks.push_back(std::move(ack));
  });
  auto full = marker->Reserve(1);
  CHECK(full && marker->Complete(*full, "x", 1));
  CHECK(!marker->Reserve(1));
  auto value_ack = marker_acks[0];
  value_ack(true);
  CHECK(marker_items == std::vector<bool>({false, true}));
  CHECK(!marker->Reserve(1));
  auto marker_ack = marker_acks[1];
  marker_ack(true);
  CHECK(marker_items == std::vector<bool>({false, true, true}));
  auto second_marker_ack = marker_acks[2];
  second_marker_ack(true);
  auto resumed = marker->Reserve(1);
  CHECK(resumed && marker->Complete(*resumed, "y", 1));
  auto resumed_ack = marker_acks[3];
  resumed_ack(true);

  bool ack_failed = false;
  auto negative = Delivery::Create(1, 4, [](Delivery::Item, Delivery::Ack ack) { ack(false); });
  auto one = negative->Reserve(1);
  CHECK(one && negative->Complete(*one, "x", 1));
  CHECK(negative->Stop([&](bool ok) { ack_failed = !ok; }));
  CHECK(ack_failed);

  std::vector<std::string> aborted_emitted;
  Delivery::Ack withheld;
  auto aborted = Delivery::Create(2, 10, [&](Delivery::Item item, Delivery::Ack ack) {
    aborted_emitted.push_back(*item.value);
    withheld = std::move(ack);
  });
  auto a = aborted->Reserve(2);
  CHECK(a && aborted->Complete(*a, "a", 1));
  auto b = aborted->Reserve(2);
  CHECK(b && aborted->Complete(*b, "b", 1));
  int abort_replies = 0;
  CHECK(aborted->Stop([&](bool ok) { CHECK(!ok); ++abort_replies; }));
  CHECK(aborted->Stop([&](bool ok) { CHECK(!ok); ++abort_replies; }));
  CHECK(abort_replies == 0);
  aborted->Abort();
  aborted->Abort();
  withheld(true);
  CHECK(abort_replies == 2);
  CHECK(aborted_emitted == std::vector<std::string>({"a"}));
  CHECK(!aborted->Reserve(1));
  CHECK(!aborted->Complete(*b, "b", 1));

  std::shared_ptr<Delivery> reentrant_abort;
  int reentrant_replies = 0;
  reentrant_abort = Delivery::Create(2, 4, [&](Delivery::Item, Delivery::Ack ack) {
    auto pending = reentrant_abort->Reserve(1);
    CHECK(pending && reentrant_abort->Complete(*pending, "later", 1));
    CHECK(reentrant_abort->Stop([&](bool ok) { CHECK(!ok); ++reentrant_replies; }));
    reentrant_abort->Abort();
    ack(true);
  });
  auto reentrant_first = reentrant_abort->Reserve(1);
  CHECK(reentrant_first && reentrant_abort->Complete(*reentrant_first, "first", 1));
  CHECK(reentrant_replies == 1);

  Delivery::Ack abandoned_ack;
  auto before_stop = Delivery::Create(2, 2, [&](Delivery::Item, Delivery::Ack ack) {
    abandoned_ack = std::move(ack);
  });
  auto outstanding = before_stop->Reserve(1);
  CHECK(outstanding && before_stop->Complete(*outstanding, "x", 1));
  auto unresolved = before_stop->Reserve(1);
  CHECK(unresolved);
  CHECK(!before_stop->Reserve(1));  // Overflow behind the unresolved slot.
  before_stop->Abort();
  CHECK(!before_stop->Complete(*unresolved, "x", 1));
  bool aborted_stop = false;
  CHECK(before_stop->Stop([&](bool ok) { aborted_stop = !ok; }));
  abandoned_ack(true);
  CHECK(aborted_stop);

  auto releasing = Delivery::Create(1, 1, [](Delivery::Item, Delivery::Ack) {});
  releasing->Abort();
  std::weak_ptr<Delivery> weak_releasing = releasing;
  CHECK(releasing->Stop([&](bool ok) {
    CHECK(!ok);
    releasing.reset();
    CHECK(!weak_releasing.expired());
  }));
  CHECK(weak_releasing.expired());

  Delivery::Ack late;
  {
    auto temporary = Delivery::Create(1, 10, [&](Delivery::Item, Delivery::Ack ack) { late = std::move(ack); });
    auto pending = temporary->Reserve(1);
    CHECK(pending && temporary->Complete(*pending, "x", 1));
  }
  late(true);  // A late channel callback cannot access destroyed state.
  return 0;
}
