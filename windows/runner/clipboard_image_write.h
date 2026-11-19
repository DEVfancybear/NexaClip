#ifndef RUNNER_CLIPBOARD_IMAGE_WRITE_H_
#define RUNNER_CLIPBOARD_IMAGE_WRITE_H_

#include <cstdint>
#include <vector>

// API supplies Allocate, Free, Open, Empty, Set and Close. Set transfers
// ownership only on success; all buffers are prepared before Empty.
enum class ImageWriteResult { kSuccess, kPrepareFailed, kOpenFailed,
                              kEmptyFailed, kPartialWrite, kWriteFailed, kClipboardChanged };

template <typename Api, typename CanReplace>
ImageWriteResult WriteClipboardImageChecked(Api& api, unsigned png_format,
                                           unsigned dib_format,
                                           const std::vector<uint8_t>& png,
                                           const std::vector<uint8_t>& dib,
                                           CanReplace can_replace) {
  if (!png_format || !dib_format || png.empty() || dib.empty())
    return ImageWriteResult::kPrepareFailed;
  using Handle = typename Api::Handle;
  struct Buffer {
    Api& api;
    Handle handle;
    ~Buffer() { if (handle) api.Free(handle); }
  };
  Buffer png_buffer{api, api.Allocate(png)};
  if (!png_buffer.handle) return ImageWriteResult::kPrepareFailed;
  Buffer dib_buffer{api, api.Allocate(dib)};
  if (!dib_buffer.handle) return ImageWriteResult::kPrepareFailed;
  if (!api.Open()) return ImageWriteResult::kOpenFailed;
  struct ClipboardGuard {
    Api& api;
    ~ClipboardGuard() { api.Close(); }
  } guard{api};
  if (!can_replace()) return ImageWriteResult::kClipboardChanged;
  if (!api.Empty()) return ImageWriteResult::kEmptyFailed;
  const bool png_ok = api.Set(png_format, png_buffer.handle);
  if (png_ok) png_buffer.handle = Handle{};
  const bool dib_ok = api.Set(dib_format, dib_buffer.handle);
  if (dib_ok) dib_buffer.handle = Handle{};
  if (png_ok && dib_ok) return ImageWriteResult::kSuccess;
  if (png_ok || dib_ok) return ImageWriteResult::kPartialWrite;
  return ImageWriteResult::kWriteFailed;
}

template <typename Api>
ImageWriteResult WriteClipboardImage(Api& api, unsigned png_format,
                                    unsigned dib_format,
                                    const std::vector<uint8_t>& png,
                                    const std::vector<uint8_t>& dib) {
  return WriteClipboardImageChecked(api, png_format, dib_format, png, dib,
                                    [] { return true; });
}

#endif  // RUNNER_CLIPBOARD_IMAGE_WRITE_H_
