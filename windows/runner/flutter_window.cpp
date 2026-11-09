#include "flutter_window.h"

#include <limits>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {
// Called while the clipboard is open. An unreadable history marker is treated
// as private rather than accidentally persisting sensitive data.
bool ClipboardAllowsHistory() {
  const UINT exclude = RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
  const UINT history = RegisterClipboardFormatW(L"CanIncludeInClipboardHistory");
  if (!exclude || !history || IsClipboardFormatAvailable(exclude)) return false;
  if (!IsClipboardFormatAvailable(history)) return true;
  HANDLE handle = GetClipboardData(history);
  if (!handle || GlobalSize(handle) < sizeof(DWORD)) return false;
  auto value = static_cast<const DWORD*>(GlobalLock(handle));
  if (!value) return false;
  const bool allowed = *value != 0;
  GlobalUnlock(handle);
  return allowed;
}

std::optional<std::string> ClipboardTextSnapshot(HWND hwnd) {
  if (!OpenClipboard(hwnd)) return std::nullopt;
  std::optional<std::string> text;
  if (ClipboardAllowsHistory() && IsClipboardFormatAvailable(CF_UNICODETEXT)) {
    HANDLE data = GetClipboardData(CF_UNICODETEXT);
    if (data) {
      const SIZE_T size = GlobalSize(data) / sizeof(wchar_t);
      auto chars = static_cast<const wchar_t*>(GlobalLock(data));
      if (chars) {
        size_t length = 0;
        while (length < size && chars[length] != L'\0') ++length;
        if (length > 0 && length < size &&
            length <= static_cast<size_t>((std::numeric_limits<int>::max)())) {
          const int input_length = static_cast<int>(length);
          const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                                chars, input_length, nullptr, 0,
                                                nullptr, nullptr);
          if (bytes > 0) {
            std::string copy(bytes, '\0');
            if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, chars,
                                    input_length, copy.data(), bytes, nullptr,
                                    nullptr) == bytes) {
              text = std::move(copy);
            }
          }
        }
        GlobalUnlock(data);
      }
    }
  }
  CloseClipboard();
  return text;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  // Create() destroys the previous HWND before invoking OnCreate(). A listener
  // registration belongs to that HWND and cannot be reused by this one.
  clipboard_listener_ = ClipboardListenerState{};
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
          if (!clipboard_listener_.Start([this] { return AddClipboardFormatListener(GetHandle()) != 0; })) {
            result->Error("listener_failed", "Unable to register clipboard listener");
            return;
          }
          result->Success();
        } else if (call.method_name() == "stop") {
          if (!clipboard_listener_.Stop([this] { return RemoveClipboardFormatListener(GetHandle()) != 0; })) {
            result->Error("listener_failed", "Unable to remove clipboard listener");
            return;
          }
          result->Success();
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

void FlutterWindow::OnDestroy() {
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
      if (clipboard_listener_.capture_enabled() && clipboard_channel_) {
        const auto text = ClipboardTextSnapshot(hwnd);
        if (text) {
          clipboard_channel_->InvokeMethod(
              "changed", std::make_unique<flutter::EncodableValue>(*text));
        }
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
