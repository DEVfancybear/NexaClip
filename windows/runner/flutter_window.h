#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <map>
#include <memory>

#include "win32_window.h"
#include "clipboard_listener_state.h"
#include "capture_delivery.h"
#include "image_prepare.h"
#include "single_job_worker.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> clipboard_channel_;
  ClipboardListenerState clipboard_listener_;
  using CaptureQueue = CaptureDelivery<flutter::EncodableValue>;
  std::shared_ptr<CaptureQueue> capture_delivery_;
  std::shared_ptr<int> capture_lifetime_;
  using DibWorker = SingleJobWorker<std::vector<std::vector<uint8_t>>, std::optional<std::vector<uint8_t>>>;
  std::unique_ptr<DibWorker> dib_worker_;
  std::shared_ptr<CaptureQueue> dib_delivery_;
  flutter::EncodableMap dib_snapshot_;
  uint64_t dib_slot_ = 0;
  size_t dib_base_weight_ = 0;
  UINT_PTR dib_timer_ = 0;
  static thread_local std::map<UINT_PTR, FlutterWindow*> dib_timers_;
  static void CALLBACK DibTimerProc(HWND, UINT, UINT_PTR, DWORD);
  void PollDibCapture();
  void StopDibCapture();
  using ImageWorker = SingleJobWorker<ImageCopyJob,
                                      std::optional<PreparedClipboardImage>>;
  std::unique_ptr<ImageWorker> image_worker_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> image_result_;
  UINT_PTR image_timer_ = 0;
  DWORD image_expected_sequence_ = 0;
  static thread_local std::map<UINT_PTR, FlutterWindow*> image_timers_;
  static void CALLBACK ImageTimerProc(HWND, UINT, UINT_PTR, DWORD);
  void PollImageCopy(HWND hwnd);
  void StopImageCopy();
  std::shared_ptr<CaptureQueue> NewCaptureDelivery(int64_t generation);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
