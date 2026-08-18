// Consumer: reads events from the shared-memory broadcast ring, stamps a receive
// timestamp, and computes delivery metrics (latency percentiles, drop rate) from
// the per-message send timestamp and sequence id. Fixed measurement end of the
// harness.
//
// Usage: consumer [--shm NAME] [--slots N] [--count N] [--from-edge]
//                 [--csv FILE] [--idle-ms MS]
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "message.h"
#include "metrics.h"
#include "shm_segment.h"
#include "spsc_ring.h"
#include "spsc_ring_variants.h"
#include "util.h"

namespace {

enum class RingKind { Sequence, Cursor, SplitSequence, DenseSequence };

struct Config {
  std::string shm_name = "/fanout_ring";
  uint32_t slots = 1024;
  uint64_t count = 0;
  bool from_edge = false;
  std::string csv;
  uint64_t idle_ms = 2000;
  RingKind ring_kind = RingKind::Sequence;
};

RingKind parse_ring_kind(const std::string& value) {
  if (value == "sequence") return RingKind::Sequence;
  if (value == "cursor") return RingKind::Cursor;
  if (value == "split-sequence") return RingKind::SplitSequence;
  if (value == "dense-sequence") return RingKind::DenseSequence;
  fprintf(stderr,
          "--ring must be sequence|cursor|split-sequence|dense-sequence "
          "(got %s)\n",
          value.c_str());
  std::exit(2);
}

const char* ring_name(RingKind kind) {
  switch (kind) {
    case RingKind::Sequence: return "sequence";
    case RingKind::Cursor: return "cursor";
    case RingKind::SplitSequence: return "split-sequence";
    case RingKind::DenseSequence: return "dense-sequence";
  }
  return "unknown";
}

Config parse_args(int argc, char** argv) {
  Config c;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&]() -> std::string {
      if (i + 1 >= argc) {
        fprintf(stderr, "missing value for %s\n", a.c_str());
        std::exit(2);
      }
      return argv[++i];
    };
    if (a == "--shm") c.shm_name = next();
    else if (a == "--slots") c.slots = static_cast<uint32_t>(std::stoul(next()));
    else if (a == "--count") c.count = std::stoull(next());
    else if (a == "--from-edge") c.from_edge = true;
    else if (a == "--csv") c.csv = next();
    else if (a == "--idle-ms") c.idle_ms = std::stoull(next());
    else if (a == "--ring") c.ring_kind = parse_ring_kind(next());
    else {
      fprintf(stderr, "unknown arg: %s\n", a.c_str());
      std::exit(2);
    }
  }
  return c;
}

void print_report(const metrics::Report& r) {
  printf("---- delivery metrics ----\n");
  printf("received     : %llu\n", (unsigned long long)r.received);
  printf("expected     : %llu\n", (unsigned long long)r.expected);
  printf("dropped      : %llu\n", (unsigned long long)r.dropped);
  printf("drop_rate    : %.4f%%\n", r.drop_rate * 100.0);
  printf("latency (ns) : min=%llu mean=%.0f max=%llu\n",
         (unsigned long long)r.lat_min, r.lat_mean,
         (unsigned long long)r.lat_max);
  printf("  p01        : %llu\n", (unsigned long long)r.p01);
  printf("  p50        : %llu\n", (unsigned long long)r.p50);
  printf("  p99        : %llu\n", (unsigned long long)r.p99);
  printf("  p99.9      : %llu\n", (unsigned long long)r.p999);
  printf("  p99.99     : %llu\n", (unsigned long long)r.p9999);
}

bool write_csv(const std::string& path,
               const std::vector<metrics::Observation>& observations) {
  FILE* csv = std::fopen(path.c_str(), "w");
  if (!csv) {
    std::fprintf(stderr, "fopen(%s) failed: %s\n", path.c_str(),
                 std::strerror(errno));
    return false;
  }

  bool ok = std::fprintf(csv, "seq,latency_ns\n") >= 0;
  for (const auto& observation : observations) {
    if (std::fprintf(csv, "%llu,%llu\n",
                     (unsigned long long)observation.seq_id,
                     (unsigned long long)observation.latency_ns) < 0) {
      ok = false;
      break;
    }
  }
  if (std::fclose(csv) != 0) ok = false;
  if (!ok) {
    std::fprintf(stderr, "failed to write CSV %s: %s\n", path.c_str(),
                 std::strerror(errno));
  }
  return ok;
}

template <typename Ring>
size_t ring_region_size(uint32_t slots) {
  return Ring::region_size(slots);
}

template <typename Ring>
int run(const Config& cfg) {
  shm::Segment seg = shm::Segment::open(
      cfg.shm_name, ring_region_size<Ring>(cfg.slots), /*create=*/false);
  Ring ring;
  ring.attach(seg.base(), cfg.slots, /*init=*/false);

  metrics::Accumulator acc(cfg.count ? cfg.count : 1u << 20);

  uint64_t read_index = cfg.from_edge ? ring.live_edge() : 0;
  uint64_t received = 0;
  uint64_t lapped_events = 0;
  const uint64_t idle_ns = cfg.idle_ms * 1000000ull;
  uint64_t last_progress = util::now_ns();

  ring.activate_reader();

  fprintf(stderr, "consumer: ring=%s slots=%u count=%llu\n",
          ring_name(cfg.ring_kind), cfg.slots,
          static_cast<unsigned long long>(cfg.count));

  while (cfg.count == 0 || received < cfg.count) {
    const uint8_t* frame = nullptr;
    uint32_t len = 0;
    uint64_t resume = 0;
    const auto status = ring.acquire(read_index, &frame, &len, &resume);

    if (status == Ring::FrameStatus::kOk) {
      const uint64_t recv_ts = util::now_ns();
      const auto* hdr = reinterpret_cast<const msg::Header*>(frame);
      const uint64_t latency =
          recv_ts > hdr->send_ts_ns ? recv_ts - hdr->send_ts_ns : 0;
      acc.record(hdr->seq_id, latency);
      ring.commit(read_index);
      ++received;
      ++read_index;
      last_progress = recv_ts;
    } else if (status == Ring::FrameStatus::kLapped) {
      ++lapped_events;
      read_index = resume;
    } else {
      if (util::now_ns() - last_progress > idle_ns) break;
    }
  }

  fprintf(stderr, "consumer: lapped %llu times\n",
          (unsigned long long)lapped_events);
  print_report(acc.report());
  if (!cfg.csv.empty() && !write_csv(cfg.csv, acc.observations())) return 1;
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  const Config cfg = parse_args(argc, argv);
  if (cfg.ring_kind == RingKind::Cursor) {
    return run<shm::spsc::experimental::CursorRing>(cfg);
  }
  if (cfg.ring_kind == RingKind::SplitSequence) {
    return run<shm::spsc::experimental::SplitPaddedSequenceRing>(cfg);
  }
  if (cfg.ring_kind == RingKind::DenseSequence) {
    return run<shm::spsc::experimental::SplitDenseSequenceRing>(cfg);
  }
  return run<shm::spsc::SequenceRing>(cfg);
}
