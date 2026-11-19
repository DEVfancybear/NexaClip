#include "../runner/png_extent.h"
#include <iostream>
#include <vector>

#define CHECK(x) do { if (!(x)) { std::cerr << "Failed at line " << __LINE__ << '\n'; return 1; } } while (false)

int main() {
  std::vector<uint8_t> png = {137,80,78,71,13,10,26,10,
      0,0,0,4,'t','E','S','T','I','E','N','D',0,0,0,0,
      0,0,0,0,'I','E','N','D',0,0,0,0};
  const size_t end = png.size();
  CHECK(PngExtent(png.data(), png.size()) == end);
  png.insert(png.end(), {7, 8, 9});
  CHECK(PngExtent(png.data(), png.size()) == end);
  CHECK(!PngExtent(png.data(), end - 1));
  png[8] = 255; CHECK(!PngExtent(png.data(), png.size()));
  png[8] = 0; png[0] = 0; CHECK(!PngExtent(png.data(), png.size()));
  CHECK(!PngExtent(nullptr, 0));
  return 0;
}
