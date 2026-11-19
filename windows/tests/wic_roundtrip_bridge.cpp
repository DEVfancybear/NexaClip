// Synthetic test bridge: reads raw straight-alpha BGRA, writes WIC PNG.
// It never opens or reads the clipboard.
#include "../runner/wic_png_encoder.h"
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  if (argc != 5) return 1;
  try {
    const auto width = std::stoul(argv[1]);
    const auto height = std::stoul(argv[2]);
    std::ifstream input(argv[3], std::ios::binary);
    if (!input) return 2;
    std::vector<uint8_t> pixels((std::istreambuf_iterator<char>(input)), {});
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 3;
    const auto png = EncodeBgraPng(width, height, pixels.data(), pixels.size(), 1048576);
    CoUninitialize();
    if (!png) return 4;
    std::ofstream output(argv[4], std::ios::binary);
    output.write(reinterpret_cast<const char*>(png->data()), png->size());
    return output ? 0 : 5;
  } catch (...) { return 6; }
}
