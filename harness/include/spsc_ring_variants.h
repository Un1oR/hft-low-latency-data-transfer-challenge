// Semantically named SPSC candidates retained for reproducible ablations.
// Production code uses shm::spsc::SequenceRing from spsc_ring.h; removing this
// header and the explicit startup dispatches removes every rejected protocol.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>

#include "spsc_ring.h"

namespace shm::spsc::experimental {

inline constexpr uint32_t kCursorMagic = 0x43504332;       // "CPC2"
inline constexpr uint32_t kSplitPaddedMagic = 0x53504333;  // "SPC3"
inline constexpr uint32_t kSplitDenseMagic = 0x44504333;   // "DPC3"

// Classic SPSC ownership: producer and consumer publish global cursors and
// cache the other side's cursor locally. This is the shared-head/tail baseline.
struct alignas(kCacheLine) CursorSlot {
  uint32_t frame_len;
  alignas(kCacheLine) uint8_t frame[kFrameCap];
};

static_assert(offsetof(CursorSlot, frame) == kCacheLine);
static_assert(sizeof(CursorSlot) == kCacheLine + kFrameCap);

inline size_t cursor_region_size(uint32_t slots) {
  return sizeof(Header) + static_cast<size_t>(slots) * sizeof(CursorSlot);
}

class CursorRing {
 public:
  static size_t region_size(uint32_t slots) {
    return cursor_region_size(slots);
  }

  void attach(void* base, uint32_t slots, bool init) {
    header_ = static_cast<Header*>(base);
    slots_ = reinterpret_cast<CursorSlot*>(static_cast<uint8_t*>(base) +
                                           sizeof(Header));
    if (init) {
      header_->magic = kCursorMagic;
      header_->slot_count = slots;
      header_->slot_size = sizeof(CursorSlot);
      header_->reader_ready.store(0, std::memory_order_relaxed);
      header_->write_index.store(0, std::memory_order_relaxed);
      header_->read_index.store(0, std::memory_order_relaxed);
    }
    mask_ = header_->slot_count - 1;
    next_write_index_ = header_->write_index.load(std::memory_order_relaxed);
    cached_read_index_ = header_->read_index.load(std::memory_order_relaxed);
    next_read_index_ = cached_read_index_;
    cached_write_index_ = next_write_index_;
  }

  uint32_t slot_count() const { return header_->slot_count; }

  bool publish(const void* frame, uint32_t len) {
    uint8_t* destination = reserve();
    if (destination == nullptr) return false;
    copy_frame(destination, frame, len);
    publish_reserved(len);
    return true;
  }

  uint8_t* reserve() {
    if (next_write_index_ - cached_read_index_ >= slot_count()) {
      cached_read_index_ =
          header_->read_index.load(std::memory_order_acquire);
      if (next_write_index_ - cached_read_index_ >= slot_count()) {
        return nullptr;
      }
    }
    return slots_[next_write_index_ & mask_].frame;
  }

  void publish_reserved(uint32_t len) {
    CursorSlot& slot = slots_[next_write_index_ & mask_];
    slot.frame_len = len;
    ++next_write_index_;
    header_->write_index.store(next_write_index_, std::memory_order_release);
  }

  uint64_t live_edge() {
    const uint64_t edge =
        header_->write_index.load(std::memory_order_acquire);
    next_read_index_ = edge;
    cached_write_index_ = edge;
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

  FrameStatus acquire(uint64_t read_index, const uint8_t** frame,
                      uint32_t* out_len, uint64_t* resume_at) {
    if (read_index != next_read_index_) {
      next_read_index_ = read_index;
      header_->read_index.store(read_index, std::memory_order_release);
    }
    if (next_read_index_ == cached_write_index_) {
      cached_write_index_ =
          header_->write_index.load(std::memory_order_acquire);
      if (next_read_index_ == cached_write_index_) {
        return FrameStatus::kEmpty;
      }
    }
    CursorSlot& slot = slots_[next_read_index_ & mask_];
    *frame = slot.frame;
    *out_len = slot.frame_len;
    *resume_at = next_read_index_;
    return FrameStatus::kOk;
  }

  void commit(uint64_t read_index) {
    next_read_index_ = read_index + 1;
    header_->read_index.store(next_read_index_, std::memory_order_release);
  }

 private:
  Header* header_ = nullptr;
  CursorSlot* slots_ = nullptr;
  uint64_t mask_ = 0;
  uint64_t next_write_index_ = 0;
  uint64_t cached_read_index_ = 0;
  uint64_t next_read_index_ = 0;
  uint64_t cached_write_index_ = 0;
};

// Same per-slot sequence protocol as production, with metadata and payloads in
// separate arrays. The aliases below expose the two cache-isolation choices as
// named layout candidates rather than boolean policy combinations.
struct alignas(kCacheLine) PaddedControl {
  std::atomic<uint64_t> sequence;
  uint32_t frame_len;
};

struct DenseControl {
  std::atomic<uint64_t> sequence;
  uint32_t frame_len;
  uint32_t reserved;
};

struct alignas(kCacheLine) SplitFrame {
  uint8_t frame[kFrameCap];
};

static_assert(sizeof(PaddedControl) == kCacheLine);
static_assert(sizeof(DenseControl) == 16);
static_assert(sizeof(SplitFrame) == kFrameCap);

inline constexpr size_t align_to_cache_line(size_t value) {
  return (value + kCacheLine - 1) & ~(kCacheLine - 1);
}

template <typename Control, uint32_t Magic>
inline size_t split_region_size(uint32_t slots) {
  return sizeof(Header) +
         align_to_cache_line(static_cast<size_t>(slots) * sizeof(Control)) +
         static_cast<size_t>(slots) * sizeof(SplitFrame);
}

template <typename Control, uint32_t Magic>
class SplitSequenceRing {
 public:
  static size_t region_size(uint32_t slots) {
    return split_region_size<Control, Magic>(slots);
  }

  void attach(void* base, uint32_t slots, bool init) {
    header_ = static_cast<Header*>(base);
    controls_ = reinterpret_cast<Control*>(static_cast<uint8_t*>(base) +
                                           sizeof(Header));
    const size_t controls_size =
        align_to_cache_line(static_cast<size_t>(slots) * sizeof(Control));
    frames_ = reinterpret_cast<SplitFrame*>(
        static_cast<uint8_t*>(base) + sizeof(Header) + controls_size);
    if (init) {
      header_->magic = Magic;
      header_->slot_count = slots;
      header_->slot_size = sizeof(Control) + sizeof(SplitFrame);
      header_->reader_ready.store(0, std::memory_order_relaxed);
      header_->write_index.store(0, std::memory_order_relaxed);
      header_->read_index.store(0, std::memory_order_relaxed);
      for (uint64_t index = 0; index < slots; ++index) {
        controls_[index].sequence.store(index, std::memory_order_relaxed);
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

  uint8_t* reserve() {
    Control& control = controls_[next_write_index_ & mask_];
    if (control.sequence.load(std::memory_order_acquire) != next_write_index_) {
      const uint64_t read_index =
          header_->read_index.load(std::memory_order_acquire);
      if (next_write_index_ - read_index >= slot_count()) return nullptr;
    }
    return frames_[next_write_index_ & mask_].frame;
  }

  void publish_reserved(uint32_t len) {
    Control& control = controls_[next_write_index_ & mask_];
    control.frame_len = len;
    ++next_write_index_;
    control.sequence.store(next_write_index_, std::memory_order_release);
    header_->write_index.store(next_write_index_, std::memory_order_release);
  }

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

  FrameStatus acquire(uint64_t read_index, const uint8_t** frame,
                      uint32_t* out_len, uint64_t* resume_at) {
    if (read_index != next_read_index_) next_read_index_ = read_index;
    Control& control = controls_[next_read_index_ & mask_];
    if (__builtin_expect(
            control.sequence.load(std::memory_order_acquire) !=
                next_read_index_ + 1,
            true)) {
      return FrameStatus::kEmpty;
    }
    *frame = frames_[next_read_index_ & mask_].frame;
    *out_len = control.frame_len;
    *resume_at = next_read_index_;
    return FrameStatus::kOk;
  }

  void commit(uint64_t read_index) {
    Control& control = controls_[read_index & mask_];
    control.sequence.store(read_index + slot_count(),
                           std::memory_order_release);
    next_read_index_ = read_index + 1;
    header_->read_index.store(next_read_index_, std::memory_order_relaxed);
  }

 private:
  Header* header_ = nullptr;
  Control* controls_ = nullptr;
  SplitFrame* frames_ = nullptr;
  uint64_t mask_ = 0;
  uint64_t next_write_index_ = 0;
  uint64_t next_read_index_ = 0;
};

using SplitPaddedSequenceRing =
    SplitSequenceRing<PaddedControl, kSplitPaddedMagic>;
using SplitDenseSequenceRing =
    SplitSequenceRing<DenseControl, kSplitDenseMagic>;

inline size_t split_padded_region_size(uint32_t slots) {
  return split_region_size<PaddedControl, kSplitPaddedMagic>(slots);
}

inline size_t split_dense_region_size(uint32_t slots) {
  return split_region_size<DenseControl, kSplitDenseMagic>(slots);
}

}  // namespace shm::spsc::experimental
