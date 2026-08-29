#include <array>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "message.h"

import spectral.wire;

namespace {

template <typename Frame>
Frame frame(std::uint64_t sequence, msg::Type type) {
  Frame value{};
  value.header.seq_id = sequence;
  value.header.type = static_cast<std::uint8_t>(type);
  return value;
}

void test_round_trip_mixed_batch() {
  std::array<std::uint8_t, spectral::wire::kDefaultDatagramBytes> bytes{};
  spectral::wire::Packer packer(bytes.data(), bytes.size());
  const auto trade = frame<msg::Trade>(1, msg::Type::Trade);
  const auto bbo = frame<msg::Bbo>(2, msg::Type::Bbo);
  const auto book = frame<msg::OrderBook>(3, msg::Type::OrderBook);

  packer.reset(17);
  assert(packer.has_room(sizeof(trade)));
  packer.add(&trade, sizeof(trade));
  packer.add(&bbo, sizeof(bbo));
  packer.add(&book, sizeof(book));
  std::uint32_t length = 0;
  packer.finish(1234, &length);

  spectral::wire::Walker walker;
  assert(walker.begin(bytes.data(), length));
  assert(walker.datagram_seq() == 17);
  assert(walker.frame_count() == 3);
  assert(walker.send_ts_ns() == 1234);

  const std::array<std::uint32_t, 3> expected_lengths = {
      sizeof(msg::Trade), sizeof(msg::Bbo), sizeof(msg::OrderBook)};
  for (std::size_t index = 0; index < expected_lengths.size(); ++index) {
    bool malformed = false;
    std::uint32_t frame_length = 0;
    const auto* value = walker.next(&frame_length, &malformed);
    assert(!malformed);
    assert(value != nullptr);
    assert(frame_length == expected_lengths[index]);
    msg::Header header{};
    std::memcpy(&header, value, sizeof(header));
    assert(header.seq_id == index + 1);
  }
  bool malformed = false;
  std::uint32_t frame_length = 0;
  assert(walker.next(&frame_length, &malformed) == nullptr);
  assert(!malformed);
}

void test_rejects_truncation_and_bad_count() {
  std::array<std::uint8_t, spectral::wire::kDefaultDatagramBytes> bytes{};
  spectral::wire::Packer packer(bytes.data(), bytes.size());
  const auto trade = frame<msg::Trade>(1, msg::Type::Trade);
  packer.reset(1);
  packer.add(&trade, sizeof(trade));
  std::uint32_t length = 0;
  packer.finish(0, &length);

  spectral::wire::Walker truncated;
  assert(!truncated.begin(bytes.data(), length - 1));

  auto header = spectral::wire::DatagramHeader{};
  std::memcpy(&header, bytes.data(), sizeof(header));
  ++header.frame_count;
  std::memcpy(bytes.data(), &header, sizeof(header));
  spectral::wire::Walker bad_count;
  assert(bad_count.begin(bytes.data(), length));
  bool malformed = false;
  std::uint32_t frame_length = 0;
  assert(bad_count.next(&frame_length, &malformed) != nullptr);
  assert(bad_count.next(&frame_length, &malformed) == nullptr);
  assert(malformed);
}

void test_minimal_llq_probe_expands_delivery_header() {
  static_assert(14 + 20 + 8 + sizeof(spectral::wire::DatagramHeader) +
                    spectral::wire::kMinimalFrameBytes ==
                94);
  static_assert(94 <= 96);

  auto trade = frame<msg::Trade>(41, msg::Type::Trade);
  trade.header.send_ts_ns = 123456;
  trade.header.instrument = 7;
  trade.header.flags = msg::kFlagAggressorSell;
  trade.header.exchange_ts_delta_ns = 4200;
  trade.price_ticks = 999;

  std::array<std::uint8_t, 128> bytes{};
  spectral::wire::encode_minimal_frame(
      &trade, bytes.data() + sizeof(spectral::wire::DatagramHeader));
  const auto header = spectral::wire::make_datagram_header(
      9, 1, spectral::wire::kMinimalFrameBytes, 654321,
      spectral::wire::kFlagMinimalFrames);
  std::memcpy(bytes.data(), &header, sizeof(header));

  spectral::wire::Walker walker;
  const auto datagram_length = static_cast<std::uint32_t>(
      sizeof(header) + spectral::wire::kMinimalFrameBytes);
  assert(walker.begin(bytes.data(), datagram_length));
  assert(walker.minimal_frames());
  assert(walker.datagram_seq() == 9);
  assert(walker.send_ts_ns() == 654321);

  bool malformed = false;
  std::uint32_t frame_length = 0;
  const auto* decoded = walker.next(&frame_length, &malformed);
  assert(decoded != nullptr);
  assert(!malformed);
  assert(frame_length == sizeof(msg::Trade));
  msg::Trade expanded{};
  std::memcpy(&expanded, decoded, sizeof(expanded));
  assert(expanded.header.seq_id == trade.header.seq_id);
  assert(expanded.header.send_ts_ns == trade.header.send_ts_ns);
  assert(expanded.header.instrument == trade.header.instrument);
  assert(expanded.header.type == trade.header.type);
  assert(expanded.header.flags == trade.header.flags);
  assert(expanded.header.exchange_ts_delta_ns == 0);
  assert(expanded.price_ticks == 0);
  assert(walker.next(&frame_length, &malformed) == nullptr);
  assert(!malformed);
}

void test_compact_wire_is_lossless_and_fits_wide_llq() {
  static_assert(spectral::wire::kCompactBboBytes == 60);
  static_assert(spectral::wire::kCompactTradeBytes == 76);
  static_assert(spectral::wire::kCompactOrderBookBytes == 150);
  static_assert(14 + 20 + 8 + sizeof(spectral::wire::DatagramHeader) +
                    spectral::wire::kCompactOrderBookBytes ==
                224);

  auto trade = frame<msg::Trade>(101, msg::Type::Trade);
  trade.header.send_ts_ns = 123456789;
  trade.header.instrument = 5;
  trade.header.flags = msg::kFlagAggressorSell;
  trade.header.exchange_ts_delta_ns = 4200;
  trade.header.match_engine_ts_delta_ns = 130;
  trade.price_ticks = 6500010;
  trade.quantity_lots = 77;
  trade.trade_id = 998877;
  trade.cumulative_quantity_lots = 1234;
  trade.cumulative_notional_ticks = 5678;
  trade.cumulative_trade_count = 90;

  auto bbo = frame<msg::Bbo>(102, msg::Type::Bbo);
  bbo.header.send_ts_ns = 987654321;
  bbo.update_id = 7654;
  bbo.bid_price_ticks = 6500000;
  bbo.spread_ticks = 100;
  bbo.bid_size_lots = 222;
  bbo.ask_size_lots = 333;
  bbo.bid_order_count = 4;
  bbo.ask_order_count = 6;

  auto book = frame<msg::OrderBook>(103, msg::Type::OrderBook);
  book.header.send_ts_ns = 111222333;
  book.header.flags = msg::kFlagSnapshot;
  book.update_id = 4567;
  book.previous_update_gap = 2;
  book.checksum = 0xaabbccdd;
  for (std::uint32_t index = 0; index < msg::kBookDepth; ++index) {
    book.bids.size_lots[index] = 1000 + index;
    book.asks.size_lots[index] = 2000 + index;
    book.bids.order_count[index] = 10 + index;
    book.asks.order_count[index] = 20 + index;
    if (index != 0) {
      book.bids.price_offset_ticks[index - 1] = -100 * index;
      book.asks.price_offset_ticks[index - 1] = 100 * index;
    }
  }
  book.bids.top_price_ticks = 6499900;
  book.asks.top_price_ticks = 6500100;

  std::array<std::uint8_t, spectral::wire::kDefaultDatagramBytes> bytes{};
  spectral::wire::Packer packer(bytes.data(), bytes.size());
  packer.reset(77, true);
  packer.add(&trade, sizeof(trade));
  packer.add(&bbo, sizeof(bbo));
  packer.add(&book, sizeof(book));
  std::uint32_t datagram_length = 0;
  packer.finish(555666, &datagram_length);
  assert(datagram_length == sizeof(spectral::wire::DatagramHeader) +
                                spectral::wire::kCompactTradeBytes +
                                spectral::wire::kCompactBboBytes +
                                spectral::wire::kCompactOrderBookBytes);

  spectral::wire::Walker walker;
  assert(walker.begin(bytes.data(), datagram_length));
  assert(walker.compact_frames());
  assert(walker.decoded_frames());
  const std::array<const void*, 3> expected = {&trade, &bbo, &book};
  const std::array<std::uint32_t, 3> expected_lengths = {
      sizeof(trade), sizeof(bbo), sizeof(book)};
  for (std::size_t index = 0; index < expected.size(); ++index) {
    bool malformed = false;
    std::uint32_t frame_length = 0;
    const auto* decoded = walker.next(&frame_length, &malformed);
    assert(decoded != nullptr);
    assert(!malformed);
    assert(frame_length == expected_lengths[index]);
    assert(std::memcmp(decoded, expected[index], frame_length) == 0);
  }
  bool malformed = false;
  std::uint32_t frame_length = 0;
  assert(walker.next(&frame_length, &malformed) == nullptr);
  assert(!malformed);
}

}  // namespace

int main() {
  static_assert(sizeof(msg::Trade) == 80);
  static_assert(sizeof(msg::Bbo) == 64);
  static_assert(sizeof(msg::OrderBook) == 160);
  test_round_trip_mixed_batch();
  test_rejects_truncation_and_bad_count();
  test_minimal_llq_probe_expands_delivery_header();
  test_compact_wire_is_lossless_and_fits_wide_llq();
  std::puts("ALL WIRE TESTS PASSED");
  return 0;
}
