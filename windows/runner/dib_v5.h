#ifndef RUNNER_DIB_V5_H_
#define RUNNER_DIB_V5_H_

#include <windows.h>
#include <cstdint>
#include <cstring>
#include <optional>
#include <vector>

// Pixels are straight-alpha BGRA, top row first. The returned bytes are a
// packed CF_DIBV5, not a BMP file (there is no BITMAPFILEHEADER).
inline std::optional<std::vector<uint8_t>> MakeDibV5(
    uint32_t width, uint32_t height, const uint8_t* pixels, size_t size) {
  constexpr uint32_t kMaxDimension = 8192;
  constexpr uint64_t kMaxPixels = 16000000;
  const uint64_t count = static_cast<uint64_t>(width) * height;
  if (!width || !height || width > kMaxDimension || height > kMaxDimension ||
      count > kMaxPixels || !pixels || size != count * 4) {
    return std::nullopt;
  }
  BITMAPV5HEADER header{};
  header.bV5Size = sizeof(header);
  header.bV5Width = static_cast<LONG>(width);
  header.bV5Height = -static_cast<LONG>(height);
  header.bV5Planes = 1;
  header.bV5BitCount = 32;
  header.bV5Compression = BI_BITFIELDS;
  header.bV5SizeImage = static_cast<DWORD>(size);
  header.bV5RedMask = 0x00ff0000;
  header.bV5GreenMask = 0x0000ff00;
  header.bV5BlueMask = 0x000000ff;
  header.bV5AlphaMask = 0xff000000;
  header.bV5CSType = LCS_sRGB;
  std::vector<uint8_t> result(sizeof(header) + size);
  std::memcpy(result.data(), &header, sizeof(header));
  std::memcpy(result.data() + sizeof(header), pixels, size);
  return result;
}

#endif  // RUNNER_DIB_V5_H_
