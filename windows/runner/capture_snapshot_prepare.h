#pragma once

#include <flutter/encodable_value.h>
#include <cstdint>
#include <string>
#include <vector>

struct PreparedCaptureSnapshot {
  size_t weight = 64;
  size_t dib_bytes = 0;
  std::vector<std::vector<uint8_t>> dib;
};

inline PreparedCaptureSnapshot PrepareCaptureSnapshot(flutter::EncodableMap& map) {
  PreparedCaptureSnapshot result;
  const auto text = map.find(flutter::EncodableValue("text"));
  if (text != map.end()) {
    if (const auto* value = std::get_if<std::string>(&text->second))
      result.weight += value->size();
  }
  const auto png = map.find(flutter::EncodableValue("png"));
  if (png != map.end()) {
    if (const auto* value = std::get_if<std::vector<uint8_t>>(&png->second))
      result.weight += value->size();
  }
  for (const char* key : {"_dibV5", "_dib"}) {
    auto it = map.find(flutter::EncodableValue(key));
    if (it == map.end()) continue;
    auto bytes = std::move(std::get<std::vector<uint8_t>>(it->second));
    result.dib_bytes += bytes.size();
    result.dib.push_back(std::move(bytes));
    map.erase(it);
  }
  return result;
}
