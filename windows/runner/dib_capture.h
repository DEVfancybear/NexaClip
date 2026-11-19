#pragma once

#include <windows.h>
#include <cstdint>
#include <cstring>
#include <optional>
#include <new>
#include <vector>

struct CapturedDib {
  uint32_t width;
  uint32_t height;
  std::vector<uint8_t> bgra;
};

// Accept BITMAPINFOHEADER BI_RGB 24/32-bit without a color table.
// BI_RGB's fourth byte has no defined alpha; output is always opaque.
inline std::optional<CapturedDib> ParseRgbDib(const uint8_t* data, size_t size) {
  if (!data || size < sizeof(BITMAPINFOHEADER)) return std::nullopt;
  BITMAPINFOHEADER h{};
  std::memcpy(&h, data, sizeof(h));
  if (h.biSize != sizeof(h) || h.biWidth <= 0 || h.biHeight == 0 ||
      h.biHeight == INT32_MIN || h.biPlanes != 1 || h.biCompression != BI_RGB ||
      (h.biBitCount != 24 && h.biBitCount != 32) || h.biClrUsed != 0)
    return std::nullopt;
  const uint32_t width = static_cast<uint32_t>(h.biWidth);
  const uint32_t height = static_cast<uint32_t>(h.biHeight < 0 ? -h.biHeight : h.biHeight);
  if (width > 8192 || height > 8192 || static_cast<uint64_t>(width) * height > 16000000)
    return std::nullopt;
  const uint64_t stride = ((static_cast<uint64_t>(width) * h.biBitCount + 31) / 32) * 4;
  const uint64_t extent = sizeof(h) + stride * height;
  if (extent > size) return std::nullopt;
  CapturedDib result{width, height, {}};
  try {
    result.bgra.resize(static_cast<size_t>(width) * height * 4);
  } catch (const std::bad_alloc&) {
    return std::nullopt;
  }
  for (uint32_t y = 0; y < height; ++y) {
    const auto source_y = h.biHeight < 0 ? y : height - 1 - y;
    const uint8_t* row = data + sizeof(h) + stride * source_y;
    for (uint32_t x = 0; x < width; ++x) {
      const auto source = row + x * (h.biBitCount / 8);
      auto target = result.bgra.data() + (static_cast<size_t>(y) * width + x) * 4;
      target[0] = source[0]; target[1] = source[1]; target[2] = source[2]; target[3] = 255;
    }
  }
  return result;
}

// Strict sRGB V5 subset with BGRA masks and no profile. Alpha bytes are
// preserved; the header does not identify whether they are premultiplied.
inline bool IsSupportedV5Dib(const uint8_t* data, size_t size) {
  if (!data || size < sizeof(BITMAPV5HEADER)) return false;
  BITMAPV5HEADER h{};
  std::memcpy(&h, data, sizeof(h));
  if (h.bV5Size != sizeof(h) || h.bV5Width <= 0 || h.bV5Height == 0 ||
      h.bV5Height == INT32_MIN || h.bV5Planes != 1 || h.bV5BitCount != 32 ||
      h.bV5Compression != BI_BITFIELDS || h.bV5ClrUsed != 0 ||
      h.bV5RedMask != 0x00ff0000 || h.bV5GreenMask != 0x0000ff00 ||
      h.bV5BlueMask != 0x000000ff || h.bV5AlphaMask != 0xff000000 ||
      h.bV5CSType != LCS_sRGB || h.bV5ProfileData != 0 || h.bV5ProfileSize != 0)
    return false;
  const uint32_t width = static_cast<uint32_t>(h.bV5Width);
  const uint32_t height = static_cast<uint32_t>(h.bV5Height < 0 ? -h.bV5Height : h.bV5Height);
  const uint64_t count = static_cast<uint64_t>(width) * height;
  return width <= 8192 && height <= 8192 && count <= 16000000 &&
         sizeof(h) + count * 4 <= size;
}

inline std::optional<CapturedDib> ParseV5Dib(const uint8_t* data, size_t size) {
  if (!IsSupportedV5Dib(data, size)) return std::nullopt;
  BITMAPV5HEADER h{};
  std::memcpy(&h, data, sizeof(h));
  const uint32_t width = static_cast<uint32_t>(h.bV5Width);
  const uint32_t height = static_cast<uint32_t>(h.bV5Height < 0 ? -h.bV5Height : h.bV5Height);
  const uint64_t count = static_cast<uint64_t>(width) * height;
  CapturedDib result{width, height, {}};
  try {
    result.bgra.resize(static_cast<size_t>(count) * 4);
  } catch (const std::bad_alloc&) {
    return std::nullopt;
  }
  const size_t stride = static_cast<size_t>(width) * 4;
  for (uint32_t y = 0; y < height; ++y) {
    const auto source_y = h.bV5Height < 0 ? y : height - 1 - y;
    std::memcpy(result.bgra.data() + y * stride,
                data + sizeof(h) + source_y * stride, stride);
  }
  return result;
}
