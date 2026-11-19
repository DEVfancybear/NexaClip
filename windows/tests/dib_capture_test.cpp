#include "../runner/dib_capture.h"
#include "../runner/dib_v5.h"
#include <iostream>
#define CHECK(x) do { if (!(x)) { std::cerr << "Failed line " << __LINE__ << '\n'; return 1; } } while (false)

int main() {
  BITMAPINFOHEADER h{};
  h.biSize = sizeof(h); h.biWidth = 1; h.biHeight = 2;
  h.biPlanes = 1; h.biBitCount = 24; h.biCompression = BI_RGB;
  std::vector<uint8_t> bytes(sizeof(h) + 8);
  std::memcpy(bytes.data(), &h, sizeof(h));
  const uint8_t pixels[] = {1, 2, 3, 99, 4, 5, 6, 88};
  std::memcpy(bytes.data() + sizeof(h), pixels, sizeof(pixels));
  auto image = ParseRgbDib(bytes.data(), bytes.size());
  CHECK(image && image->width == 1 && image->height == 2);
  CHECK(image->bgra == std::vector<uint8_t>({4, 5, 6, 255, 1, 2, 3, 255}));
  h.biHeight = -2;
  std::memcpy(bytes.data(), &h, sizeof(h));
  image = ParseRgbDib(bytes.data(), bytes.size());
  CHECK(image && image->bgra == std::vector<uint8_t>({1, 2, 3, 255, 4, 5, 6, 255}));
  CHECK(!ParseRgbDib(bytes.data(), bytes.size() - 1));
  h.biBitCount = 32;
  std::memcpy(bytes.data(), &h, sizeof(h));
  image = ParseRgbDib(bytes.data(), bytes.size());
  CHECK(image && image->bgra == std::vector<uint8_t>({1, 2, 3, 255, 4, 5, 6, 255}));
  h.biHeight = INT32_MIN;
  std::memcpy(bytes.data(), &h, sizeof(h));
  CHECK(!ParseRgbDib(bytes.data(), bytes.size()));
  h.biHeight = 2; h.biCompression = BI_BITFIELDS;
  std::memcpy(bytes.data(), &h, sizeof(h));
  CHECK(!ParseRgbDib(bytes.data(), bytes.size()));

  h.biCompression = BI_RGB;
  auto rejected = [&] {
    std::memcpy(bytes.data(), &h, sizeof(h));
    return !ParseRgbDib(bytes.data(), bytes.size());
  };
  CHECK(!ParseRgbDib(nullptr, bytes.size()));
  CHECK(!ParseRgbDib(bytes.data(), sizeof(h) - 1));
  h.biWidth = 0; CHECK(rejected());
  h.biWidth = -1; CHECK(rejected());
  h.biWidth = 8193; CHECK(rejected());
  h.biWidth = 1; h.biHeight = 0; CHECK(rejected());
  h.biHeight = 8193; CHECK(rejected());
  h.biWidth = 4001; h.biHeight = 4000; CHECK(rejected());
  h.biWidth = 1; h.biHeight = 2; h.biPlanes = 2; CHECK(rejected());
  h.biPlanes = 1; h.biBitCount = 16; CHECK(rejected());
  h.biBitCount = 32; h.biClrUsed = 1; CHECK(rejected());
  h.biClrUsed = 0; h.biSize = sizeof(h) + 1; CHECK(rejected());

  h.biSize = sizeof(h); h.biWidth = 2; h.biHeight = 2; h.biBitCount = 24;
  bytes.resize(sizeof(h) + 16);
  std::memcpy(bytes.data(), &h, sizeof(h));
  const uint8_t rows[] = {1,2,3, 4,5,6, 90,91, 7,8,9, 10,11,12, 92,93};
  std::memcpy(bytes.data() + sizeof(h), rows, sizeof(rows));
  image = ParseRgbDib(bytes.data(), bytes.size());
  CHECK(image && image->bgra == std::vector<uint8_t>({7,8,9,255, 10,11,12,255,
                                                       1,2,3,255, 4,5,6,255}));
  CHECK(!ParseRgbDib(bytes.data(), bytes.size() - 1));

  // Construct independently of MakeDibV5 to test the parser's input layout.
  BITMAPV5HEADER independent{};
  independent.bV5Size = sizeof(independent);
  independent.bV5Width = 2; independent.bV5Height = -1;
  independent.bV5Planes = 1; independent.bV5BitCount = 32;
  independent.bV5Compression = BI_BITFIELDS;
  independent.bV5RedMask = 0x00ff0000; independent.bV5GreenMask = 0x0000ff00;
  independent.bV5BlueMask = 0x000000ff; independent.bV5AlphaMask = 0xff000000;
  independent.bV5CSType = LCS_sRGB;
  std::vector<uint8_t> external(sizeof(independent) + 8);
  std::memcpy(external.data(), &independent, sizeof(independent));
  const uint8_t external_pixels[] = {19, 73, 221, 64, 200, 3, 17, 255};
  std::memcpy(external.data() + sizeof(independent), external_pixels, sizeof(external_pixels));
  auto independent_result = ParseV5Dib(external.data(), external.size());
  CHECK(independent_result && independent_result->width == 2 && independent_result->height == 1);
  CHECK(independent_result->bgra == std::vector<uint8_t>(external_pixels, external_pixels + sizeof(external_pixels)));

  const uint8_t v5pixels[] = {1,2,3,0, 4,5,6,128, 7,8,9,255, 10,11,12,1};
  auto v5 = MakeDibV5(2, 2, v5pixels, sizeof(v5pixels));
  CHECK(v5);
  auto parsed = ParseV5Dib(v5->data(), v5->size());
  CHECK(parsed && parsed->bgra == std::vector<uint8_t>(v5pixels, v5pixels + sizeof(v5pixels)));
  CHECK(!ParseV5Dib(v5->data(), v5->size() - 1));
  BITMAPV5HEADER vh{};
  std::memcpy(&vh, v5->data(), sizeof(vh));
  vh.bV5Height = 2;
  std::memcpy(v5->data(), &vh, sizeof(vh));
  parsed = ParseV5Dib(v5->data(), v5->size());
  CHECK(parsed && parsed->bgra == std::vector<uint8_t>({7,8,9,255,10,11,12,1,1,2,3,0,4,5,6,128}));
  vh.bV5AlphaMask = 0;
  std::memcpy(v5->data(), &vh, sizeof(vh));
  CHECK(!ParseV5Dib(v5->data(), v5->size()));
  vh.bV5AlphaMask = 0xff000000; vh.bV5ProfileSize = 1;
  std::memcpy(v5->data(), &vh, sizeof(vh));
  CHECK(!ParseV5Dib(v5->data(), v5->size()));
  vh.bV5ProfileSize = 0;
  auto rejectedV5 = [&] {
    std::memcpy(v5->data(), &vh, sizeof(vh));
    return !ParseV5Dib(v5->data(), v5->size());
  };
  CHECK(!ParseV5Dib(nullptr, v5->size()));
  CHECK(!ParseV5Dib(v5->data(), sizeof(vh) - 1));
  vh.bV5Width = 0; CHECK(rejectedV5());
  vh.bV5Width = 8193; CHECK(rejectedV5());
  vh.bV5Width = 4001; vh.bV5Height = 4000; CHECK(rejectedV5());
  vh.bV5Width = 2; vh.bV5Height = INT32_MIN; CHECK(rejectedV5());
  vh.bV5Height = 2; vh.bV5Planes = 2; CHECK(rejectedV5());
  vh.bV5Planes = 1; vh.bV5BitCount = 24; CHECK(rejectedV5());
  vh.bV5BitCount = 32; vh.bV5Compression = BI_RGB; CHECK(rejectedV5());
  vh.bV5Compression = BI_BITFIELDS; vh.bV5CSType = LCS_CALIBRATED_RGB; CHECK(rejectedV5());
  vh.bV5CSType = LCS_sRGB; vh.bV5ProfileData = sizeof(vh); CHECK(rejectedV5());
  vh.bV5ProfileData = 0; vh.bV5RedMask = 0; CHECK(rejectedV5());
  return 0;
}
