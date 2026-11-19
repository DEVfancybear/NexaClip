#include "../runner/wic_png_encoder.h"
#include <wincodec.h>
#include <wrl/client.h>
#include <iostream>

using Microsoft::WRL::ComPtr;
#define CHECK(x) do { if (!(x)) { std::cerr << "Failed at line " << __LINE__ << '\n'; return 1; } } while (false)

int main() {
  CHECK(SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)));
  {
    ComPtr<IWICImagingFactory> factory;
    CHECK(SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))));
    BYTE pixels[] = {1, 2, 3, 0, 250, 10, 20, 1, 32, 64, 128, 128,
                     3, 45, 201, 255, 255, 4, 18, 64, 17, 87, 234, 127};
    CHECK(!EncodeBgraPng(0, 1, pixels, sizeof(pixels), 4096));
    CHECK(!EncodeBgraPng(3, 2, pixels, 7, 4096));
    CHECK(!EncodeBgraPng(8193, 1, pixels, sizeof(pixels), 4096));
    CHECK(!EncodeBgraPng(3, 2, pixels, sizeof(pixels), 8));
    auto png = EncodeBgraPng(3, 2, pixels, sizeof(pixels), 4096);
    CHECK(png && !png->empty() && png->size() <= 4096);
    ComPtr<CappedStream> stream;
    stream.Attach(new CappedStream(4096));
    ULONG written = 0;
    CHECK(SUCCEEDED(stream->Write(png->data(), static_cast<ULONG>(png->size()), &written)));
    CHECK(written == png->size());
    LARGE_INTEGER zero{};
    CHECK(SUCCEEDED(stream->Seek(zero, STREAM_SEEK_SET, nullptr)));
    ComPtr<IWICBitmapDecoder> decoder;
    CHECK(SUCCEEDED(factory->CreateDecoderFromStream(stream.Get(), nullptr,
        WICDecodeMetadataCacheOnLoad, &decoder)));
    ComPtr<IWICBitmapFrameDecode> decoded;
    CHECK(SUCCEEDED(decoder->GetFrame(0, &decoded)));
    ComPtr<IWICFormatConverter> converter;
    CHECK(SUCCEEDED(factory->CreateFormatConverter(&converter)));
    CHECK(SUCCEEDED(converter->Initialize(decoded.Get(), GUID_WICPixelFormat32bppBGRA,
        WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom)));
    BYTE result[sizeof(pixels)]{};
    CHECK(SUCCEEDED(converter->CopyPixels(nullptr, 12, sizeof(result), result)));
    CHECK(std::memcmp(result, pixels, sizeof(pixels)) == 0);
  }
  CoUninitialize();
  return 0;
}
