// Manual test: replaces the system clipboard with synthetic pixels. It never
// reads before both synthetic formats have been written in the same open.
#include <windows.h>
#include <cstring>
#include <iostream>
#include <vector>
#include "../runner/clipboard_image_write.h"
#include "../runner/dib_v5.h"
#include "../runner/wic_png_encoder.h"

struct RealApi {
  using Handle = HGLOBAL;
  HWND window;
  unsigned png_format;
  const std::vector<uint8_t>& png;
  const std::vector<uint8_t>& dib;
  unsigned successes = 0;
  bool matched = false;
  bool closed = false;
  Handle Allocate(const std::vector<uint8_t>& bytes) {
    Handle h = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
    if (!h) return nullptr;
    void* p = GlobalLock(h);
    if (!p) { GlobalFree(h); return nullptr; }
    std::memcpy(p, bytes.data(), bytes.size());
    GlobalUnlock(h);
    return h;
  }
  void Free(Handle h) { GlobalFree(h); }
  bool Open() { return OpenClipboard(window) != 0; }
  bool Empty() { return EmptyClipboard() != 0; }
  bool Set(unsigned format, Handle h) {
    if (!SetClipboardData(format, h)) return false;
    ++successes;
    return true;
  }
  bool Matches(unsigned format, const std::vector<uint8_t>& expected) {
    HANDLE h = GetClipboardData(format);
    if (!h || GlobalSize(h) < expected.size()) return false;
    const void* p = GlobalLock(h);
    if (!p) return false;
    const bool same = std::memcmp(p, expected.data(), expected.size()) == 0;
    GlobalUnlock(h);
    return same;
  }
  void Close() noexcept {
    // Never inspect clipboard after any failed write or after closing it.
    if (successes == 2)
      matched = Matches(png_format, png) && Matches(CF_DIBV5, dib);
    closed = CloseClipboard() != 0;
  }
};

int main() {
  const HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(hr)) return 1;
  HWND hwnd = CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0,
                              HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (!hwnd) { CoUninitialize(); return 2; }
  const std::vector<uint8_t> pixels{1, 2, 3, 255, 40, 50, 60, 128};
  auto png = EncodeBgraPng(2, 1, pixels.data(), pixels.size(), 10 * 1024 * 1024);
  auto dib = MakeDibV5(2, 1, pixels.data(), pixels.size());
  const UINT format = RegisterClipboardFormatW(L"PNG");
  int result = 3;
  if (png && dib && format) {
    RealApi api{hwnd, format, *png, *dib};
    auto status = WriteClipboardImage(api, format, CF_DIBV5, *png, *dib);
    result = status == ImageWriteResult::kSuccess && api.matched && api.closed ? 0 : 4;
  }
  DestroyWindow(hwnd);
  CoUninitialize();
  if (result) std::cerr << "Synthetic image write test failed: " << result << '\n';
  return result;
}
