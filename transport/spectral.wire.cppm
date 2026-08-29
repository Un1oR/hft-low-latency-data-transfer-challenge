module;

#include <cstdint>
#include <cstddef>
#include <cstring>

#include "message.h"

export module spectral.wire;

import std;

export namespace spectral::wire {

inline constexpr std::uint32_t kMagic = 0x53505731;  // "SPW1"
inline constexpr std::uint8_t kVersion = 1;
inline constexpr std::uint8_t kFlagMinimalFrames = 1u << 0;
inline constexpr std::uint8_t kFlagCompactFrames = 1u << 1;
inline constexpr std::uint32_t kDefaultDatagramBytes = 1472;
inline constexpr std::uint32_t kMaxDatagramBytes = 8973;
// Diagnostic-only representation used to test whether fitting an entire
// Ethernet frame into ENA's ordinary 96-byte LLQ changes latency.  It retains
// only the fields needed by the delivery harness and deliberately discards
// market-data payload semantics.
inline constexpr std::uint32_t kMinimalFrameBytes = 20;

// Lossless wire representation of the current in-memory messages.  Only the
// explicitly reserved bytes are omitted; the receiver reconstructs the same
// msg::* object with those bytes zeroed.  Keep this as an explicit codec rather
// than changing the SPSC ABI or relying on packed C++ structure layout.
inline constexpr std::uint32_t kCompactHeaderBytes = 28;
inline constexpr std::uint32_t kCompactTradeBytes = 76;
inline constexpr std::uint32_t kCompactBboBytes = 60;
inline constexpr std::uint32_t kCompactBookSideBytes = 54;
inline constexpr std::uint32_t kCompactOrderBookBytes = 150;

static_assert(offsetof(msg::Header, reserved) == kCompactHeaderBytes);
static_assert(offsetof(msg::Trade, price_ticks) == sizeof(msg::Header));
static_assert(offsetof(msg::Bbo, update_id) == sizeof(msg::Header));
static_assert(offsetof(msg::OrderBook, update_id) == sizeof(msg::Header));
static_assert(offsetof(msg::OrderBook, checksum) == 44);
static_assert(offsetof(msg::OrderBook, bids) == 48);
static_assert(offsetof(msg::OrderBook, asks) == 104);
static_assert(offsetof(msg::BookSide, reserved) == kCompactBookSideBytes);

struct DatagramHeader {
  std::uint32_t magic;
  std::uint8_t version;
  std::uint8_t flags;
  std::uint16_t frame_count;
  std::uint32_t payload_len;
  std::uint32_t reserved;
  std::uint64_t datagram_seq;
  std::uint64_t send_ts_ns;
};
static_assert(sizeof(DatagramHeader) == 32);

inline constexpr std::uint32_t kMinDatagramBytes =
    sizeof(DatagramHeader) + msg::kMaxFrame;
inline constexpr std::uint16_t kMaxFramesPerDatagram =
    (kMaxDatagramBytes - sizeof(DatagramHeader)) / kCompactBboBytes;

inline auto make_datagram_header(std::uint64_t datagram_seq,
                                 std::uint16_t frame_count,
                                 std::uint32_t payload_len,
                                 std::uint64_t send_ts_ns,
                                 std::uint8_t flags = 0)
    -> DatagramHeader {
  return DatagramHeader{
      .magic = kMagic,
      .version = kVersion,
      .flags = flags,
      .frame_count = frame_count,
      .payload_len = payload_len,
      .reserved = 0,
      .datagram_seq = datagram_seq,
      .send_ts_ns = send_ts_ns,
  };
}

inline constexpr auto compact_frame_size(std::uint8_t type)
    -> std::uint32_t {
  switch (static_cast<msg::Type>(type)) {
    case msg::Type::Trade:
      return kCompactTradeBytes;
    case msg::Type::Bbo:
      return kCompactBboBytes;
    case msg::Type::OrderBook:
      return kCompactOrderBookBytes;
  }
  return 0;
}

inline constexpr auto compact_frame_size_from_native(
    std::uint32_t native_size) -> std::uint32_t {
  switch (native_size) {
    case sizeof(msg::Trade):
      return kCompactTradeBytes;
    case sizeof(msg::Bbo):
      return kCompactBboBytes;
    case sizeof(msg::OrderBook):
      return kCompactOrderBookBytes;
    default:
      return 0;
  }
}

inline void encode_compact_frame(const void* frame, std::uint32_t frame_len,
                                 std::uint8_t* output) {
  const auto* input = static_cast<const std::uint8_t*>(frame);
  std::memcpy(output, input, kCompactHeaderBytes);
  if (frame_len == sizeof(msg::Trade) || frame_len == sizeof(msg::Bbo)) {
    std::memcpy(output + kCompactHeaderBytes, input + sizeof(msg::Header),
                frame_len - sizeof(msg::Header));
    return;
  }
  if (frame_len != sizeof(msg::OrderBook)) return;

  std::uint32_t write_offset = kCompactHeaderBytes;
  // update_id + previous_update_gap; skip OrderBook::reserved.
  std::memcpy(output + write_offset, input + 32, 10);
  write_offset += 10;
  std::memcpy(output + write_offset, input + 44, sizeof(std::uint32_t));
  write_offset += sizeof(std::uint32_t);
  // Each side is copied through order_count; its trailing reserved is omitted.
  std::memcpy(output + write_offset, input + 48, kCompactBookSideBytes);
  write_offset += kCompactBookSideBytes;
  std::memcpy(output + write_offset, input + 104, kCompactBookSideBytes);
}

inline void decode_compact_frame(const std::uint8_t* input,
                                 std::uint32_t wire_len, void* frame,
                                 std::uint32_t frame_len) {
  auto* output = static_cast<std::uint8_t*>(frame);
  std::memset(output, 0, frame_len);
  std::memcpy(output, input, kCompactHeaderBytes);
  if (frame_len == sizeof(msg::Trade) || frame_len == sizeof(msg::Bbo)) {
    std::memcpy(output + sizeof(msg::Header), input + kCompactHeaderBytes,
                wire_len - kCompactHeaderBytes);
    return;
  }
  if (frame_len != sizeof(msg::OrderBook)) return;

  std::uint32_t read_offset = kCompactHeaderBytes;
  std::memcpy(output + 32, input + read_offset, 10);
  read_offset += 10;
  std::memcpy(output + 44, input + read_offset, sizeof(std::uint32_t));
  read_offset += sizeof(std::uint32_t);
  std::memcpy(output + 48, input + read_offset, kCompactBookSideBytes);
  read_offset += kCompactBookSideBytes;
  std::memcpy(output + 104, input + read_offset, kCompactBookSideBytes);
}

inline void encode_minimal_frame(const void* frame, std::uint8_t* output) {
  msg::Header header{};
  std::memcpy(&header, frame, sizeof(header));
  std::memcpy(output, &header.seq_id, sizeof(header.seq_id));
  std::memcpy(output + 8, &header.send_ts_ns, sizeof(header.send_ts_ns));
  std::memcpy(output + 16, &header.instrument, sizeof(header.instrument));
  output[18] = header.type;
  output[19] = header.flags;
}

inline void decode_minimal_frame(const std::uint8_t* input, void* frame,
                                 std::uint32_t frame_len) {
  auto* output = static_cast<std::uint8_t*>(frame);
  std::memset(output, 0, frame_len);
  auto* header = reinterpret_cast<msg::Header*>(output);
  std::memcpy(&header->seq_id, input, sizeof(header->seq_id));
  std::memcpy(&header->send_ts_ns, input + 8, sizeof(header->send_ts_ns));
  std::memcpy(&header->instrument, input + 16, sizeof(header->instrument));
  header->type = input[18];
  header->flags = input[19];
}

class Packer {
 public:
  Packer(std::uint8_t* buffer, std::uint32_t capacity)
      : buffer_(buffer), capacity_(capacity) {}

  void reset(std::uint64_t datagram_seq, bool compact_frames = false) {
    length_ = sizeof(DatagramHeader);
    frame_count_ = 0;
    datagram_seq_ = datagram_seq;
    compact_frames_ = compact_frames;
  }

  [[nodiscard]] bool empty() const { return frame_count_ == 0; }
  [[nodiscard]] std::uint16_t frame_count() const { return frame_count_; }
  [[nodiscard]] bool has_room(std::uint32_t frame_len) const {
    const auto wire_len = compact_frames_
                              ? compact_frame_size_from_native(frame_len)
                              : frame_len;
    return wire_len != 0 && length_ + wire_len <= capacity_;
  }

  void add(const void* frame, std::uint32_t frame_len) {
    if (compact_frames_) {
      const auto wire_len = compact_frame_size_from_native(frame_len);
      encode_compact_frame(frame, frame_len, buffer_ + length_);
      length_ += wire_len;
      ++frame_count_;
      return;
    }
    if (frame_len == sizeof(msg::Bbo)) {
      __builtin_memcpy(buffer_ + length_, frame, sizeof(msg::Bbo));
    } else if (frame_len == sizeof(msg::Trade)) {
      __builtin_memcpy(buffer_ + length_, frame, sizeof(msg::Trade));
    } else if (frame_len == sizeof(msg::OrderBook)) {
      __builtin_memcpy(buffer_ + length_, frame, sizeof(msg::OrderBook));
    } else {
      std::memcpy(buffer_ + length_, frame, frame_len);
    }
    length_ += frame_len;
    ++frame_count_;
  }

  std::uint8_t* finish(std::uint64_t send_ts_ns, std::uint32_t* out_len) {
    const auto header = make_datagram_header(
        datagram_seq_, frame_count_,
        static_cast<std::uint32_t>(length_ - sizeof(DatagramHeader)),
        send_ts_ns, compact_frames_ ? kFlagCompactFrames : 0);
    std::memcpy(buffer_, &header, sizeof(header));
    *out_len = length_;
    return buffer_;
  }

 private:
  std::uint8_t* buffer_;
  std::uint32_t capacity_;
  std::uint32_t length_ = sizeof(DatagramHeader);
  std::uint16_t frame_count_ = 0;
  std::uint64_t datagram_seq_ = 0;
  bool compact_frames_ = false;
};

class Walker {
 public:
  bool begin(const std::uint8_t* datagram, std::uint32_t length) {
    if (length < sizeof(DatagramHeader)) return false;
    std::memcpy(&header_, datagram, sizeof(header_));
    if (header_.magic != kMagic || header_.version != kVersion ||
        (header_.flags & ~(kFlagMinimalFrames | kFlagCompactFrames)) != 0 ||
        (header_.flags & (kFlagMinimalFrames | kFlagCompactFrames)) ==
            (kFlagMinimalFrames | kFlagCompactFrames) ||
        header_.frame_count == 0 ||
        header_.payload_len != length - sizeof(DatagramHeader)) {
      return false;
    }
    payload_ = datagram + sizeof(DatagramHeader);
    payload_len_ = header_.payload_len;
    offset_ = 0;
    seen_ = 0;
    return true;
  }

  [[nodiscard]] std::uint64_t datagram_seq() const {
    return header_.datagram_seq;
  }
  [[nodiscard]] std::uint16_t frame_count() const {
    return header_.frame_count;
  }
  [[nodiscard]] std::uint64_t send_ts_ns() const {
    return header_.send_ts_ns;
  }
  [[nodiscard]] bool minimal_frames() const {
    return (header_.flags & kFlagMinimalFrames) != 0;
  }
  [[nodiscard]] bool compact_frames() const {
    return (header_.flags & kFlagCompactFrames) != 0;
  }
  [[nodiscard]] bool decoded_frames() const {
    return minimal_frames() || compact_frames();
  }

  const std::uint8_t* next_wire(std::uint32_t* out_len,
                                std::uint32_t* out_wire_len,
                                bool* malformed) {
    *malformed = false;
    if (offset_ == payload_len_) {
      if (seen_ != header_.frame_count) *malformed = true;
      return nullptr;
    }
    msg::Header header{};
    if (minimal_frames()) {
      if (offset_ + kMinimalFrameBytes > payload_len_) {
        *malformed = true;
        return nullptr;
      }
      std::memcpy(&header.seq_id, payload_ + offset_, sizeof(header.seq_id));
      std::memcpy(&header.send_ts_ns, payload_ + offset_ + 8,
                  sizeof(header.send_ts_ns));
      std::memcpy(&header.instrument, payload_ + offset_ + 16,
                  sizeof(header.instrument));
      header.type = payload_[offset_ + 18];
      header.flags = payload_[offset_ + 19];
    } else if (compact_frames()) {
      if (offset_ + kCompactHeaderBytes > payload_len_) {
        *malformed = true;
        return nullptr;
      }
      std::memcpy(&header, payload_ + offset_, kCompactHeaderBytes);
    } else {
      if (offset_ + sizeof(msg::Header) > payload_len_) {
        *malformed = true;
        return nullptr;
      }
      std::memcpy(&header, payload_ + offset_, sizeof(header));
    }
    const auto frame_len = msg::frame_size(header.type);
    const auto wire_frame_len =
        minimal_frames() ? kMinimalFrameBytes
                         : (compact_frames() ? compact_frame_size(header.type)
                                             : frame_len);
    if (frame_len == 0 || offset_ + wire_frame_len > payload_len_ ||
        seen_ >= header_.frame_count) {
      *malformed = true;
      return nullptr;
    }

    const std::uint8_t* frame = payload_ + offset_;
    offset_ += wire_frame_len;
    ++seen_;
    *out_len = frame_len;
    *out_wire_len = wire_frame_len;
    return frame;
  }

  const std::uint8_t* next(std::uint32_t* out_len, bool* malformed) {
    std::uint32_t wire_len = 0;
    const auto* wire_frame = next_wire(out_len, &wire_len, malformed);
    if (wire_frame == nullptr) return nullptr;
    if (minimal_frames()) {
      decode_minimal_frame(wire_frame, decoded_frame_.data(), *out_len);
      return decoded_frame_.data();
    }
    if (compact_frames()) {
      decode_compact_frame(wire_frame, wire_len, decoded_frame_.data(),
                           *out_len);
      return decoded_frame_.data();
    }
    return wire_frame;
  }

 private:
  DatagramHeader header_{};
  const std::uint8_t* payload_ = nullptr;
  std::uint32_t payload_len_ = 0;
  std::uint32_t offset_ = 0;
  std::uint16_t seen_ = 0;
  alignas(8) std::array<std::uint8_t, msg::kMaxFrame> decoded_frame_{};
};

}  // namespace spectral::wire
