#include "../runner/clipboard_listener_state.h"
#include <iostream>

#define CHECK(condition) do { if (!(condition)) { std::cerr << "Failed at line " << __LINE__ << '\n'; return 1; } } while (false)

int main() {
  ClipboardListenerState state;
  int adds = 0, removes = 0;
  auto add = [&] { ++adds; return true; };
  bool enabled_during_remove = false;
  auto remove_failure = [&] {
    ++removes;
    enabled_during_remove = state.capture_enabled();
    return false;
  };
  auto remove_success = [&] { ++removes; return true; };
  CHECK(!state.Start([&] { ++adds; return false; }));
  CHECK(!state.capture_enabled());
  CHECK(state.Start(add));
  CHECK(state.capture_enabled());
  CHECK(!state.Stop(remove_failure));
  CHECK(!enabled_during_remove);
  CHECK(!state.capture_enabled());
  CHECK(state.Start(add));
  CHECK(adds == 2);
  CHECK(state.capture_enabled());
  CHECK(state.Stop(remove_success));
  CHECK(!state.capture_enabled());
  CHECK(state.Stop(remove_success));
  CHECK(removes == 2);
  CHECK(state.Start(add));
  CHECK(!state.Stop(remove_failure));
  CHECK(state.Stop(remove_success));
  CHECK(!state.capture_enabled());
  CHECK(removes == 4);
  CHECK(state.Start(add));
  CHECK(!state.Stop(remove_failure));
  state = ClipboardListenerState{};  // A new window needs a new registration.
  const int previous_adds = adds;
  CHECK(state.Start(add));
  CHECK(adds == previous_adds + 1);
  return 0;
}
