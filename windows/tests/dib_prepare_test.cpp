#include "../runner/dib_prepare.h"
#include "../runner/single_job_worker.h"

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <thread>

#define CHECK(x) do { if (!(x)) { std::cerr << "CHECK failed: " #x << " at " << __LINE__ << '\n'; std::abort(); } } while (false)
using Worker = SingleJobWorker<std::vector<uint8_t>, std::optional<std::vector<uint8_t>>>;

static std::vector<uint8_t> DecodePng(const std::vector<uint8_t>& png, UINT width, UINT height) {
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, png.size());
  CHECK(memory);
  void* data = GlobalLock(memory);
  CHECK(data);
  std::memcpy(data, png.data(), png.size());
  GlobalUnlock(memory);
  IStream* stream = nullptr;
  CHECK(SUCCEEDED(CreateStreamOnHGlobal(memory, TRUE, &stream)));
  IWICImagingFactory* factory = nullptr;
  CHECK(SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))));
  IWICBitmapDecoder* decoder = nullptr;
  CHECK(SUCCEEDED(factory->CreateDecoderFromStream(stream, nullptr, WICDecodeMetadataCacheOnLoad, &decoder)));
  IWICBitmapFrameDecode* frame = nullptr;
  CHECK(SUCCEEDED(decoder->GetFrame(0, &frame)));
  IWICFormatConverter* converter = nullptr;
  CHECK(SUCCEEDED(factory->CreateFormatConverter(&converter)));
  CHECK(SUCCEEDED(converter->Initialize(frame, GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom)));
  std::vector<uint8_t> decoded(width * height * 4);
  CHECK(SUCCEEDED(converter->CopyPixels(nullptr, width * 4, static_cast<UINT>(decoded.size()), decoded.data())));
  converter->Release(); frame->Release(); decoder->Release(); factory->Release(); stream->Release();
  return decoded;
}

int main() {
  BITMAPINFOHEADER header{};
  header.biSize = sizeof(header);
  header.biWidth = 1;
  header.biHeight = -1;
  header.biPlanes = 1;
  header.biBitCount = 24;
  header.biCompression = BI_RGB;
  std::vector<uint8_t> input(sizeof(header) + 4);
  std::memcpy(input.data(), &header, sizeof(header));
  input[sizeof(header)] = 10;
  input[sizeof(header) + 1] = 20;
  input[sizeof(header) + 2] = 30;
  input[sizeof(header) + 3] = 99;
  Worker worker(PrepareRgbClipboardDib);
  CHECK(worker.TryStart(std::move(input)) == Worker::StartResult::started);
  std::optional<Worker::Result> result;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!result && std::chrono::steady_clock::now() < deadline) {
    result = worker.TryTake();
    std::this_thread::yield();
  }
  CHECK(result && result->index() == 0 && std::get<0>(*result));
  auto& png = *std::get<0>(*result);
  CHECK(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)));
  CHECK(DecodePng(png, 1, 1) == std::vector<uint8_t>({10, 20, 30, 255}));
  header.biHeight = 2;
  header.biBitCount = 32;
  std::vector<uint8_t> bottom_up(sizeof(header) + 8);
  std::memcpy(bottom_up.data(), &header, sizeof(header));
  const uint8_t rows[] = {1, 2, 3, 0, 4, 5, 6, 7};
  std::memcpy(bottom_up.data() + sizeof(header), rows, sizeof(rows));
  auto saved_dib = bottom_up;
  int attempts = 0;
  auto recovered = PrepareDibCandidates({{1}, {2}}, [&](std::vector<uint8_t> candidate)
      -> std::optional<std::vector<uint8_t>> {
    if (++attempts == 1) throw std::bad_alloc();
    return candidate;
  });
  CHECK(attempts == 2 && recovered && *recovered == std::vector<uint8_t>({2}));
  auto fallback = PrepareClipboardDibCandidates({{1, 2, 3}, bottom_up});
  CHECK(fallback);
  CHECK(DecodePng(*fallback, 1, 2) == std::vector<uint8_t>({4, 5, 6, 255, 1, 2, 3, 255}));
  auto rgb32 = PrepareRgbClipboardDib(std::move(bottom_up));
  CHECK(rgb32);
  CHECK(DecodePng(*rgb32, 1, 2) == std::vector<uint8_t>({4, 5, 6, 255, 1, 2, 3, 255}));
  BITMAPV5HEADER v5{};
  v5.bV5Size = sizeof(v5);
  v5.bV5Width = 1;
  v5.bV5Height = -1;
  v5.bV5Planes = 1;
  v5.bV5BitCount = 32;
  v5.bV5Compression = BI_BITFIELDS;
  v5.bV5RedMask = 0x00ff0000;
  v5.bV5GreenMask = 0x0000ff00;
  v5.bV5BlueMask = 0x000000ff;
  v5.bV5AlphaMask = 0xff000000;
  v5.bV5CSType = LCS_sRGB;
  std::vector<uint8_t> v5_bytes(sizeof(v5) + 4);
  std::memcpy(v5_bytes.data(), &v5, sizeof(v5));
  const uint8_t v5_pixel[] = {10, 20, 30, 128};
  std::memcpy(v5_bytes.data() + sizeof(v5), v5_pixel, sizeof(v5_pixel));
  auto preferred = PrepareClipboardDibCandidates({v5_bytes, saved_dib});
  CHECK(preferred);
  CHECK(DecodePng(*preferred, 1, 1) == std::vector<uint8_t>({10, 20, 30, 128}));
  CHECK(!PrepareClipboardDibCandidates({{1, 2, 3}, {4, 5, 6}}));
  auto v5_png = PrepareClipboardDib(std::move(v5_bytes));
  CHECK(v5_png);
  CHECK(DecodePng(*v5_png, 1, 1) == std::vector<uint8_t>({10, 20, 30, 128}));
  CoUninitialize();
  CHECK(!PrepareRgbClipboardDib(std::vector<uint8_t>{1, 2, 3}));
  CHECK(!PrepareRgbClipboardDib(std::vector<uint8_t>(kMaxRgbDibBytes + 1)));
  CHECK(SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)));
  CHECK(!PrepareRgbClipboardDib(std::move(saved_dib)));
  APTTYPE type;
  APTTYPEQUALIFIER qualifier;
  CHECK(SUCCEEDED(CoGetApartmentType(&type, &qualifier)));
  CHECK(type == APTTYPE_STA || type == APTTYPE_MAINSTA);
  CoUninitialize();
  CHECK(CoGetApartmentType(&type, &qualifier) == CO_E_NOTINITIALIZED);
}
