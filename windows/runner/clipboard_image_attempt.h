#pragma once

#include <new>
#include <utility>

// Image capture is optional: an allocation failure must not suppress text.
template <typename Capture>
void AttemptClipboardImage(Capture&& capture) {
  try {
    std::forward<Capture>(capture)();
  } catch (const std::bad_alloc&) {
  }
}
