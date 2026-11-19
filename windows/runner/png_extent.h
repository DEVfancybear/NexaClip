#ifndef RUNNER_PNG_EXTENT_H_
#define RUNNER_PNG_EXTENT_H_

#include <cstddef>
#include <cstdint>
#include <optional>

// Finds the end of a complete PNG chunk stream, excluding allocation padding.
// This does not validate CRCs or decode the image.
inline std::optional<size_t> PngExtent(const uint8_t* data, size_t size) {
  constexpr uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
  if (!data || size < sizeof(signature)) return std::nullopt;
  for (size_t i = 0; i < sizeof(signature); ++i) {
    if (data[i] != signature[i]) return std::nullopt;
  }
  size_t pos = sizeof(signature);
  while (size - pos >= 12) {
    const uint32_t length = (uint32_t(data[pos]) << 24) |
                            (uint32_t(data[pos + 1]) << 16) |
                            (uint32_t(data[pos + 2]) << 8) | data[pos + 3];
    if (length > size - pos - 12) return std::nullopt;
    const bool end = data[pos + 4] == 'I' && data[pos + 5] == 'E' &&
                     data[pos + 6] == 'N' && data[pos + 7] == 'D';
    pos += size_t(length) + 12;
    if (end) return length == 0 ? std::optional<size_t>(pos) : std::nullopt;
  }
  return std::nullopt;
}

#endif  // RUNNER_PNG_EXTENT_H_
