#ifndef RUNNER_IMAGE_PREPARE_H_
#define RUNNER_IMAGE_PREPARE_H_

#include <objbase.h>

#include <cstdint>
#include <optional>
#include <vector>

#include "dib_v5.h"
#include "wic_png_encoder.h"

struct ImageCopyJob {
  int width;
  int height;
  std::vector<uint8_t> bgra;
};

struct PreparedClipboardImage {
  std::vector<uint8_t> dib;
  std::vector<uint8_t> png;
};

// Called on a worker thread; COM is initialized and released on that thread.
inline std::optional<PreparedClipboardImage> PrepareClipboardImage(ImageCopyJob job) {
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return std::nullopt;
  struct ComGuard {
    ~ComGuard() { CoUninitialize(); }
  } guard;
  auto dib = MakeDibV5(job.width, job.height, job.bgra.data(), job.bgra.size());
  if (!dib) return std::nullopt;
  auto png = EncodeBgraPng(job.width, job.height, job.bgra.data(), job.bgra.size(),
                           10 * 1024 * 1024);
  if (!png) return std::nullopt;
  return PreparedClipboardImage{std::move(*dib), std::move(*png)};
}

#endif  // RUNNER_IMAGE_PREPARE_H_
