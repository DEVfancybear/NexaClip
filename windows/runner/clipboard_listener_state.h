#ifndef RUNNER_CLIPBOARD_LISTENER_STATE_H_
#define RUNNER_CLIPBOARD_LISTENER_STATE_H_

class ClipboardListenerState {
 public:
  template <typename Add>
  bool Start(Add add) {
    if (!listening_ && !add()) return false;
    listening_ = true;
    capture_enabled_ = true;
    return true;
  }

  template <typename Remove>
  bool Stop(Remove remove) {
    capture_enabled_ = false;
    if (listening_ && !remove()) return false;
    listening_ = false;
    return true;
  }

  bool capture_enabled() const { return capture_enabled_; }

 private:
  bool listening_ = false;
  bool capture_enabled_ = false;
};

#endif  // RUNNER_CLIPBOARD_LISTENER_STATE_H_
