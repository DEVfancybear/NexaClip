#pragma once

#include "capped_stream.h"
#include <wincodec.h>
#include <wrl/client.h>
#include <cstdint>
#include <optional>
#include <vector>

// The caller must initialize COM on the current thread. Pixels are top-down,
// straight-alpha BGRA. Failure leaves the clipboard untouched.
inline std::optional<std::vector<uint8_t>> EncodeBgraPng(
    uint32_t width, uint32_t height, const uint8_t* pixels, size_t size,
    size_t output_limit) {
  if (!width || !height || width > 8192 || height > 8192 ||
      static_cast<uint64_t>(width) * height > 16000000 || !pixels ||
      size != static_cast<uint64_t>(width) * height * 4 || !output_limit) {
    return std::nullopt;
  }
  using Microsoft::WRL::ComPtr;
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                             CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))))
    return std::nullopt;
  ComPtr<CappedStream> stream;
  stream.Attach(new (std::nothrow) CappedStream(output_limit));
  if (!stream) return std::nullopt;
  ComPtr<IWICBitmapEncoder> encoder;
  if (FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) ||
      FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)))
    return std::nullopt;
  ComPtr<IWICBitmapFrameEncode> frame;
  if (FAILED(encoder->CreateNewFrame(&frame, nullptr)) ||
      FAILED(frame->Initialize(nullptr)) || FAILED(frame->SetSize(width, height)))
    return std::nullopt;
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(frame->SetPixelFormat(&format)) ||
      !IsEqualGUID(format, GUID_WICPixelFormat32bppBGRA) ||
      FAILED(frame->WritePixels(height, width * 4, static_cast<UINT>(size),
                                const_cast<BYTE*>(pixels))) ||
      FAILED(frame->Commit()) || FAILED(encoder->Commit()) ||
      stream->bytes().empty())
    return std::nullopt;
  frame.Reset();
  encoder.Reset();
  return stream->TakeBytes();
}
