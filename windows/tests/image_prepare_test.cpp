#include "../runner/image_prepare.h"
#include "../runner/single_job_worker.h"

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <thread>

#define CHECK(x) do { if (!(x)) { std::cerr << "CHECK failed: " #x << " at " << __LINE__ << '\n'; std::abort(); } } while (false)

using Worker = SingleJobWorker<ImageCopyJob, std::optional<PreparedClipboardImage>>;

static Worker::Result TakeEventually(Worker& worker) {
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    auto result = worker.TryTake();
    if (result) return std::move(*result);
    std::this_thread::yield();
  }
  std::abort();
}

int main() {
  Worker worker(PrepareClipboardImage);
  ImageCopyJob job{1, 1, {10, 20, 30, 255}};
  auto expected = MakeDibV5(1, 1, job.bgra.data(), job.bgra.size());
  CHECK(expected);
  CHECK(worker.TryStart(std::move(job)) == Worker::StartResult::started);
  auto result = TakeEventually(worker);
  CHECK(result.index() == 0);
  const auto& prepared = std::get<0>(result);
  CHECK(prepared);
  CHECK(prepared->dib == *expected);
  CHECK(prepared->png.size() >= 8);
  CHECK(prepared->png[0] == 0x89 && prepared->png[1] == 'P' &&
        prepared->png[2] == 'N' && prepared->png[3] == 'G');
  ImageCopyJob bad{1, 1, {1, 2, 3}};
  CHECK(worker.TryStart(std::move(bad)) == Worker::StartResult::started);
  auto invalid = TakeEventually(worker);
  CHECK(invalid.index() == 0 && !std::get<0>(invalid));

  CHECK(SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)));
  CHECK(!PrepareClipboardImage(ImageCopyJob{1, 1, {10, 20, 30, 255}}));
  APTTYPE apartment;
  APTTYPEQUALIFIER qualifier;
  CHECK(SUCCEEDED(CoGetApartmentType(&apartment, &qualifier)));
  CHECK(apartment == APTTYPE_STA || apartment == APTTYPE_MAINSTA);
  CoUninitialize();

  CHECK(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)));
  auto nested = PrepareClipboardImage(ImageCopyJob{1, 1, {10, 20, 30, 255}});
  CHECK(nested);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, nested->png.size());
  CHECK(memory);
  void* target = GlobalLock(memory);
  CHECK(target);
  std::memcpy(target, nested->png.data(), nested->png.size());
  GlobalUnlock(memory);
  IStream* stream = nullptr;
  CHECK(SUCCEEDED(CreateStreamOnHGlobal(memory, TRUE, &stream)));
  IWICImagingFactory* factory = nullptr;
  CHECK(SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_PPV_ARGS(&factory))));
  IWICBitmapDecoder* decoder = nullptr;
  CHECK(SUCCEEDED(factory->CreateDecoderFromStream(stream, nullptr, WICDecodeMetadataCacheOnLoad, &decoder)));
  IWICBitmapFrameDecode* frame = nullptr;
  CHECK(SUCCEEDED(decoder->GetFrame(0, &frame)));
  IWICFormatConverter* converter = nullptr;
  CHECK(SUCCEEDED(factory->CreateFormatConverter(&converter)));
  CHECK(SUCCEEDED(converter->Initialize(frame, GUID_WICPixelFormat32bppBGRA,
                                        WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom)));
  uint8_t decoded[4] = {};
  CHECK(SUCCEEDED(converter->CopyPixels(nullptr, 4, 4, decoded)));
  CHECK(decoded[0] == 10 && decoded[1] == 20 && decoded[2] == 30 && decoded[3] == 255);
  converter->Release();
  frame->Release();
  decoder->Release();
  factory->Release();
  stream->Release();
  CHECK(SUCCEEDED(CoGetApartmentType(&apartment, &qualifier)));
  CHECK(apartment == APTTYPE_MTA);
  CoUninitialize();
  CHECK(CoGetApartmentType(&apartment, &qualifier) == CO_E_NOTINITIALIZED);
}
