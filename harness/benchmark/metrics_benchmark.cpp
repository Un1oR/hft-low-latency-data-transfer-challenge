#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <memory>
#include <string_view>

#include "metrics.h"

namespace {

uint64_t now_ns() {
  timespec time{};
  ::clock_gettime(CLOCK_MONOTONIC_RAW, &time);
  return static_cast<uint64_t>(time.tv_sec) * 1'000'000'000ull +
         static_cast<uint64_t>(time.tv_nsec);
}

uint64_t parse_count(int argc, char** argv) {
  if (argc == 1) return 2'000'000;
  if (argc != 3 || std::string_view(argv[1]) != "--count") {
    std::fprintf(stderr, "usage: metrics_benchmark [--count N]\n");
    std::exit(2);
  }
  char* end = nullptr;
  errno = 0;
  const auto count = std::strtoull(argv[2], &end, 10);
  if (errno != 0 || end == argv[2] || *end != '\0' || count == 0) {
    std::fprintf(stderr, "metrics_benchmark: invalid count: %s\n", argv[2]);
    std::exit(2);
  }
  return count;
}

}  // namespace

int main(int argc, char** argv) {
  const uint64_t count = parse_count(argc, argv);

  const uint64_t setup_start = now_ns();
  auto accumulator = std::make_unique<metrics::Accumulator>(count);
  const uint64_t setup_end = now_ns();

  const uint64_t record_start = now_ns();
  for (uint64_t seq = 1; seq <= count; ++seq) {
    accumulator->record(seq, 100 + seq % 1000);
  }
  const uint64_t record_end = now_ns();

  const auto& observations = accumulator->observations();
  const uint64_t checksum = observations.front().seq_id +
                            observations[count / 2].latency_ns +
                            observations.back().seq_id;
  std::printf(
      "metrics_benchmark: count=%llu setup=%.3f ms record=%.2f ns/observation checksum=%llu\n",
      static_cast<unsigned long long>(count),
      static_cast<double>(setup_end - setup_start) / 1'000'000.0,
      static_cast<double>(record_end - record_start) /
      static_cast<double>(count),
      static_cast<unsigned long long>(checksum));
  return 0;
}
