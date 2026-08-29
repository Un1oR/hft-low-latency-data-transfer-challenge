// Shared-memory broadcast ring buffer (single producer, one or more readers).
//
// The producer never blocks on a reader: once the ring is full it overwrites
// the oldest slot. A reader that falls too far behind is "lapped" -- it detects
// the overwrite via the per-slot sequence number and skips ahead. That is the
// drop mechanism, modelling the 0.1-1% loss the task assumes on the channel.
//
// A slot is invalidated before reuse and published with a release-store of its
// sequence. Payload words are lock-free atomics, so a reader overlapping an
// overwrite can reject the snapshot without a C++ data race. No locks or
// syscalls are used on the hot path.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "message.h"

namespace shm {

inline constexpr uint32_t kFrameCap = msg::kMaxFrame;
inline constexpr size_t kFrameWordSize = sizeof(uint64_t);
inline constexpr size_t kFrameWordCount =
    (kFrameCap + kFrameWordSize - 1) / kFrameWordSize;

// Fixed because the layout is shared by binaries built with different standard
// libraries; std::hardware_destructive_interference_size is implementation-defined.
inline constexpr size_t kCacheLine = 64;

// In-memory layout shared by the independently built harness and transport
// binaries. A layout change bumps kMagic and requires a matching binary set.
inline constexpr size_t kHeaderWriteIndexOffset = 64;
inline constexpr size_t kHeaderSize = 128;
inline constexpr size_t kSlotFrameOffset = kCacheLine;
inline constexpr size_t kSlotSize =
    ((kSlotFrameOffset + kFrameWordCount * kFrameWordSize + kCacheLine - 1) /
     kCacheLine) *
    kCacheLine;

struct alignas(kCacheLine) Slot {
  // Publication sequence for this slot; 0 means "never written". The producer
  // writes the frame, then release-stores seq = write_index + 1.
  std::atomic<uint64_t> seq;
  std::atomic<uint32_t> frame_len;
  alignas(kCacheLine) std::atomic<uint64_t> frame[kFrameWordCount];
};

struct alignas(kCacheLine) Header {
  uint32_t magic;
  uint32_t slot_count;  // power of two
  uint64_t slot_size;
  alignas(kCacheLine) std::atomic<uint64_t> write_index;
};

static_assert(sizeof(std::atomic<uint64_t>) == sizeof(uint64_t));
static_assert(alignof(std::atomic<uint64_t>) == alignof(uint64_t));
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(sizeof(std::atomic<uint32_t>) == sizeof(uint32_t));
static_assert(std::atomic<uint32_t>::is_always_lock_free);
static_assert(offsetof(Header, write_index) == kHeaderWriteIndexOffset);
static_assert(sizeof(Header) == kHeaderSize);
static_assert(offsetof(Slot, frame) == kSlotFrameOffset);
static_assert(sizeof(Slot) == kSlotSize);

inline constexpr uint32_t kMagic = 0x53484d34;  // "SHM4"

inline size_t region_size(uint32_t slots) {
  return sizeof(Header) + static_cast<size_t>(slots) * sizeof(Slot);
}

// A thin view over an already-mapped region; does not own the mapping.
template <void (*AfterPayloadWrite)() = nullptr>
class TRing {
 public:
  TRing() = default;

  // Producer passes init=true to (re)initialise the header; readers pass false.
  void attach(void* base, uint32_t slots, bool init) {
    header_ = static_cast<Header*>(base);
    slots_ = reinterpret_cast<Slot*>(static_cast<uint8_t*>(base) +
                                     sizeof(Header));
    if (init) {
      header_->magic = kMagic;
      header_->slot_count = slots;
      header_->slot_size = sizeof(Slot);
      header_->write_index.store(0, std::memory_order_relaxed);
      for (uint32_t i = 0; i < slots; ++i) {
        slots_[i].seq.store(0, std::memory_order_relaxed);
        slots_[i].frame_len.store(0, std::memory_order_relaxed);
      }
    }
    mask_ = header_->slot_count - 1;
    next_write_index_ = header_->write_index.load(std::memory_order_relaxed);
  }

  uint32_t slot_count() const { return header_->slot_count; }

  void publish(const void* frame, uint32_t len) {
    const uint64_t idx = next_write_index_;
    const uint64_t next = idx + 1;
    Slot& s = slots_[idx & mask_];
    // Invalidate the previous generation before touching its payload. A reader
    // that was concurrently copying it will reject the frame on its seq check.
    s.seq.store(0, std::memory_order_release);
    s.frame_len.store(len, std::memory_order_release);
    store_frame(s, frame, len);
    if constexpr (AfterPayloadWrite != nullptr) AfterPayloadWrite();
    // Release so the frame writes are visible before the seq flip. seq is idx+1
    // so 0 stays reserved for "never written".
    s.seq.store(next, std::memory_order_release);
    header_->write_index.store(next, std::memory_order_release);
    next_write_index_ = next;
  }

  // The producer's live write edge -- where a fresh reader should start.
  uint64_t live_edge() const {
    return header_->write_index.load(std::memory_order_acquire);
  }

  enum class FrameStatus { kOk, kEmpty, kLapped };

  // Try to read the slot at logical position read_index. On kLapped, resume_at
  // gives a safe position to jump to.
  FrameStatus read(uint64_t read_index, void* out, uint32_t* out_len,
                   uint64_t* resume_at) {
    Slot& s = slots_[read_index & mask_];
    const uint64_t seq = s.seq.load(std::memory_order_acquire);
    const uint64_t want = read_index + 1;

    if (__builtin_expect(seq < want, true)) return FrameStatus::kEmpty;
    if (__builtin_expect(seq > want, false)) {
      const uint64_t edge = live_edge();
      *resume_at = edge > slot_count() ? edge - slot_count() : 0;
      return FrameStatus::kLapped;
    }

    const uint32_t len = s.frame_len.load(std::memory_order_acquire);
    load_frame(s, out, len);
    // Re-check seq: if the producer began overwriting mid-copy, we were lapped.
    if (s.seq.load(std::memory_order_acquire) != want) {
      const uint64_t edge = live_edge();
      *resume_at = edge > slot_count() ? edge - slot_count() : 0;
      return FrameStatus::kLapped;
    }
    *out_len = len;
    return FrameStatus::kOk;
  }

 private:
  template <size_t Index, size_t WordCount>
  static inline __attribute__((always_inline)) void store_words(
      Slot& slot, const uint8_t* source) {
    uint64_t word = 0;
    __builtin_memcpy(&word, source + Index * kFrameWordSize, kFrameWordSize);
    slot.frame[Index].store(word, std::memory_order_release);
    if constexpr (Index + 1 < WordCount) {
      store_words<Index + 1, WordCount>(slot, source);
    }
  }

  static void store_frame(Slot& slot, const void* frame, uint32_t len) {
    const auto* source = static_cast<const uint8_t*>(frame);
    const size_t full_words = len / kFrameWordSize;
    if (full_words == sizeof(msg::Trade) / kFrameWordSize) {
      store_words<0, sizeof(msg::Trade) / kFrameWordSize>(slot, source);
    } else if (full_words == sizeof(msg::OrderBook) / kFrameWordSize) {
      store_words<0, sizeof(msg::OrderBook) / kFrameWordSize>(slot, source);
    } else {
      for (size_t index = 0; index < full_words; ++index) {
        uint64_t word = 0;
        __builtin_memcpy(&word, source + index * kFrameWordSize,
                         kFrameWordSize);
        slot.frame[index].store(word, std::memory_order_release);
      }
    }
    const size_t remainder = len % kFrameWordSize;
    if (remainder != 0) {
      uint64_t word = 0;
      std::memcpy(&word, source + full_words * kFrameWordSize, remainder);
      slot.frame[full_words].store(word, std::memory_order_release);
    }
  }

  template <size_t Index, size_t WordCount>
  static inline __attribute__((always_inline)) void load_words(
      const Slot& slot, uint8_t* destination) {
    const uint64_t word = slot.frame[Index].load(std::memory_order_acquire);
    __builtin_memcpy(destination + Index * kFrameWordSize, &word,
                     kFrameWordSize);
    if constexpr (Index + 1 < WordCount) {
      load_words<Index + 1, WordCount>(slot, destination);
    }
  }

  static void load_frame(const Slot& slot, void* frame, uint32_t len) {
    auto* destination = static_cast<uint8_t*>(frame);
    const size_t full_words = len / kFrameWordSize;
    if (full_words == sizeof(msg::Trade) / kFrameWordSize) {
      load_words<0, sizeof(msg::Trade) / kFrameWordSize>(slot, destination);
    } else if (full_words == sizeof(msg::OrderBook) / kFrameWordSize) {
      load_words<0, sizeof(msg::OrderBook) / kFrameWordSize>(slot,
                                                             destination);
    } else {
      for (size_t index = 0; index < full_words; ++index) {
        const uint64_t word =
            slot.frame[index].load(std::memory_order_acquire);
        __builtin_memcpy(destination + index * kFrameWordSize, &word,
                         kFrameWordSize);
      }
    }
    const size_t remainder = len % kFrameWordSize;
    if (remainder != 0) {
      const uint64_t word =
          slot.frame[full_words].load(std::memory_order_acquire);
      std::memcpy(destination + full_words * kFrameWordSize, &word, remainder);
    }
  }

  Header* header_ = nullptr;
  Slot* slots_ = nullptr;
  uint64_t mask_ = 0;
  // The single writer owns its cursor and only publishes the live edge.
  uint64_t next_write_index_ = 0;
};

using Ring = TRing<>;

}  // namespace shm
