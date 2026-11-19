#ifndef RUNNER_CAPTURE_DELIVERY_H_
#define RUNNER_CAPTURE_DELIVERY_H_

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

#include "ordered_capture_queue.h"

// All methods and acknowledgements run on the owning UI thread. The emitter
// must eventually acknowledge each accepted item; it may acknowledge inline.
// Logical byte/count limits include the item awaiting acknowledgement, but do
// not bound encoder internals, platform-channel copies, or allocator overhead.
template <typename T>
class CaptureDelivery : public std::enable_shared_from_this<CaptureDelivery<T>> {
 public:
  using Queue = OrderedCaptureQueue<T>;
  using Item = typename Queue::Item;
  using Ack = std::function<void(bool)>;
  using Emit = std::function<void(Item, Ack)>;
  using Stopped = std::function<void(bool)>;
  using Failed = std::function<void()>;

  static std::shared_ptr<CaptureDelivery> Create(size_t max_items,
                                                  size_t max_bytes, Emit emit,
                                                  Failed failed = {}) {
    return std::shared_ptr<CaptureDelivery>(
        new CaptureDelivery(max_items, max_bytes, std::move(emit), std::move(failed)));
  }

  bool accepting() const { return !stopping_ && !aborted_ && !queue_failed_; }

  std::optional<uint64_t> Reserve(size_t bytes) {
    if (!accepting()) return std::nullopt;
    if (queue_.size() + (in_flight_ ? 1 : 0) >= max_items_ ||
        bytes > max_bytes_ - in_flight_bytes_ ||
        queue_.bytes() > max_bytes_ - in_flight_bytes_ - bytes) {
      queue_.MarkOverflow();
      Pump();
      return std::nullopt;
    }
    return queue_.Reserve(bytes);
  }

  bool Complete(uint64_t id, T value, size_t bytes) {
    if (aborted_ || queue_failed_ || !queue_.Complete(id, std::move(value), bytes)) return false;
    Pump();
    return true;
  }

  // A producer failure may leave an unresolved or partially moved slot.
  // Keep any already delivered item in flight until its acknowledgement.
  void FailQueue() {
    auto keep_alive = this->shared_from_this();
    if (aborted_ || queue_failed_) return;
    queue_.Discard();
    queue_failed_ = true;
    delivery_failed_ = true;
    NotifyFailure();
    Pump();
  }

  // Discards undelivered slots and invalidates outstanding acknowledgements.
  // The in-flight item has an unknown outcome; this does not cancel Dart work.
  // The caller must fence late messages and drain admitted writes before restart.
  void Abort() {
    auto keep_alive = this->shared_from_this();
    if (aborted_) return;
    aborted_ = true;
    delivery_failed_ = true;
    in_flight_ = false;
    in_flight_bytes_ = 0;
    queue_.Discard();
    Finish(false);
  }

  // The stop callback runs after accepted slots and the overflow marker are
  // acknowledged. The caller must resolve every reserved slot, even on error,
  // and retain this object until done runs. Destruction cancels pending callbacks.
  bool Stop(Stopped done) {
    auto keep_alive = this->shared_from_this();
    if (stop_result_) {
      try {
        done(*stop_result_);
      } catch (...) {
        // The reply outcome is unknown; do not invoke it again.
      }
      return true;
    }
    stopped_.push_back(std::move(done));
    if (stopping_) return true;
    stopping_ = true;
    if (aborted_) {
      Finish(false);
    } else {
      Pump();
    }
    return true;
  }

 private:
  CaptureDelivery(size_t max_items, size_t max_bytes, Emit emit, Failed failed)
      : queue_(max_items, max_bytes), max_items_(max_items),
        max_bytes_(max_bytes), emit_(std::move(emit)), failed_(std::move(failed)) {}

  void NotifyFailure() {
    auto callback = std::move(failed_);
    try {
      if (callback) callback();
    } catch (...) {
      // Notification is best effort and must not prevent draining.
    }
  }

  void Finish(bool success) {
    if (stop_result_) return;
    stop_result_ = success;
    auto callbacks = std::move(stopped_);
    for (auto& callback : callbacks) {
      try {
        callback(success);
      } catch (...) {
        // One failed reply must not prevent other waiters from completing.
      }
    }
  }

  void Pump() {
    auto keep_alive = this->shared_from_this();
    if (pumping_) return;
    pumping_ = true;
    while (!aborted_ && !in_flight_) {
      std::optional<Item> item;
      try {
        item = queue_.Take();
      } catch (...) {
        // A failed move can leave a slot moved-from or already removed.
        // Discard it all and report failure rather than retrying unknown data.
        queue_.Discard();
        queue_failed_ = true;
        delivery_failed_ = true;
        pumping_ = false;
        NotifyFailure();
        if (stopping_) Finish(false);
        return;
      }
      if (!item) {
        if (stopping_ && queue_.size() == 0 && !stop_result_) {
          pumping_ = false;
          Finish(!delivery_failed_);
          return;
        }
        break;
      }
      in_flight_ = true;
      in_flight_bytes_ = item->bytes;
      const uint64_t token = ++token_;
      std::weak_ptr<CaptureDelivery> weak = keep_alive;
      try {
        emit_(std::move(*item), [weak, token](bool ok) {
          if (auto self = weak.lock()) self->Acknowledge(token, ok);
        });
      } catch (...) {
        Acknowledge(token, false);
      }
    }
    pumping_ = false;
  }

  void Acknowledge(uint64_t token, bool ok) {
    if (aborted_ || !in_flight_ || token != token_) return;
    delivery_failed_ |= !ok;
    in_flight_ = false;
    in_flight_bytes_ = 0;
    Pump();
  }

  Queue queue_;
  size_t max_items_;
  size_t max_bytes_;
  Emit emit_;
  Failed failed_;
  std::vector<Stopped> stopped_;
  std::optional<bool> stop_result_;
  size_t in_flight_bytes_ = 0;
  uint64_t token_ = 0;
  bool in_flight_ = false;
  bool pumping_ = false;
  bool stopping_ = false;
  bool delivery_failed_ = false;
  bool queue_failed_ = false;
  bool aborted_ = false;
};

#endif  // RUNNER_CAPTURE_DELIVERY_H_
