#ifndef RUNNER_ORDERED_CAPTURE_QUEUE_H_
#define RUNNER_ORDERED_CAPTURE_QUEUE_H_

#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <utility>

// UI-thread-only FIFO. Total-FIFO overflow coalesces until all earlier slots
// drain; new snapshots are rejected while its marker is pending. This differs
// from image-worker saturation, where the caller should reserve a small slot
// and preserve text fallback. Byte accounting is caller-supplied, not a heap cap.
// Every reserved slot must be completed (including error/cancel paths).
template <typename T>
class OrderedCaptureQueue {
 public:
  struct Item {
    bool overflow;
    std::optional<T> value;
    size_t bytes;
  };

  OrderedCaptureQueue(size_t max_items, size_t max_bytes)
      : max_items_(max_items), max_bytes_(max_bytes) {}

  std::optional<uint64_t> Reserve(size_t bytes) {
    if (overflow_ || slots_.size() >= max_items_ || bytes > max_bytes_ - bytes_) {
      overflow_ = true;
      return std::nullopt;
    }
    const uint64_t id = next_id_++;
    slots_.push_back(Slot{id, bytes, std::nullopt});
    bytes_ += bytes;
    return id;
  }

  void MarkOverflow() { overflow_ = true; }

  void Discard() {
    slots_.clear();
    bytes_ = 0;
    overflow_ = false;
  }

  bool Complete(uint64_t id, T value, size_t bytes) {
    for (auto& slot : slots_) {
      if (slot.id != id) continue;
      if (slot.value || bytes > slot.bytes) return false;
      slot.value.emplace(std::move(value));
      bytes_ -= slot.bytes - bytes;
      slot.bytes = bytes;
      return true;
    }
    return false;
  }

  std::optional<Item> Take() {
    if (!slots_.empty()) {
      auto& slot = slots_.front();
      if (!slot.value) return std::nullopt;
      Item result{false, std::move(slot.value), slot.bytes};
      bytes_ -= slot.bytes;
      slots_.pop_front();
      return result;
    }
    if (!overflow_) return std::nullopt;
    overflow_ = false;
    return Item{true, std::nullopt, 0};
  }

  size_t bytes() const { return bytes_; }
  size_t size() const { return slots_.size(); }

 private:
  struct Slot {
    uint64_t id;
    size_t bytes;
    std::optional<T> value;
  };
  const size_t max_items_;
  const size_t max_bytes_;
  std::deque<Slot> slots_;
  size_t bytes_ = 0;
  uint64_t next_id_ = 1;
  bool overflow_ = false;
};

#endif  // RUNNER_ORDERED_CAPTURE_QUEUE_H_
