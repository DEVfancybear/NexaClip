#ifndef RUNNER_START_WITH_CLEANUP_H_
#define RUNNER_START_WITH_CLEANUP_H_

#include <utility>

// The caller owns a registered resource until start succeeds. On failure or an
// exception, release it before returning or propagating the exception.
template <typename Start, typename Cleanup>
bool StartWithCleanup(Start&& start, Cleanup&& cleanup) {
  try {
    if (std::forward<Start>(start)()) return true;
  } catch (...) {
    std::forward<Cleanup>(cleanup)();
    throw;
  }
  std::forward<Cleanup>(cleanup)();
  return false;
}

#endif  // RUNNER_START_WITH_CLEANUP_H_
