// Producer: generates a stream of market-data events (trade, BBO, or order-book
// snapshots), stamping each with a monotonic sequence id and a send timestamp,
// and publishes them into a shared-memory broadcast ring for one or more
// consumers. Fixed end of the benchmark harness -- a candidate replaces the
// transport, not this.
//
// Usage: producer [--shm NAME] [--slots N] [--count N] [--rate MSGS_PER_SEC]
//                 [--type trade|bbo|book|mixed]
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

#include "message.h"
#include "shm_segment.h"
#include "spsc_ring.h"
#include "spsc_ring_variants.h"
#include "util.h"

namespace {

enum class Kind { Trade, Bbo, Book, Mixed };
enum class RingKind { Sequence, Cursor, SplitSequence, DenseSequence };

struct Config {
  std::string shm_name = "/fanout_ring";
  uint32_t slots = 1024;
  uint64_t count = 1000000;
  double rate = 0.0;
  Kind kind = Kind::Mixed;
  RingKind ring_kind = RingKind::Sequence;
  bool wait_for_reader = false;
};

bool is_power_of_two(uint32_t x) { return x != 0 && (x & (x - 1)) == 0; }

Kind parse_kind(const std::string& s) {
  if (s == "trade") return Kind::Trade;
  if (s == "bbo") return Kind::Bbo;
  if (s == "book") return Kind::Book;
  if (s == "mixed") return Kind::Mixed;
  fprintf(stderr, "--type must be trade|bbo|book|mixed (got %s)\n", s.c_str());
  std::exit(2);
}

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
    else if (a == "--rate") c.rate = std::stod(next());
    else if (a == "--type") c.kind = parse_kind(next());
    else if (a == "--ring") c.ring_kind = parse_ring_kind(next());
    else if (a == "--wait-for-reader") c.wait_for_reader = true;
    else {
      fprintf(stderr, "unknown arg: %s\n", a.c_str());
      std::exit(2);
    }
  }
  if (!is_power_of_two(c.slots)) {
    fprintf(stderr, "--slots must be a power of two (got %u)\n", c.slots);
    std::exit(2);
  }
  return c;
}

struct TradeTotals {
  uint64_t quantity_lots = 0;
  uint64_t notional_ticks = 0;
  uint64_t trade_count = 0;
};

inline constexpr int32_t kExchangeLagNs = 4200;
inline constexpr int32_t kMatchEngineLagNs = 130;

void fill_header(msg::Header& h, uint64_t seq, msg::Type type, uint8_t flags) {
  h.seq_id = seq;
  h.instrument = 0;
  h.type = static_cast<uint8_t>(type);
  h.flags = flags;
  h.exchange_ts_delta_ns = kExchangeLagNs;
  h.match_engine_ts_delta_ns = kMatchEngineLagNs;
  h.reserved = 0;
  h.send_ts_ns = util::now_ns();  // stamp as late as possible before publish
}

uint32_t build_trade(void* buf, uint64_t seq, TradeTotals* totals) {
  auto& m = *reinterpret_cast<msg::Trade*>(buf);
  m.trade_id = 100000 + seq;
  m.price_ticks = 6500000 + static_cast<int64_t>(seq % 500) * 50;
  m.quantity_lots = 1 + static_cast<int64_t>(seq % 100) * 10;
  m.cumulative_quantity_lots = totals->quantity_lots;
  m.cumulative_notional_ticks = totals->notional_ticks;
  m.cumulative_trade_count = totals->trade_count;

  uint8_t flags = static_cast<uint8_t>((seq % 4) <<
                                       msg::kTickDirectionShift);
  if ((seq & 1) != 0) flags |= msg::kFlagAggressorSell;
  fill_header(m.header, seq, msg::Type::Trade, flags);
  return sizeof(msg::Trade);
}

uint32_t build_bbo(void* buf, uint64_t seq) {
  auto& m = *reinterpret_cast<msg::Bbo*>(buf);
  m.update_id = 900000 + seq;
  const int64_t mid_ticks =
      6500000 + static_cast<int64_t>(seq % 500) * 50;
  m.bid_price_ticks = mid_ticks - 50;
  m.spread_ticks = 100;
  m.bid_size_lots = static_cast<int32_t>(1500 + (seq % 50) * 100);
  m.ask_size_lots =
      static_cast<int32_t>(1500 + ((seq + 7) % 50) * 100);
  m.bid_order_count = static_cast<uint16_t>(3 + seq % 10);
  m.ask_order_count = static_cast<uint16_t>(3 + (seq + 3) % 10);
  fill_header(m.header, seq, msg::Type::Bbo, 0);
  return sizeof(msg::Bbo);
}

uint32_t build_book(void* buf, uint64_t seq) {
  auto& m = *reinterpret_cast<msg::OrderBook*>(buf);
  m.update_id = 900000 + seq;
  m.previous_update_gap = 1;
  m.reserved = 0;
  const int64_t mid_ticks =
      6500000 + static_cast<int64_t>(seq % 500) * 50;
  m.bids.top_price_ticks = mid_ticks - 50;
  m.asks.top_price_ticks = mid_ticks + 50;
  m.bids.reserved = 0;
  m.asks.reserved = 0;
  for (uint32_t i = 0; i < msg::kBookDepth; ++i) {
    if (i > 0) {
      m.bids.price_offset_ticks[i - 1] = -static_cast<int32_t>(i) * 100;
      m.asks.price_offset_ticks[i - 1] = static_cast<int32_t>(i) * 100;
    }
    m.bids.size_lots[i] =
        static_cast<int32_t>(1000 + ((seq + i) % 40) * 100);
    m.bids.order_count[i] =
        static_cast<uint16_t>(2 + (seq + i) % 8);
    m.asks.size_lots[i] =
        static_cast<int32_t>(1000 + ((seq + i + 5) % 40) * 100);
    m.asks.order_count[i] =
        static_cast<uint16_t>(2 + (seq + i + 5) % 8);
  }
  m.checksum = static_cast<uint32_t>(seq * 2654435761u);
  fill_header(m.header, seq, msg::Type::OrderBook, msg::kFlagSnapshot);
  return sizeof(msg::OrderBook);
}

uint32_t build(Kind kind, uint64_t seq, void* buf, TradeTotals* totals) {
  Kind k = kind;
  if (k == Kind::Mixed) {
    switch (seq % 3) {
      case 0: k = Kind::Trade; break;
      case 1: k = Kind::Bbo; break;
      default: k = Kind::Book; break;
    }
  }
  switch (k) {
    case Kind::Trade: return build_trade(buf, seq, totals);
    case Kind::Bbo: return build_bbo(buf, seq);
    default: return build_book(buf, seq);
  }
}

Kind resolved_kind(Kind kind, uint64_t seq) {
  if (kind != Kind::Mixed) return kind;
  switch (seq % 3) {
    case 0:
      return Kind::Trade;
    case 1:
      return Kind::Bbo;
    default:
      return Kind::Book;
  }
}

void account_event(Kind kind, uint64_t seq, TradeTotals* totals) {
  if (resolved_kind(kind, seq) != Kind::Trade) return;
  const auto price_ticks =
      6500000 + static_cast<uint64_t>(seq % 500) * 50;
  const auto quantity_lots = 1 + static_cast<uint64_t>(seq % 100) * 10;
  totals->quantity_lots += quantity_lots;
  totals->notional_ticks += price_ticks * quantity_lots;
  ++totals->trade_count;
}

const char* kind_name(Kind k) {
  switch (k) {
    case Kind::Trade: return "trade";
    case Kind::Bbo: return "bbo";
    case Kind::Book: return "book";
    default: return "mixed";
  }
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

template <typename Ring>
size_t ring_region_size(uint32_t slots) {
  return Ring::region_size(slots);
}

template <typename Ring>
int run(const Config& cfg) {
  shm::Segment seg = shm::Segment::open(
      cfg.shm_name, ring_region_size<Ring>(cfg.slots), /*create=*/true);
  Ring ring;
  ring.attach(seg.base(), cfg.slots, /*init=*/true);

  const uint64_t interval_ns =
      cfg.rate > 0.0 ? static_cast<uint64_t>(1e9 / cfg.rate) : 0;

  fprintf(stderr,
          "producer: shm=%s slots=%u count=%llu rate=%.0f type=%s ring=%s\n",
          cfg.shm_name.c_str(), cfg.slots,
          static_cast<unsigned long long>(cfg.count), cfg.rate,
          kind_name(cfg.kind), ring_name(cfg.ring_kind));

  if (cfg.wait_for_reader) {
    while (!ring.reader_ready()) {
    }
  }

  uint64_t next_send = util::now_ns();

  uint64_t seq = 0;
  uint64_t dropped = 0;
  TradeTotals totals;
  while (cfg.count == 0 || seq < cfg.count) {
    if (interval_ns) {
      while (util::now_ns() < next_send) {
      }
      next_send += interval_ns;
    }
    ++seq;
    account_event(cfg.kind, seq, &totals);
    uint8_t* frame = ring.reserve();
    if (frame == nullptr) {
      ++dropped;
      continue;
    }
    const uint32_t len = build(cfg.kind, seq, frame, &totals);
    ring.publish_reserved(len);
  }

  fprintf(stderr, "producer: generated %llu messages, queue-dropped %llu\n",
          static_cast<unsigned long long>(seq),
          static_cast<unsigned long long>(dropped));
  seg.unlink();
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
