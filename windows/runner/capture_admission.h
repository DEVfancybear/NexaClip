#pragma once

#include "capture_delivery.h"
#include "capture_snapshot_prepare.h"

// start_dib may consume candidates, but must move map only on success.
template <typename EnsureWorker, typename StartDib>
void AdmitCapture(flutter::EncodableValue snapshot,
                  const std::shared_ptr<CaptureDelivery<flutter::EncodableValue>>& delivery,
                  bool dib_busy, EnsureWorker ensure_worker, StartDib start_dib) {
  auto* map = std::get_if<flutter::EncodableMap>(&snapshot);
  if (!map) return;
  auto prepared = PrepareCaptureSnapshot(*map);
  const size_t weight = prepared.weight;
  if (!prepared.dib.empty()) {
    if (!dib_busy && ensure_worker()) {
      const auto slot = delivery->Reserve(weight + prepared.dib_bytes + 10 * 1024 * 1024);
      if (!slot) return;
      if (start_dib(*slot, weight, *map, std::move(prepared.dib))) return;
      (*map)[flutter::EncodableValue(map->count(flutter::EncodableValue("png"))
                                         ? "fallbackUnavailable" : "pngRejected")] = flutter::EncodableValue(true);
      if (!delivery->Complete(*slot, std::move(snapshot), weight)) delivery->FailQueue();
      return;
    }
    (*map)[flutter::EncodableValue(map->count(flutter::EncodableValue("png"))
                                       ? "fallbackUnavailable" : "pngRejected")] = flutter::EncodableValue(true);
  }
  const auto slot = delivery->Reserve(weight);
  if (slot && !delivery->Complete(*slot, std::move(snapshot), weight)) delivery->FailQueue();
}
