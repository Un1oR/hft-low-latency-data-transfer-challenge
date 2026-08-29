// Compact, self-contained market-data frames shared by the producer, transport
// and consumer. seq_id and send_ts_ns are the measurement contract; every
// other field is encoded once in its canonical integer representation.
#pragma once

#include <cstdint>

namespace msg {

inline constexpr uint32_t kBookDepth = 5;

enum class Type : uint8_t {
  Trade = 1,
  Bbo = 2,
  OrderBook = 3,
};

// Static reference data is negotiated outside the event stream. A frame carries
// its numeric instrument id instead of repeating names and currencies.
struct Instrument {
  const char* symbol;
  const char* venue;
  const char* base_currency;
  const char* quote_currency;
};

inline constexpr Instrument kInstruments[] = {
    {"BTCUSDT", "BINANCE", "BTC", "USDT"},
};
inline constexpr uint16_t kInstrumentCount =
    static_cast<uint16_t>(sizeof(kInstruments) / sizeof(kInstruments[0]));

inline constexpr double kPriceTickSize = 0.01;
inline constexpr double kQuantityLotSize = 0.001;

inline constexpr uint8_t kFlagAggressorSell = 1u << 0;
inline constexpr uint8_t kFlagBlockTrade = 1u << 1;
inline constexpr uint8_t kFlagRpi = 1u << 2;
inline constexpr uint8_t kFlagLiquidation = 1u << 3;
inline constexpr uint8_t kFlagSnapshot = 1u << 4;
inline constexpr uint8_t kTickDirectionShift = 5;
inline constexpr uint8_t kTickDirectionMask = 0x3u << kTickDirectionShift;

struct Header {
  uint64_t seq_id;
  uint64_t send_ts_ns;
  uint16_t instrument;
  uint8_t type;
  uint8_t flags;
  int32_t exchange_ts_delta_ns;
  int32_t match_engine_ts_delta_ns;
  uint32_t reserved;
};
static_assert(sizeof(Header) == 32);

struct alignas(8) Trade {
  Header header;
  int64_t price_ticks;
  int64_t quantity_lots;
  uint64_t trade_id;
  // A lost trade is visible in seq_id. These absolute running totals let the
  // receiver recover volume, notional and count on the next trade.
  uint64_t cumulative_quantity_lots;
  uint64_t cumulative_notional_ticks;
  uint64_t cumulative_trade_count;
};
static_assert(sizeof(Trade) == 80);

struct alignas(8) Bbo {
  Header header;
  uint64_t update_id;
  int64_t bid_price_ticks;
  int32_t spread_ticks;
  int32_t bid_size_lots;
  int32_t ask_size_lots;
  uint16_t bid_order_count;
  uint16_t ask_order_count;
};
static_assert(sizeof(Bbo) == 64);

struct BookSide {
  int64_t top_price_ticks;
  int32_t price_offset_ticks[kBookDepth - 1];
  int32_t size_lots[kBookDepth];
  uint16_t order_count[kBookDepth];
  uint16_t reserved;
};
static_assert(sizeof(BookSide) == 56);

struct alignas(8) OrderBook {
  Header header;
  uint64_t update_id;
  uint16_t previous_update_gap;
  uint16_t reserved;
  uint32_t checksum;
  BookSide bids;
  BookSide asks;
};
static_assert(sizeof(OrderBook) == 160);

inline constexpr uint32_t kMaxFrame = sizeof(OrderBook);

inline constexpr uint32_t frame_size(uint8_t type) {
  switch (static_cast<Type>(type)) {
    case Type::Trade:
      return sizeof(Trade);
    case Type::Bbo:
      return sizeof(Bbo);
    case Type::OrderBook:
      return sizeof(OrderBook);
  }
  return 0;
}

inline uint64_t exchange_ts_ns(const Header& header) {
  return header.send_ts_ns -
         static_cast<uint64_t>(header.exchange_ts_delta_ns);
}

inline uint64_t match_engine_ts_ns(const Header& header) {
  return exchange_ts_ns(header) -
         static_cast<uint64_t>(header.match_engine_ts_delta_ns);
}

}  // namespace msg
