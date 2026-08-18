#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <limits>
#include <string>

#include "message.h"
#include "shm_ring.h"

namespace {

struct Config {
  uint32_t slots = 1024;
  uint64_t rounds = 2000;
};

[[noreturn]] void usage(const char* message) {
  std::fprintf(stderr, "ring_benchmark: %s\n", message);
  std::exit(2);
}

uint64_t parse_u64(const char* value, const char* option) {
  char* end = nullptr;
  errno = 0;
  const auto parsed = std::strtoull(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0') {
    std::fprintf(stderr, "ring_benchmark: invalid %s: %s\n", option, value);
    std::exit(2);
  }
  return parsed;
}

Config parse_args(int argc, char** argv) {
  Config config;
  for (int index = 1; index < argc; ++index) {
    const std::string option = argv[index];
    if (index + 1 >= argc) usage("missing option value");
    const char* value = argv[++index];
    if (option == "--slots") {
      const auto parsed = parse_u64(value, "--slots");
      if (parsed == 0 || parsed > std::numeric_limits<uint32_t>::max()) {
        usage("--slots is out of range");
      }
      config.slots = static_cast<uint32_t>(parsed);
    } else if (option == "--rounds") {
      config.rounds = parse_u64(value, "--rounds");
      if (config.rounds == 0) usage("--rounds must be positive");
    } else {
      usage("unknown option");
    }
  }
  if ((config.slots & (config.slots - 1)) != 0) {
    usage("--slots must be a power of two");
  }
  return config;
}

uint64_t now_ns() {
  timespec time{};
  ::clock_gettime(CLOCK_MONOTONIC_RAW, &time);
  return static_cast<uint64_t>(time.tv_sec) * 1'000'000'000ull +
         static_cast<uint64_t>(time.tv_nsec);
}

struct Result {
  double publish_ns;
  double read_ns;
  uint64_t checksum;
};

Result run_case(void* memory, uint32_t slots, uint64_t rounds,
                uint32_t frame_size) {
  shm::Ring ring;
  ring.attach(memory, slots, /*init=*/true);

  alignas(shm::kCacheLine) uint8_t input[shm::kFrameCap]{};
  alignas(shm::kCacheLine) uint8_t output[shm::kFrameCap]{};
  for (uint32_t index = 0; index < frame_size; ++index) {
    input[index] = static_cast<uint8_t>(index * 37u + frame_size);
  }

  constexpr uint64_t kWarmupRounds = 8;
  uint64_t read_index = 0;
  uint64_t publish_ns = 0;
  uint64_t read_ns = 0;
  uint64_t checksum = 0;
  const uint64_t total_rounds = rounds + kWarmupRounds;

  for (uint64_t round = 0; round < total_rounds; ++round) {
    const uint64_t publish_start = now_ns();
    for (uint32_t index = 0; index < slots; ++index) {
      ring.publish(input, frame_size);
    }
    const uint64_t publish_end = now_ns();

    const uint64_t read_start = now_ns();
    for (uint32_t index = 0; index < slots; ++index) {
      uint32_t length = 0;
      uint64_t resume_at = 0;
      const auto status = ring.read(read_index, output, &length, &resume_at);
      if (status != shm::Ring::FrameStatus::kOk || length != frame_size) {
        std::fprintf(stderr,
                     "ring_benchmark: read failed at index %llu (status=%u, resume=%llu)\n",
                     static_cast<unsigned long long>(read_index),
                     static_cast<unsigned>(status),
                     static_cast<unsigned long long>(resume_at));
        std::exit(1);
      }
      checksum += output[(read_index + frame_size) % frame_size];
      ++read_index;
    }
    const uint64_t read_end = now_ns();

    if (round >= kWarmupRounds) {
      publish_ns += publish_end - publish_start;
      read_ns += read_end - read_start;
    }
  }

  const auto operations = static_cast<double>(slots) * rounds;
  return {static_cast<double>(publish_ns) / operations,
          static_cast<double>(read_ns) / operations, checksum};
}

void print_case(const char* name, uint32_t size, const Result& result) {
  std::printf("%-10s size=%3u publish=%7.2f ns read=%7.2f ns checksum=%llu\n",
              name, size, result.publish_ns, result.read_ns,
              static_cast<unsigned long long>(result.checksum));
}

}  // namespace

int main(int argc, char** argv) {
  const auto config = parse_args(argc, argv);
  const size_t bytes = shm::region_size(config.slots);
  void* memory = nullptr;
  if (posix_memalign(&memory, shm::kCacheLine, bytes) != 0) {
    std::fprintf(stderr, "ring_benchmark: allocation failed\n");
    return 1;
  }
  std::memset(memory, 0, bytes);

  std::printf("ring_benchmark: slots=%u rounds=%llu operations/case=%llu\n",
              config.slots, static_cast<unsigned long long>(config.rounds),
              static_cast<unsigned long long>(config.rounds * config.slots));
  print_case("trade", sizeof(msg::Trade),
             run_case(memory, config.slots, config.rounds, sizeof(msg::Trade)));
  print_case("bbo", sizeof(msg::Bbo),
             run_case(memory, config.slots, config.rounds, sizeof(msg::Bbo)));
  print_case("book", sizeof(msg::OrderBook),
             run_case(memory, config.slots, config.rounds,
                      sizeof(msg::OrderBook)));

  std::free(memory);
  return 0;
}
