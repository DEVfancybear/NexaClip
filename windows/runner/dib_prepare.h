#ifndef RUNNER_DIB_PREPARE_H_
#define RUNNER_DIB_PREPARE_H_

#include <objbase.h>

#include <cstdint>
#include <optional>
#include <vector>

#include "dib_capture.h"
#include "wic_png_encoder.h"

// CF_DIB BI_RGB 24/32-bit only; the parser makes pixels opaque.
// The caller must enforce this bound before copying clipboard bytes.
inline constexpr size_t kMaxRgbDibBytes = 64000000 + sizeof(BITMAPINFOHEADER);
inline constexpr size_t kMaxClipboardDibBytes = 64000000 + sizeof(BITMAPV5HEADER);

inline std::optional<std::vector<uint8_t>> PrepareRgbClipboardDib(
    std::vector<uint8_t> bytes) {
  if (bytes.size() > kMaxRgbDibBytes) return std::nullopt;
  auto pixels = ParseRgbDib(bytes.data(), bytes.size());
  if (!pixels) return std::nullopt;
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return std::nullopt;
  struct ComGuard {
    ~ComGuard() { CoUninitialize(); }
  } guard;
  return EncodeBgraPng(pixels->width, pixels->height, pixels->bgra.data(),
                       pixels->bgra.size(), 10 * 1024 * 1024);
}

inline std::optional<std::vector<uint8_t>> PrepareClipboardDib(
    std::vector<uint8_t> bytes) {
  if (bytes.size() > kMaxClipboardDibBytes) return std::nullopt;
  auto pixels = ParseV5Dib(bytes.data(), bytes.size());
  if (!pixels) return PrepareRgbClipboardDib(std::move(bytes));
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return std::nullopt;
  struct ComGuard {
    ~ComGuard() { CoUninitialize(); }
  } guard;
  return EncodeBgraPng(pixels->width, pixels->height, pixels->bgra.data(),
                       pixels->bgra.size(), 10 * 1024 * 1024);
}

template <typename Prepare>
inline std::optional<std::vector<uint8_t>> PrepareDibCandidates(
    std::vector<std::vector<uint8_t>> candidates, Prepare prepare) {
  for (auto& candidate : candidates) {
    try {
      auto png = prepare(std::move(candidate));
      if (png) return png;
    } catch (const std::bad_alloc&) {
      // A later candidate can be smaller and still succeed.
    }
  }
  return std::nullopt;
}

inline std::optional<std::vector<uint8_t>> PrepareClipboardDibCandidates(
    std::vector<std::vector<uint8_t>> candidates) {
  return PrepareDibCandidates(std::move(candidates), PrepareClipboardDib);
}

#endif  // RUNNER_DIB_PREPARE_H_
