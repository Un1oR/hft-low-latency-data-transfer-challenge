#pragma once

#include <cstdint>
#include <ctime>

namespace util {

inline uint64_t now_ns() {
  timespec time{};
  ::clock_gettime(CLOCK_REALTIME, &time);
  return static_cast<uint64_t>(time.tv_sec) * 1'000'000'000ull +
         static_cast<uint64_t>(time.tv_nsec);
}

}  // namespace util
