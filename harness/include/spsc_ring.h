// Bounded SPSC queue used by the direct path.
//
// Unlike the broadcast snapshot ring, this queue never overwrites storage a
// reader may still be copying. The producer drops a new frame when the queue is
// full, so the payload can be ordinary memory. Per-slot generations transfer
// exclusive ownership without CAS or a shared hot cursor.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "message.h"

namespace shm::spsc {

inline constexpr size_t kCacheLine = 64;
inline constexpr uint32_t kFrameCap = msg::kMaxFrame;

struct alignas(kCacheLine) Header {
  uint32_t magic;
  uint32_t slot_count;
  uint64_t slot_size;
  std::atomic<uint32_t> reader_ready;
  alignas(kCacheLine) std::atomic<uint64_t> write_index;
  alignas(kCacheLine) std::atomic<uint64_t> read_index;
};

static_assert(offsetof(Header, write_index) == kCacheLine);
static_assert(offsetof(Header, read_index) == 2 * kCacheLine);
static_assert(sizeof(Header) == 3 * kCacheLine);

inline constexpr uint32_t kMagic = 0x53504335;  // "SPC5"

// Optional out-of-band timestamps for diagnostic runs. They live in the
// alignment padding after the largest frame, so the slot remains 256 bytes and
// the compact wire protocol is unchanged.
struct StageTimestamps {
  uint64_t transport_send_ts_ns;
  // Always CLOCK_REALTIME, like the producer and consumer timestamps.
  uint64_t transport_receive_ts_ns;
  // Optional ENA hardware RX timestamp converted from the local PHC to
  // CLOCK_REALTIME with a measured receiver-local calibration.
  uint64_t hardware_receive_realtime_ns;
  // CLOCK_REALTIME immediately after the rte_eth_rx_burst call which returned
  // this packet. All packets in the same DPDK burst share this timestamp.
  uint64_t dpdk_rx_burst_return_realtime_ns;
};
static_assert(sizeof(StageTimestamps) == 32);

inline __attribute__((always_inline)) void copy_frame(
    void* destination, const void* source, uint32_t len) {
  if (len == sizeof(msg::Trade)) {
    __builtin_memcpy(destination, source, sizeof(msg::Trade));
  } else if (len == sizeof(msg::Bbo)) {
    __builtin_memcpy(destination, source, sizeof(msg::Bbo));
  } else if (len == sizeof(msg::OrderBook)) {
    __builtin_memcpy(destination, source, sizeof(msg::OrderBook));
  } else {
    std::memcpy(destination, source, len);
  }
}

// Per-slot generation variant. A slot alternates between a producer-owned
// "free" generation and the following reader-owned "ready" generation. This
// avoids polling a single global write cursor while retaining plain payloads.
struct alignas(kCacheLine) SequenceSlot {
  std::atomic<uint64_t> sequence;
  uint32_t frame_len;
  alignas(kCacheLine) uint8_t frame[kFrameCap];
  StageTimestamps stage_timestamps;
};

static_assert(offsetof(SequenceSlot, frame) == kCacheLine);
static_assert(offsetof(SequenceSlot, stage_timestamps) ==
              kCacheLine + kFrameCap);
static_assert(sizeof(SequenceSlot) ==
              ((kCacheLine + kFrameCap + kCacheLine - 1) / kCacheLine) *
                  kCacheLine);

class SequenceRing {
 public:
  static size_t region_size(uint32_t slots) {
    return sizeof(Header) +
           static_cast<size_t>(slots) * sizeof(SequenceSlot);
  }

  void attach(void* base, uint32_t slots, bool init) {
    header_ = static_cast<Header*>(base);
    slots_ = reinterpret_cast<SequenceSlot*>(
        static_cast<uint8_t*>(base) + sizeof(Header));
    if (init) {
      header_->magic = kMagic;
      header_->slot_count = slots;
      header_->slot_size = sizeof(SequenceSlot);
      header_->reader_ready.store(0, std::memory_order_relaxed);
      header_->write_index.store(0, std::memory_order_relaxed);
      header_->read_index.store(0, std::memory_order_relaxed);
      for (uint64_t index = 0; index < slots; ++index) {
        slots_[index].sequence.store(index, std::memory_order_relaxed);
      }
    }
    mask_ = header_->slot_count - 1;
    next_write_index_ = header_->write_index.load(std::memory_order_relaxed);
    next_read_index_ = header_->read_index.load(std::memory_order_relaxed);
  }

  uint32_t slot_count() const { return header_->slot_count; }

  bool publish(const void* frame, uint32_t len) {
    uint8_t* destination = reserve();
    if (destination == nullptr) return false;
    copy_frame(destination, frame, len);
    publish_reserved(len);
    return true;
  }

  bool publish(const void* frame, uint32_t len,
               StageTimestamps stage_timestamps) {
    uint8_t* destination = reserve();
    if (destination == nullptr) return false;
    copy_frame(destination, frame, len);
    publish_reserved(len, stage_timestamps);
    return true;
  }

  // Reserve the next producer-owned slot so the caller can construct a frame
  // directly in shared memory. Exactly one publish_reserved() must follow a
  // successful reservation before reserve() is called again.
  uint8_t* reserve() {
    SequenceSlot& slot = slots_[next_write_index_ & mask_];
    if (slot.sequence.load(std::memory_order_acquire) != next_write_index_) {
      // A late reader may fast-forward over already published slots without
      // touching every per-slot generation. Its release-store of read_index
      // transfers ownership of that whole prefix to the producer.
      const uint64_t read_index =
          header_->read_index.load(std::memory_order_acquire);
      if (next_write_index_ - read_index >= slot_count()) return nullptr;
    }
    return slots_[next_write_index_ & mask_].frame;
  }

  void publish_reserved(uint32_t len) {
    SequenceSlot& slot = slots_[next_write_index_ & mask_];
    slot.frame_len = len;
    publish_slot(slot);
  }

  void publish_reserved(uint32_t len, StageTimestamps stage_timestamps) {
    SequenceSlot& slot = slots_[next_write_index_ & mask_];
    slot.frame_len = len;
    slot.stage_timestamps = stage_timestamps;
    publish_slot(slot);
  }

  StageTimestamps stage_timestamps(uint64_t read_index) const {
    return slots_[read_index & mask_].stage_timestamps;
  }

 private:
  void publish_slot(SequenceSlot& slot) {
    ++next_write_index_;
    slot.sequence.store(next_write_index_, std::memory_order_release);
    header_->write_index.store(next_write_index_, std::memory_order_release);
  }

 public:
  uint64_t live_edge() {
    const uint64_t edge =
        header_->write_index.load(std::memory_order_acquire);
    next_read_index_ = edge;
    header_->read_index.store(edge, std::memory_order_release);
    return edge;
  }

  void activate_reader() {
    header_->reader_ready.store(1, std::memory_order_release);
  }

  bool reader_ready() const {
    return header_->reader_ready.load(std::memory_order_acquire) != 0;
  }

  enum class FrameStatus { kOk, kEmpty, kLapped };

  FrameStatus read(uint64_t read_index, void* out, uint32_t* out_len,
                   uint64_t* resume_at) {
    const uint8_t* source = nullptr;
    const auto status = acquire(read_index, &source, out_len, resume_at);
    if (status != FrameStatus::kOk) return status;
    copy_frame(out, source, *out_len);
    return FrameStatus::kOk;
  }

  // The returned view remains immutable until commit(read_index). Keeping the
  // ownership transfer explicit makes the plain payload data-race-free.
  FrameStatus acquire(uint64_t read_index, const uint8_t** frame,
                      uint32_t* out_len, uint64_t* resume_at) {
    if (read_index != next_read_index_) next_read_index_ = read_index;
    SequenceSlot& slot = slots_[next_read_index_ & mask_];
    if (__builtin_expect(
            slot.sequence.load(std::memory_order_acquire) !=
                next_read_index_ + 1,
            true)) {
      return FrameStatus::kEmpty;
    }

    *frame = slot.frame;
    *out_len = slot.frame_len;
    *resume_at = next_read_index_;
    return FrameStatus::kOk;
  }

  void commit(uint64_t read_index) {
    SequenceSlot& slot = slots_[read_index & mask_];
    slot.sequence.store(read_index + slot_count(), std::memory_order_release);
    next_read_index_ = read_index + 1;
    header_->read_index.store(next_read_index_, std::memory_order_relaxed);
  }

 private:
  Header* header_ = nullptr;
  SequenceSlot* slots_ = nullptr;
  uint64_t mask_ = 0;
  uint64_t next_write_index_ = 0;
  uint64_t next_read_index_ = 0;
};

inline size_t sequence_region_size(uint32_t slots) {
  return SequenceRing::region_size(slots);
}

}  // namespace shm::spsc
