#pragma once

#include <windows.h>
#include <objidl.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <cstdint>
#include <new>
#include <vector>
#include <utility>

// A seekable in-memory COM stream with a strict maximum logical size.
class CappedStream final : public IStream {
 public:
  explicit CappedStream(size_t limit) : limit_(limit) {}
  const std::vector<unsigned char>& bytes() const { return bytes_; }
  std::vector<unsigned char> TakeBytes() noexcept { return std::move(bytes_); }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (id == IID_IUnknown || id == IID_ISequentialStream || id == IID_IStream) {
      *out = static_cast<IStream*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override {
    ULONG remaining = --refs_;
    if (!remaining) delete this;
    return remaining;
  }
  HRESULT STDMETHODCALLTYPE Read(void* out, ULONG count, ULONG* read) override {
    if (read) *read = 0;
    if (!out && count) return STG_E_INVALIDPOINTER;
    const size_t available = position_ < bytes_.size() ? bytes_.size() - position_ : 0;
    const size_t n = (std::min)(static_cast<size_t>(count), available);
    if (n) std::memcpy(out, bytes_.data() + position_, n);
    position_ += n;
    if (read) *read = static_cast<ULONG>(n);
    return n == count ? S_OK : S_FALSE;
  }
  HRESULT STDMETHODCALLTYPE Write(const void* input, ULONG count, ULONG* written) override {
    if (written) *written = 0;
    if (!input && count) return STG_E_INVALIDPOINTER;
    if (!count) return S_OK;
    if (position_ > limit_ || count > limit_ - position_) return STG_E_MEDIUMFULL;
    const size_t end = position_ + count;
    try {
      if (end > bytes_.size()) bytes_.resize(end);
    } catch (const std::bad_alloc&) {
      return STG_E_INSUFFICIENTMEMORY;
    } catch (...) {
      return E_FAIL;
    }
    if (count) std::memcpy(bytes_.data() + position_, input, count);
    position_ = end;
    if (written) *written = count;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Seek(LARGE_INTEGER move, DWORD origin,
                                 ULARGE_INTEGER* result) override {
    uint64_t base;
    if (origin == STREAM_SEEK_SET) {
      position_ = static_cast<uint64_t>(move.QuadPart);
      if (result) result->QuadPart = position_;
      return S_OK;
    } else if (origin == STREAM_SEEK_CUR) {
      base = position_;
    } else if (origin == STREAM_SEEK_END) {
      base = bytes_.size();
    } else {
      return STG_E_INVALIDFUNCTION;
    }
    if (move.QuadPart < 0) {
      const auto magnitude = static_cast<uint64_t>(-(move.QuadPart + 1)) + 1;
      if (magnitude > base) return STG_E_INVALIDFUNCTION;
      position_ = base - magnitude;
    } else {
      const auto delta = static_cast<uint64_t>(move.QuadPart);
      if (delta > UINT64_MAX - base) return STG_E_INVALIDFUNCTION;
      position_ = base + delta;
    }
    if (result) result->QuadPart = position_;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE SetSize(ULARGE_INTEGER size) override {
    if (size.QuadPart > limit_) return STG_E_MEDIUMFULL;
    try {
      bytes_.resize(static_cast<size_t>(size.QuadPart));
      return S_OK;
    } catch (const std::bad_alloc&) {
      return STG_E_INSUFFICIENTMEMORY;
    } catch (...) {
      return E_FAIL;
    }
  }
  HRESULT STDMETHODCALLTYPE CopyTo(IStream*, ULARGE_INTEGER, ULARGE_INTEGER*, ULARGE_INTEGER*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE Commit(DWORD) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE Revert() override { return STG_E_REVERTED; }
  HRESULT STDMETHODCALLTYPE LockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override { return STG_E_INVALIDFUNCTION; }
  HRESULT STDMETHODCALLTYPE UnlockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override { return STG_E_INVALIDFUNCTION; }
  HRESULT STDMETHODCALLTYPE Stat(STATSTG* stat, DWORD) override {
    if (!stat) return STG_E_INVALIDPOINTER;
    std::memset(stat, 0, sizeof(*stat));
    stat->type = STGTY_STREAM;
    stat->cbSize.QuadPart = bytes_.size();
    stat->grfMode = STGM_READWRITE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Clone(IStream**) override { return E_NOTIMPL; }

 private:
  std::atomic<ULONG> refs_{1};
  size_t limit_;
  uint64_t position_ = 0;
  std::vector<unsigned char> bytes_;
};
