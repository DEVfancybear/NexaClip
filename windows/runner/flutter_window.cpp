#include "flutter_window.h"

#include <exception>
#include <limits>
#include <optional>
#include <string>
#include <type_traits>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/method_result_functions.h>
#include "clipboard_privacy.h"
#include "clipboard_bytes.h"
#include "clipboard_text.h"
#include "clipboard_snapshot.h"
#include "capture_admission.h"
#include "png_extent.h"
#include "clipboard_image_write.h"
#include "dib_v5.h"
#include "dib_prepare.h"
#include "wic_png_encoder.h"
#include "start_with_cleanup.h"

namespace {
static_assert(std::is_nothrow_move_assignable_v<flutter::EncodableMap>,
              "Installing a started DIB capture must not throw");
struct WinClipboardWriter {
  using Handle = HGLOBAL;
  HWND hwnd;
  Handle Allocate(const std::vector<uint8_t>& bytes) {
    Handle handle = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
    if (!handle) return nullptr;
    void* destination = GlobalLock(handle);
    if (!destination) {
      GlobalFree(handle);
      return nullptr;
    }
    std::memcpy(destination, bytes.data(), bytes.size());
    GlobalUnlock(handle);
    return handle;
  }
  void Free(Handle handle) noexcept { GlobalFree(handle); }
  bool Open() { return OpenClipboard(hwnd) != 0; }
  bool Empty() { return EmptyClipboard() != 0; }
  bool Set(unsigned format, Handle handle) {
    return SetClipboardData(format, handle) != nullptr;
  }
  void Close() noexcept { CloseClipboard(); }
};

std::optional<flutter::EncodableValue> ClipboardSnapshot(HWND hwnd) {
  flutter::EncodableMap snapshot;
  CaptureClipboardSnapshotWithPrivacy(
      [hwnd] { return OpenClipboard(hwnd) != 0; },
      []() noexcept { CloseClipboard(); },
      [](const wchar_t* name) { return RegisterClipboardFormatW(name); },
      [](UINT format) { return IsClipboardFormatAvailable(format) != 0; },
      [](UINT history) {
        return ReadClipboardHistoryMarker(
            GetClipboardData(history),
            [](HANDLE handle) { return GlobalSize(handle); },
            [](HANDLE handle) { return GlobalLock(handle); },
            [](HANDLE handle) noexcept { GlobalUnlock(handle); });
      },
      [&] {
        std::optional<std::string> text;
        if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
          HANDLE data = GetClipboardData(CF_UNICODETEXT);
          if (data) {
            const SIZE_T size = GlobalSize(data) / sizeof(wchar_t);
            auto chars = static_cast<const wchar_t*>(GlobalLock(data));
            if (chars) {
              struct UnlockGuard {
                HANDLE handle;
                ~UnlockGuard() { GlobalUnlock(handle); }
              } unlock_guard{data};
              bool too_large = false;
              text = DecodeClipboardText(chars, size, &too_large);
              if (too_large) {
                snapshot.emplace(flutter::EncodableValue("textTooLarge"),
                                 flutter::EncodableValue(true));
              }
            }
          }
        }
        if (text) snapshot.emplace(flutter::EncodableValue("text"),
                                   flutter::EncodableValue(std::move(*text)));
      },
      [&] {
        const UINT png_format = RegisterClipboardFormatW(L"PNG");
        if (png_format && IsClipboardFormatAvailable(png_format)) {
          constexpr size_t kMaxPngBytes = 10 * 1024 * 1024;
          std::optional<std::vector<uint8_t>> bytes;
          try {
            bytes = CopyClipboardBytes(
                GetClipboardData(png_format), kMaxPngBytes,
                [](HANDLE handle) { return GlobalSize(handle); },
                [](HANDLE handle) { return GlobalLock(handle); },
                [](HANDLE handle) noexcept { GlobalUnlock(handle); });
          } catch (const std::bad_alloc&) {
            // Best effort: reporting the rejection can itself fail under pressure.
          }
          const auto extent = bytes ? PngExtent(bytes->data(), bytes->size()) : std::nullopt;
          if (extent) {
            bytes->resize(*extent);
            snapshot.emplace(flutter::EncodableValue("png"),
                             flutter::EncodableValue(std::move(*bytes)));
          } else {
            snapshot.emplace(flutter::EncodableValue("pngRejected"),
                             flutter::EncodableValue(true));
          }
        }
        {
          for (const auto format : {CF_DIBV5, CF_DIB}) {
            if (!IsClipboardFormatAvailable(format)) continue;
            try {
            auto dib = CopyClipboardBytes(
                GetClipboardData(format), kMaxClipboardDibBytes,
                [](HANDLE handle) { return GlobalSize(handle); },
                [](HANDLE handle) { return GlobalLock(handle); },
                [](HANDLE handle) noexcept { GlobalUnlock(handle); });
            const char* key = format == CF_DIBV5 ? "_dibV5" : "_dib";
            if (dib && format == CF_DIBV5 && dib->size() >= sizeof(DWORD)) {
              DWORD header_size = 0;
              std::memcpy(&header_size, dib->data(), sizeof(header_size));
              if (header_size == sizeof(BITMAPV5HEADER) &&
                  !IsSupportedV5Dib(dib->data(), dib->size())) {
                dib.reset();
              }
            }
            if (dib) {
              snapshot[flutter::EncodableValue(key)] = flutter::EncodableValue(std::move(*dib));
            } else if (!snapshot.count(flutter::EncodableValue("png"))) {
              snapshot[flutter::EncodableValue("pngRejected")] = flutter::EncodableValue(true);
            }
            } catch (const std::bad_alloc&) {
              try {
                if (!snapshot.count(flutter::EncodableValue("png")))
                  snapshot[flutter::EncodableValue("pngRejected")] = flutter::EncodableValue(true);
              } catch (const std::bad_alloc&) {}
            }
          }
        }
      });
  if (snapshot.empty()) return std::nullopt;
  return flutter::EncodableValue(std::move(snapshot));
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

thread_local std::map<UINT_PTR, FlutterWindow*> FlutterWindow::image_timers_;
thread_local std::map<UINT_PTR, FlutterWindow*> FlutterWindow::dib_timers_;

FlutterWindow::~FlutterWindow() {
  StopDibCapture();
  StopImageCopy();
}

void CALLBACK FlutterWindow::ImageTimerProc(HWND, UINT, UINT_PTR id, DWORD) {
  const auto entry = image_timers_.find(id);
  if (entry == image_timers_.end()) return;
  auto* window = entry->second;
  try {
    window->PollImageCopy(window->GetHandle());
  } catch (...) {
    try {
      window->StopImageCopy();
    } catch (...) {
      // Do not unwind through the Windows callback boundary.
    }
  }
}

bool FlutterWindow::OnCreate() {
  // Create() destroys the previous HWND before invoking OnCreate(). A listener
  // registration belongs to that HWND and cannot be reused by this one.
  clipboard_listener_ = ClipboardListenerState{};
  capture_lifetime_ = std::make_shared<int>(0);
  image_worker_ = std::make_unique<ImageWorker>(PrepareClipboardImage);
  dib_worker_ = std::make_unique<DibWorker>(PrepareClipboardDibCandidates);
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  clipboard_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "nexaclip/clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  clipboard_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "start") {
          if (capture_delivery_) {
            result->Error("listener_failed", "Clipboard listener is already active or stopping");
            return;
          }
          const auto* argument = call.arguments();
          int64_t generation = 0;
          if (argument) {
            if (const auto* value32 = std::get_if<int32_t>(argument)) generation = *value32;
            else if (const auto* value64 = std::get_if<int64_t>(argument)) generation = *value64;
          }
          if (generation <= 0) {
            result->Error("listener_failed", "Invalid clipboard capture generation");
            return;
          }
          try {
            capture_delivery_ = NewCaptureDelivery(generation);
          } catch (...) {
            result->Error("listener_failed", "Unable to prepare clipboard capture");
            return;
          }
          if (!clipboard_listener_.Start([this] { return AddClipboardFormatListener(GetHandle()) != 0; })) {
            capture_delivery_.reset();
            result->Error("listener_failed", "Unable to register clipboard listener");
            return;
          }
          result->Success();
        } else if (call.method_name() == "stop") {
          std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply;
          std::shared_ptr<bool> reply_attempted;
          try {
            reply_attempted = std::make_shared<bool>(false);
            reply = std::move(result);
            const bool removed = clipboard_listener_.Stop([this] { return RemoveClipboardFormatListener(GetHandle()) != 0; });
            if (!capture_delivery_) {
              *reply_attempted = true;
              if (removed) reply->Success();
              else reply->Error("listener_failed", "Unable to remove clipboard listener");
              return;
            }
            auto delivery = capture_delivery_;
            std::weak_ptr<CaptureQueue> stopped_delivery = delivery;
            std::weak_ptr<int> lifetime = capture_lifetime_;
            delivery->Stop([this, reply, reply_attempted, removed, stopped_delivery, lifetime](bool delivered) {
              if (lifetime.expired()) return;
              if (capture_delivery_ == stopped_delivery.lock()) capture_delivery_.reset();
              if (*reply_attempted) return;
              *reply_attempted = true;
              if (!removed) reply->Error("listener_failed", "Unable to remove clipboard listener");
              else if (!delivered) reply->Error("capture_delivery_failed", "Unable to deliver clipboard changes");
              else reply->Success();
            });
          } catch (...) {
            // A channel reply may itself throw; its outcome is then unknown.
            if (!reply_attempted || !*reply_attempted) {
              if (reply_attempted) *reply_attempted = true;
              clipboard_listener_.Stop([this] { return RemoveClipboardFormatListener(GetHandle()) != 0; });
              // Keep the delivery owned so a retry can stop it; abandoning it
              // here could allow a new session while an old Dart write is live.
              try {
                if (reply) reply->Error("listener_failed", "Unable to stop clipboard delivery; retry required");
                else if (result) result->Error("listener_failed", "Unable to stop clipboard delivery; retry required");
              } catch (...) {}
            }
          }
        } else if (call.method_name() == "clipboardSequence") {
          const DWORD sequence = GetClipboardSequenceNumber();
          if (!sequence) {
            result->Error("clipboard_unavailable", "Unable to get clipboard sequence");
          } else {
            result->Success(flutter::EncodableValue(static_cast<int64_t>(sequence)));
          }
        } else if (call.method_name() == "copyImage") {
          auto reply_error = [&result](const char* code, const char* message) noexcept {
            try {
              result->Error(code, message);
            } catch (...) {
              // The reply outcome is unknown, so do not try to send it again.
            }
          };
          try {
            const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
            if (!args) {
              reply_error("invalid_image", "Missing image data");
              return;
            }
            auto sequence_it = args->find(flutter::EncodableValue("sequence"));
            if (sequence_it == args->end()) {
              reply_error("invalid_image", "Missing clipboard sequence");
              return;
            }
            int64_t sequence = 0;
            if (const auto* value = std::get_if<int32_t>(&sequence_it->second)) sequence = *value;
            else if (const auto* long_value = std::get_if<int64_t>(&sequence_it->second)) sequence = *long_value;
            if (sequence <= 0 || sequence > UINT32_MAX) {
              reply_error("invalid_image", "Invalid clipboard sequence");
              return;
            }
            const DWORD clipboard_sequence = static_cast<DWORD>(sequence);
            auto pixels_it = args->find(flutter::EncodableValue("bgra"));
            auto width_it = args->find(flutter::EncodableValue("width"));
            auto height_it = args->find(flutter::EncodableValue("height"));
            if (pixels_it == args->end() ||
                width_it == args->end() || height_it == args->end()) {
              reply_error("invalid_image", "Missing image fields");
              return;
            }
            const auto* pixels = std::get_if<std::vector<uint8_t>>(&pixels_it->second);
            const auto* width = std::get_if<int32_t>(&width_it->second);
            const auto* height = std::get_if<int32_t>(&height_it->second);
            if (!pixels || !width || !height || *width <= 0 || *height <= 0) {
              reply_error("invalid_image", "Invalid image fields");
              return;
            }
            const auto count = static_cast<uint64_t>(*width) * static_cast<uint64_t>(*height);
            if (*width > 8192 || *height > 8192 || count > 16000000 ||
                pixels->size() != count * 4) {
              reply_error("invalid_image", "Invalid image dimensions");
              return;
            }
            if (!image_worker_ || image_result_) {
              reply_error("image_copy_busy", "An image copy is already in progress");
              return;
            }
            ImageCopyJob job{*width, *height, *pixels};
            HWND hwnd = GetHandle();
            if (!hwnd) {
              reply_error("clipboard_write_failed", "Window is unavailable");
              return;
            }
            const UINT_PTR timer = SetTimer(nullptr, 0, 20, ImageTimerProc);
            if (!timer) {
              reply_error("clipboard_write_failed", "Unable to start image copy timer");
              return;
            }
            try {
              if (!image_timers_.emplace(timer, this).second) {
                KillTimer(nullptr, timer);
                reply_error("clipboard_write_failed", "Image copy timer is already registered");
                return;
              }
            } catch (...) {
              KillTimer(nullptr, timer);
              throw;
            }
            bool started = false;
            try {
              started = StartWithCleanup(
                  [&] { return image_worker_->TryStart(std::move(job)) ==
                               ImageWorker::StartResult::started; },
                  [&] { image_timers_.erase(timer); KillTimer(nullptr, timer); });
            } catch (...) {
              // Cleanup has run; report a failed start outside this catch.
            }
            if (!started) {
              reply_error("clipboard_write_failed", "Unable to start image preparation");
              return;
            }
            image_timer_ = timer;
            image_expected_sequence_ = clipboard_sequence;
            image_result_ = std::move(result);
          } catch (...) {
            reply_error("clipboard_write_failed", "Unable to prepare image");
          }
        } else {
          result->NotImplemented();
        }
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void CALLBACK FlutterWindow::DibTimerProc(HWND, UINT, UINT_PTR id, DWORD) {
  const auto entry = dib_timers_.find(id);
  if (entry == dib_timers_.end()) return;
  auto* window = entry->second;
  try {
    window->PollDibCapture();
  } catch (...) {
    if (window->dib_delivery_) window->dib_delivery_->FailQueue();
    window->StopDibCapture();
    window->dib_worker_.reset();
  }
}

void FlutterWindow::PollDibCapture() {
  if (!dib_worker_ || !dib_delivery_) return;
  auto completion = dib_worker_->TryTake();
  if (!completion) return;
  dib_timers_.erase(dib_timer_);
  KillTimer(nullptr, dib_timer_);
  dib_timer_ = 0;
  auto delivery = dib_delivery_;
  size_t weight = dib_base_weight_;
  if (completion->index() == 0 && std::get<0>(*completion)) {
    weight += std::get<0>(*completion)->size();
    dib_snapshot_.erase(flutter::EncodableValue("pngRejected"));
    const char* key = dib_snapshot_.count(flutter::EncodableValue("png"))
                          ? "fallbackPng" : "png";
    dib_snapshot_[flutter::EncodableValue(key)] =
        flutter::EncodableValue(std::move(*std::get<0>(*completion)));
  } else {
    if (!dib_snapshot_.count(flutter::EncodableValue("png")))
      dib_snapshot_[flutter::EncodableValue("pngRejected")] = flutter::EncodableValue(true);
  }
  if (!delivery->Complete(dib_slot_, flutter::EncodableValue(std::move(dib_snapshot_)), weight)) {
    delivery->FailQueue();
  }
  dib_delivery_.reset();
}

void FlutterWindow::StopDibCapture() {
  if (dib_timer_) {
    dib_timers_.erase(dib_timer_);
    KillTimer(nullptr, dib_timer_);
    dib_timer_ = 0;
  }
  if (dib_worker_) dib_worker_->Shutdown();
  if (dib_delivery_) {
    dib_delivery_->FailQueue();
    dib_delivery_.reset();
  }
}

void FlutterWindow::PollImageCopy(HWND hwnd) {
  if (!image_worker_ || !image_result_) return;
  auto completion = image_worker_->TryTake();
  if (!completion) return;
  image_timers_.erase(image_timer_);
  KillTimer(nullptr, image_timer_);
  image_timer_ = 0;
  const DWORD expected = image_expected_sequence_;
  image_expected_sequence_ = 0;
  auto reply = std::move(image_result_);
  if (completion->index() != 0 || !std::get<0>(*completion)) {
    try {
      reply->Error("image_encode_failed", "Unable to encode PNG or output exceeds the size limit");
    } catch (...) {
      // A reply may have been sent before the exception; do not send it twice.
    }
    return;
  }
  const auto& image = *std::get<0>(*completion);
  std::optional<ImageWriteResult> status;
  try {
    WinClipboardWriter api{hwnd};
    status = WriteClipboardImageChecked(
        api, RegisterClipboardFormatW(L"PNG"), CF_DIBV5, image.png, image.dib,
        [expected] {
          return expected != 0 && GetClipboardSequenceNumber() == expected;
        });
  } catch (...) {
    // Reply once below, after leaving the operation that may throw.
  }
  try {
    if (status == ImageWriteResult::kSuccess) {
      reply->Success();
    } else if (status == ImageWriteResult::kClipboardChanged) {
      reply->Error("clipboard_changed", "Clipboard changed while preparing the image");
    } else if (status == ImageWriteResult::kPartialWrite) {
      reply->Error("partial_write", "Only one image format was copied");
    } else if (status == ImageWriteResult::kWriteFailed) {
      reply->Error("write_failed_after_empty", "Clipboard was emptied but image formats could not be written");
    } else {
      reply->Error("clipboard_write_failed", "Unable to copy image");
    }
  } catch (...) {
    // The response outcome is unknown; never retry it or stop the worker.
  }
}

void FlutterWindow::StopImageCopy() {
  if (image_timer_) {
    image_timers_.erase(image_timer_);
    KillTimer(nullptr, image_timer_);
    image_timer_ = 0;
  }
  if (image_worker_) image_worker_->Shutdown();
  auto reply = std::move(image_result_);
  image_expected_sequence_ = 0;
  if (reply) {
    try {
      reply->Error("image_copy_cancelled", "Window closed before image copy completed");
    } catch (...) {
      // Shutdown must not throw through the window destructor.
    }
  }
}

std::shared_ptr<FlutterWindow::CaptureQueue> FlutterWindow::NewCaptureDelivery(int64_t generation) {
  std::weak_ptr<int> lifetime = capture_lifetime_;
  return CaptureQueue::Create(64, 160 * 1024 * 1024,
      [this, lifetime](CaptureQueue::Item item, CaptureQueue::Ack ack) {
        if (lifetime.expired() || !clipboard_channel_) {
          ack(false);
          return;
        }
        flutter::EncodableValue payload;
        if (item.overflow) {
          flutter::EncodableMap warning;
          warning[flutter::EncodableValue("captureDropped")] = flutter::EncodableValue(true);
          payload = flutter::EncodableValue(std::move(warning));
        } else {
          payload = std::move(*item.value);
        }
        auto response = std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
            [ack](const flutter::EncodableValue*) { ack(true); },
            [ack](const std::string&, const std::string&, const flutter::EncodableValue*) { ack(false); },
            [ack] { ack(false); });
        clipboard_channel_->InvokeMethod("changed",
            std::make_unique<flutter::EncodableValue>(std::move(payload)), std::move(response));
      }, [this, lifetime, generation] {
        if (lifetime.expired() || !clipboard_channel_) return;
        clipboard_channel_->InvokeMethod("captureFailed",
            std::make_unique<flutter::EncodableValue>(generation));
      });
}

void FlutterWindow::OnDestroy() {
  capture_lifetime_.reset();
  StopImageCopy();
  StopDibCapture();
  capture_delivery_.reset();
  clipboard_listener_.Stop([this] { return RemoveClipboardFormatListener(GetHandle()) != 0; });
  clipboard_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_DESTROY) StopImageCopy();
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_DESTROY:
      // The base handler clears GetHandle() before calling OnDestroy().
      clipboard_listener_.Stop([hwnd] {
        return RemoveClipboardFormatListener(hwnd) != 0;
      });
      break;
    case WM_CLIPBOARDUPDATE:
      if (clipboard_listener_.capture_enabled() && clipboard_channel_ &&
          capture_delivery_ && capture_delivery_->accepting()) {
        auto delivery = capture_delivery_;
        try {
          auto snapshot = ClipboardSnapshot(hwnd);
          if (snapshot && capture_delivery_) {
            AdmitCapture(std::move(*snapshot), delivery, dib_delivery_ != nullptr,
              [this] {
                if (!dib_worker_) dib_worker_ = std::make_unique<DibWorker>(PrepareClipboardDibCandidates);
                return dib_worker_ != nullptr;
              },
              [this, delivery](uint64_t slot, size_t weight, flutter::EncodableMap& map,
                               std::vector<std::vector<uint8_t>> dib) {
                const UINT_PTR timer = SetTimer(nullptr, 0, 20, DibTimerProc);
                bool started = false;
                if (timer) {
                  try {
                    if (dib_timers_.emplace(timer, this).second) {
                      started = dib_worker_->TryStart(std::move(dib)) == DibWorker::StartResult::started;
                    }
                  } catch (...) {
                    dib_timers_.erase(timer);
                    KillTimer(nullptr, timer);
                    delivery->FailQueue();
                    throw;
                  }
                }
                if (started) {
                  dib_timer_ = timer;
                  dib_slot_ = slot;
                  dib_base_weight_ = weight;
                  dib_snapshot_ = std::move(map);
                  dib_delivery_ = delivery;
                  return true;
                }
                if (timer) { dib_timers_.erase(timer); KillTimer(nullptr, timer); }
                return false;
              });
          }
        } catch (...) {
          delivery->FailQueue();
          OutputDebugStringA("NexaClip clipboard capture failed.\n");
        }
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
