#include <pthread.h>
#include <sched.h>
#include <x86intrin.h>
#include <cpuid.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "message.h"
#include "metrics.h"
#include "shm_ring.h"
#include "spsc_ring.h"
#include "spsc_ring_variants.h"
#include "util.h"

namespace {

enum class Implementation {
  kSnapshot,
  kSpsc,
  kSequence,
  kSequenceView,
  kSequenceZeroCopy,
  kSpscZeroCopy,
  kSplitSequenceZeroCopy,
  kDenseSequenceZeroCopy,
};
enum class FrameKind { kTrade, kBook };
enum class ClockKind { kRealtime, kTsc, kFast };

struct Config {
  Implementation implementation = Implementation::kSnapshot;
  FrameKind frame_kind = FrameKind::kTrade;
  ClockKind clock_kind = ClockKind::kRealtime;
  uint32_t slots = 1024;
  uint64_t count = 500'000;
  uint64_t rate = 250'000;
  int producer_cpu = 4;
  int consumer_cpu = 7;
};

struct BoundaryStats {
  uint64_t count = 0;
  uint64_t p50 = 0;
  uint64_t p99 = 0;
  uint64_t maximum = 0;
};

BoundaryStats boundary_stats(
    const std::vector<metrics::Observation>& observations, uint32_t slots) {
  std::vector<uint64_t> latencies;
  latencies.reserve(observations.size() / slots + 1);
  for (const auto& observation : observations) {
    if (observation.seq_id > 1 && (observation.seq_id - 1) % slots == 0) {
      latencies.push_back(observation.latency_ns);
    }
  }
  if (latencies.empty()) return {};
  std::sort(latencies.begin(), latencies.end());
  const auto percentile = [&](size_t numerator, size_t denominator) {
    size_t rank =
        (latencies.size() * numerator + denominator - 1) / denominator;
    if (rank == 0) rank = 1;
    return latencies[rank - 1];
  };
  return {latencies.size(), percentile(50, 100), percentile(99, 100),
          latencies.back()};
}

[[noreturn]] void usage(const char* message) {
  std::fprintf(stderr, "ring_handoff_benchmark: %s\n", message);
  std::fprintf(stderr,
               "usage: ring_handoff_benchmark --impl "
               "snapshot|spsc|spsc-zero-copy|sequence|sequence-view|"
               "sequence-zero-copy|"
               "split-sequence-zero-copy|dense-sequence-zero-copy "
               "[--frame trade|book] [--slots N] [--count N] [--rate N] "
               "[--clock realtime|tsc|fast] [--producer-cpu N] "
               "[--consumer-cpu N]\n");
  std::exit(2);
}

uint64_t parse_u64(const std::string& value, const char* option) {
  char* end = nullptr;
  errno = 0;
  const auto parsed = std::strtoull(value.c_str(), &end, 10);
  if (errno != 0 || end == value.c_str() || *end != '\0') usage(option);
  return parsed;
}

Config parse_args(int argc, char** argv) {
  Config config;
  for (int index = 1; index < argc; ++index) {
    const std::string option = argv[index];
    auto next = [&]() -> std::string {
      if (index + 1 >= argc) usage("missing option value");
      return argv[++index];
    };
    if (option == "--impl") {
      const auto value = next();
      if (value == "snapshot") config.implementation = Implementation::kSnapshot;
      else if (value == "spsc") config.implementation = Implementation::kSpsc;
      else if (value == "spsc-zero-copy") {
        config.implementation = Implementation::kSpscZeroCopy;
      }
      else if (value == "sequence") {
        config.implementation = Implementation::kSequence;
      } else if (value == "sequence-view") {
        config.implementation = Implementation::kSequenceView;
      } else if (value == "sequence-zero-copy") {
        config.implementation = Implementation::kSequenceZeroCopy;
      } else if (value == "split-sequence-zero-copy") {
        config.implementation = Implementation::kSplitSequenceZeroCopy;
      } else if (value == "dense-sequence-zero-copy") {
        config.implementation = Implementation::kDenseSequenceZeroCopy;
      } else {
        usage("invalid --impl");
      }
    } else if (option == "--frame") {
      const auto value = next();
      if (value == "trade") config.frame_kind = FrameKind::kTrade;
      else if (value == "book") config.frame_kind = FrameKind::kBook;
      else usage("--frame must be trade or book");
    } else if (option == "--clock") {
      const auto value = next();
      if (value == "realtime") config.clock_kind = ClockKind::kRealtime;
      else if (value == "tsc") config.clock_kind = ClockKind::kTsc;
      else if (value == "fast") config.clock_kind = ClockKind::kFast;
      else usage("--clock must be realtime, tsc or fast");
    } else if (option == "--slots") {
      config.slots = static_cast<uint32_t>(parse_u64(next(), "invalid slots"));
    } else if (option == "--count") {
      config.count = parse_u64(next(), "invalid count");
    } else if (option == "--rate") {
      config.rate = parse_u64(next(), "invalid rate");
    } else if (option == "--producer-cpu") {
      config.producer_cpu = static_cast<int>(parse_u64(next(), "invalid CPU"));
    } else if (option == "--consumer-cpu") {
      config.consumer_cpu = static_cast<int>(parse_u64(next(), "invalid CPU"));
    } else {
      usage("unknown option");
    }
  }
  if (config.slots == 0 || (config.slots & (config.slots - 1)) != 0) {
    usage("--slots must be a power of two");
  }
  if (config.count == 0 || config.rate == 0) {
    usage("--count and --rate must be non-zero");
  }
  return config;
}

uint64_t tsc_frequency_hz() {
  unsigned int eax = 0;
  unsigned int ebx = 0;
  unsigned int ecx = 0;
  unsigned int edx = 0;
  if (__get_cpuid_count(0x15, 0, &eax, &ebx, &ecx, &edx) != 0 && eax != 0 &&
      ebx != 0 && ecx != 0) {
    return static_cast<uint64_t>(ecx) * ebx / eax;
  }
  if (__get_cpuid(0x16, &eax, &ebx, &ecx, &edx) != 0 && eax != 0) {
    return static_cast<uint64_t>(eax) * 1'000'000ull;
  }
  usage("CPUID does not expose a TSC frequency");
}

class FastClock {
 public:
  FastClock() : frequency_hz_(tsc_frequency_hz()) {
    unsigned int aux = 0;
    const uint64_t before = __rdtscp(&aux);
    base_ns_ = util::now_ns();
    const uint64_t after = __rdtscp(&aux);
    base_tsc_ = before + (after - before) / 2;
    multiplier_ = static_cast<uint64_t>(
        (static_cast<__uint128_t>(1'000'000'000ull) << kShift) /
        frequency_hz_);
  }

  uint64_t now_ns() const {
    unsigned int aux = 0;
    const uint64_t cycles = __rdtscp(&aux) - base_tsc_;
    return base_ns_ + static_cast<uint64_t>(
                          (static_cast<__uint128_t>(cycles) * multiplier_) >>
                          kShift);
  }

  uint64_t frequency_hz() const { return frequency_hz_; }

 private:
  static constexpr unsigned int kShift = 32;
  uint64_t frequency_hz_ = 0;
  uint64_t base_tsc_ = 0;
  uint64_t base_ns_ = 0;
  uint64_t multiplier_ = 0;
};

uint64_t read_measurement_clock(ClockKind clock_kind,
                                const FastClock& fast_clock) {
  if (clock_kind == ClockKind::kRealtime) return util::now_ns();
  if (clock_kind == ClockKind::kFast) return fast_clock.now_ns();
  unsigned int aux = 0;
  return __rdtscp(&aux);
}

void pin_to_cpu(int cpu) {
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  const int error = pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
  if (error != 0) {
    std::fprintf(stderr, "pthread_setaffinity_np(CPU %d) failed: %s\n", cpu,
                 std::strerror(error));
    std::exit(1);
  }
}

bool publish(shm::Ring& ring, const void* frame, uint32_t frame_size) {
  ring.publish(frame, frame_size);
  return true;
}

template <typename Ring>
bool publish(Ring& ring, const void* frame, uint32_t frame_size) {
  return ring.publish(frame, frame_size);
}

void commit(shm::Ring&, uint64_t) {}

template <typename Ring>
void commit(Ring& ring, uint64_t read_index) {
  ring.commit(read_index);
}

template <typename Ring, bool ReaderView = false, bool WriterView = false>
metrics::Report run(const Config& config, size_t region_size,
                    uint64_t* published_out, uint64_t* rejected_out,
                    uint64_t* lapped_out, BoundaryStats* boundaries_out) {
  void* memory = nullptr;
  if (posix_memalign(&memory, 64, region_size) != 0) {
    usage("allocation failed");
  }
  std::memset(memory, 0, region_size);

  Ring writer;
  writer.attach(memory, config.slots, /*init=*/true);
  Ring reader;
  reader.attach(memory, config.slots, /*init=*/false);

  std::atomic<bool> reader_ready{false};
  std::atomic<bool> producer_done{false};
  std::atomic<uint64_t> published{0};
  const FastClock fast_clock;
  uint64_t rejected = 0;
  uint64_t lapped = 0;
  BoundaryStats boundaries;
  metrics::Report report;

  std::thread consumer([&] {
    pin_to_cpu(config.consumer_cpu);
    metrics::Accumulator accumulator(config.count);
    alignas(64) uint8_t frame[shm::kFrameCap];
    uint64_t read_index = reader.live_edge();
    uint64_t received = 0;
    reader_ready.store(true, std::memory_order_release);

    for (;;) {
      uint32_t frame_size = 0;
      uint64_t resume_at = 0;
      const uint8_t* source = frame;
      typename Ring::FrameStatus status;
      if constexpr (ReaderView) {
        status = reader.acquire(read_index, &source, &frame_size, &resume_at);
      } else {
        status = reader.read(read_index, frame, &frame_size, &resume_at);
      }
      if (status == Ring::FrameStatus::kOk) {
        const uint64_t receive_timestamp =
            read_measurement_clock(config.clock_kind, fast_clock);
        const auto* header = reinterpret_cast<const msg::Header*>(source);
        accumulator.record(header->seq_id,
                           receive_timestamp - header->send_ts_ns);
        commit(reader, read_index);
        ++read_index;
        ++received;
      } else if (status == Ring::FrameStatus::kLapped) {
        ++lapped;
        read_index = resume_at;
      } else if (producer_done.load(std::memory_order_acquire) &&
                 received >= published.load(std::memory_order_relaxed)) {
        break;
      }
    }
    boundaries = boundary_stats(accumulator.observations(), config.slots);
    report = accumulator.report();
  });

  std::thread producer([&] {
    pin_to_cpu(config.producer_cpu);
    while (!reader_ready.load(std::memory_order_acquire)) {
      std::this_thread::yield();
    }

    alignas(64) uint8_t frame[shm::kFrameCap]{};
    const uint32_t frame_size = config.frame_kind == FrameKind::kTrade
                                    ? sizeof(msg::Trade)
                                    : sizeof(msg::OrderBook);
    auto* header = reinterpret_cast<msg::Header*>(frame);
    header->type = config.frame_kind == FrameKind::kTrade
                       ? static_cast<uint16_t>(msg::Type::Trade)
                       : static_cast<uint16_t>(msg::Type::OrderBook);
    header->version = 1;
    header->body_len = frame_size;

    const uint64_t interval_ns = 1'000'000'000ull / config.rate;
    uint64_t next_send = util::now_ns();
    uint64_t accepted = 0;
    for (uint64_t sequence_id = 1; sequence_id <= config.count;
         ++sequence_id) {
      while (util::now_ns() < next_send) {
      }
      next_send += interval_ns;
      if constexpr (WriterView) {
        uint8_t* destination = writer.reserve();
        if (destination == nullptr) {
          ++rejected;
          continue;
        }
        auto* destination_header =
            reinterpret_cast<msg::Header*>(destination);
        destination_header->seq_id = sequence_id;
        destination_header->type = header->type;
        destination_header->version = header->version;
        destination_header->body_len = frame_size;
        destination_header->send_ts_ns =
            read_measurement_clock(config.clock_kind, fast_clock);
        writer.publish_reserved(frame_size);
        ++accepted;
      } else {
        header->seq_id = sequence_id;
        header->send_ts_ns =
            read_measurement_clock(config.clock_kind, fast_clock);
        if (publish(writer, frame, frame_size)) ++accepted;
        else ++rejected;
      }
    }
    published.store(accepted, std::memory_order_relaxed);
    producer_done.store(true, std::memory_order_release);
  });

  producer.join();
  consumer.join();
  *published_out = published.load(std::memory_order_relaxed);
  *rejected_out = rejected;
  *lapped_out = lapped;
  *boundaries_out = boundaries;
  if (config.clock_kind == ClockKind::kFast) {
    std::printf("ring_handoff: tsc_frequency_hz=%llu\n",
                static_cast<unsigned long long>(fast_clock.frequency_hz()));
  }
  std::free(memory);
  return report;
}

}  // namespace

int main(int argc, char** argv) {
  const Config config = parse_args(argc, argv);
  uint64_t published = 0;
  uint64_t rejected = 0;
  uint64_t lapped = 0;
  BoundaryStats boundaries;
  metrics::Report report;
  const char* implementation = nullptr;
  if (config.implementation == Implementation::kSnapshot) {
    implementation = "snapshot";
    report = run<shm::Ring>(config, shm::region_size(config.slots), &published,
                            &rejected, &lapped, &boundaries);
  } else if (config.implementation == Implementation::kSpsc) {
    implementation = "spsc";
    report = run<shm::spsc::experimental::CursorRing>(
        config, shm::spsc::experimental::cursor_region_size(config.slots),
                                  &published, &rejected, &lapped,
                                  &boundaries);
  } else if (config.implementation == Implementation::kSpscZeroCopy) {
    implementation = "spsc-zero-copy";
    report = run<shm::spsc::experimental::CursorRing, true, true>(
        config, shm::spsc::experimental::cursor_region_size(config.slots),
        &published, &rejected, &lapped, &boundaries);
  } else if (config.implementation == Implementation::kSequence) {
    implementation = "sequence";
    report = run<shm::spsc::SequenceRing>(
        config, shm::spsc::sequence_region_size(config.slots), &published,
        &rejected, &lapped, &boundaries);
  } else if (config.implementation == Implementation::kSequenceView) {
    implementation = "sequence-view";
    report = run<shm::spsc::SequenceRing, true>(
        config, shm::spsc::sequence_region_size(config.slots), &published,
        &rejected, &lapped, &boundaries);
  } else if (config.implementation == Implementation::kSequenceZeroCopy) {
    implementation = "sequence-zero-copy";
    report = run<shm::spsc::SequenceRing, true, true>(
        config, shm::spsc::sequence_region_size(config.slots), &published,
        &rejected, &lapped, &boundaries);
  } else if (config.implementation == Implementation::kSplitSequenceZeroCopy) {
    implementation = "split-sequence-zero-copy";
    report = run<shm::spsc::experimental::SplitPaddedSequenceRing, true, true>(
        config, shm::spsc::experimental::split_padded_region_size(config.slots),
        &published, &rejected, &lapped, &boundaries);
  } else if (config.implementation == Implementation::kDenseSequenceZeroCopy) {
    implementation = "dense-sequence-zero-copy";
    report = run<shm::spsc::experimental::SplitDenseSequenceRing, true, true>(
        config, shm::spsc::experimental::split_dense_region_size(config.slots),
        &published, &rejected, &lapped, &boundaries);
  } else {
    usage("unhandled implementation");
  }

  std::printf(
      "ring_handoff: impl=%s frame=%s clock=%s slots=%u count=%llu published=%llu "
      "rejected=%llu lapped=%llu\n",
      implementation, config.frame_kind == FrameKind::kTrade ? "trade" : "book",
      config.clock_kind == ClockKind::kRealtime
          ? "realtime"
          : (config.clock_kind == ClockKind::kTsc ? "tsc" : "fast"),
      config.slots, static_cast<unsigned long long>(config.count),
      static_cast<unsigned long long>(published),
      static_cast<unsigned long long>(rejected),
      static_cast<unsigned long long>(lapped));
  std::printf(
      "ring_handoff: latency_%s min=%llu mean=%.0f p50=%llu p99=%llu "
      "p99.9=%llu p99.99=%llu max=%llu dropped=%llu\n",
      config.clock_kind == ClockKind::kTsc ? "cycles" : "ns",
      static_cast<unsigned long long>(report.lat_min), report.lat_mean,
      static_cast<unsigned long long>(report.p50),
      static_cast<unsigned long long>(report.p99),
      static_cast<unsigned long long>(report.p999),
      static_cast<unsigned long long>(report.p9999),
      static_cast<unsigned long long>(report.lat_max),
      static_cast<unsigned long long>(report.dropped));
  std::printf(
      "ring_handoff: boundary count=%llu p50=%llu p99=%llu max=%llu\n",
      static_cast<unsigned long long>(boundaries.count),
      static_cast<unsigned long long>(boundaries.p50),
      static_cast<unsigned long long>(boundaries.p99),
      static_cast<unsigned long long>(boundaries.maximum));
  return rejected == 0 && report.dropped == 0 ? 0 : 1;
}
