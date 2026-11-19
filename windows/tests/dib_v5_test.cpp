#include "../runner/dib_v5.h"
#include <iostream>

#define CHECK(x) do { if (!(x)) { std::cerr << "Failed at line " << __LINE__ << '\n'; return 1; } } while (false)

int main() {
  const uint8_t pixels[] = {1, 2, 3, 4, 5, 6, 7, 8};
  auto dib = MakeDibV5(1, 2, pixels, sizeof(pixels));
  CHECK(dib.has_value());
  CHECK(dib->size() == sizeof(BITMAPV5HEADER) + sizeof(pixels));
  BITMAPV5HEADER header{};
  std::memcpy(&header, dib->data(), sizeof(header));
  CHECK(header.bV5Size == sizeof(header));
  CHECK(header.bV5Width == 1 && header.bV5Height == -2);
  CHECK(header.bV5Planes == 1 && header.bV5BitCount == 32);
  CHECK(header.bV5Compression == BI_BITFIELDS && header.bV5SizeImage == 8);
  CHECK(header.bV5RedMask == 0x00ff0000 && header.bV5GreenMask == 0x0000ff00);
  CHECK(header.bV5BlueMask == 0x000000ff && header.bV5AlphaMask == 0xff000000);
  CHECK(header.bV5CSType == LCS_sRGB);
  CHECK(std::memcmp(dib->data() + sizeof(header), pixels, sizeof(pixels)) == 0);
  const uint8_t alpha_pixels[] = {0, 0, 0, 0, 32, 64, 128, 128, 3, 2, 1, 255};
  auto alpha_dib = MakeDibV5(3, 1, alpha_pixels, sizeof(alpha_pixels));
  CHECK(alpha_dib.has_value());
  CHECK(std::memcmp(alpha_dib->data() + sizeof(header), alpha_pixels, sizeof(alpha_pixels)) == 0);
  CHECK(!MakeDibV5(1, 0, pixels, sizeof(pixels)));
  CHECK(!MakeDibV5(1, 1, pixels, sizeof(pixels)));
  std::vector<uint8_t> wide(8192 * 4, 0);
  CHECK(MakeDibV5(8192, 1, wide.data(), wide.size()).has_value());
  {
    std::vector<uint8_t> maximum(16000000 * 4, 0);
    auto largest = MakeDibV5(4000, 4000, maximum.data(), maximum.size());
    CHECK(largest.has_value());
    CHECK(largest->size() == sizeof(header) + maximum.size());
  }
  CHECK(!MakeDibV5(4001, 4000, pixels, sizeof(pixels)));
  CHECK(!MakeDibV5(0, 1, pixels, sizeof(pixels)));
  CHECK(!MakeDibV5(1, 1, nullptr, 4));
  CHECK(!MakeDibV5(1, 2, pixels, 7));
  CHECK(!MakeDibV5(8193, 1, pixels, sizeof(pixels)));
  CHECK(!MakeDibV5(8192, 8192, pixels, sizeof(pixels)));
  CHECK(!MakeDibV5(UINT32_MAX, UINT32_MAX, pixels, sizeof(pixels)));
  return 0;
}
