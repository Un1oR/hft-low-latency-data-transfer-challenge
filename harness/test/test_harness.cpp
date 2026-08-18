// Standalone assertion-based tests for the metrics accumulator and the shm ring.
// No test framework -- just asserts, so this stays dependency-free and builds
// with a single g++ invocation.
#include <cassert>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

#include "metrics.h"
#include "shm_ring.h"
#include "spsc_ring_variants.h"
#include "spsc_ring.h"

namespace {

enum class PublishGate {
  kOpen,            // The after-payload hook lets the writer continue.
  kPauseRequested,  // The next after-payload hook must stop the writer.
  kWriterPaused,    // The new payload is copied, but its seq is not published.
};

std::atomic<PublishGate> publish_gate{PublishGate::kOpen};

void pause_after_payload_write() {
  switch (publish_gate.load(std::memory_order_relaxed)) {
    case PublishGate::kOpen:
      return;
    case PublishGate::kPauseRequested:
      break;
    case PublishGate::kWriterPaused:
      assert(false && "publish hook re-entered while writer is paused");
      return;
  }
  publish_gate.store(PublishGate::kWriterPaused, std::memory_order_release);
  while (publish_gate.load(std::memory_order_acquire) ==
         PublishGate::kWriterPaused) {
    std::this_thread::yield();
  }
}

}  // namespace

static void test_metrics_basic() {
  metrics::Accumulator acc;
  // seq 1..100 all delivered, latency == seq nanoseconds.
  for (uint64_t i = 1; i <= 100; ++i) acc.record(i, i);
  metrics::Report r = acc.report();

  assert(r.received == 100);
  assert(r.expected == 100);
  assert(r.dropped == 0);
  assert(r.drop_rate == 0.0);
  assert(r.lat_min == 1);
  assert(r.lat_max == 100);
  // Nearest-rank: p50 of 1..100 -> rank ceil(0.5*100)=50 -> value 50.
  assert(r.p50 == 50);
  assert(r.p99 == 99);
  assert(r.lat_mean > 50.0 && r.lat_mean < 51.0);
  assert(acc.observations().size() == 100);
  assert(acc.observations().front().seq_id == 1);
  assert(acc.observations().front().latency_ns == 1);
  assert(acc.observations().back().seq_id == 100);
  assert(acc.observations().back().latency_ns == 100);
  printf("test_metrics_basic OK\n");
}

static void test_metrics_drops() {
  metrics::Accumulator acc;
  // Deliver only even sequence ids 2,4,...,100 -> 50 received, 100 expected.
  for (uint64_t i = 2; i <= 100; i += 2) acc.record(i, 10);
  metrics::Report r = acc.report();

  assert(r.received == 50);
  assert(r.expected == 99);  // last(100) - first(2) + 1
  assert(r.dropped == 49);
  assert(r.drop_rate > 0.49 && r.drop_rate < 0.50);
  printf("test_metrics_drops OK\n");
}

static void test_ring_roundtrip() {
  const uint32_t slots = 8;
  std::vector<uint8_t> mem(shm::region_size(slots));
  shm::Ring prod;
  prod.attach(mem.data(), slots, /*init=*/true);
  shm::Ring cons;
  cons.attach(mem.data(), slots, /*init=*/false);

  // Publish 5 frames (fits in the ring, no lapping).
  for (uint32_t i = 0; i < 5; ++i) {
    uint8_t frame[16];
    std::memset(frame, static_cast<int>(i), sizeof(frame));
    prod.publish(frame, sizeof(frame));
  }

  uint64_t read_index = 0;
  for (uint32_t i = 0; i < 5; ++i) {
    uint8_t out[64];
    uint32_t len = 0;
    uint64_t resume = 0;
    auto st = cons.read(read_index, out, &len, &resume);
    assert(st == shm::Ring::FrameStatus::kOk);
    assert(len == 16);
    assert(out[0] == static_cast<uint8_t>(i));
    ++read_index;
  }
  // Next read is empty (nothing published yet).
  uint8_t out[64];
  uint32_t len = 0;
  uint64_t resume = 0;
  assert(cons.read(read_index, out, &len, &resume) ==
         shm::Ring::FrameStatus::kEmpty);
  printf("test_ring_roundtrip OK\n");
}

static void test_ring_lapping() {
  const uint32_t slots = 4;
  std::vector<uint8_t> mem(shm::region_size(slots));
  shm::Ring prod;
  prod.attach(mem.data(), slots, /*init=*/true);
  shm::Ring cons;
  cons.attach(mem.data(), slots, /*init=*/false);

  // Publish 10 frames into a 4-slot ring -> reader sitting at index 0 is lapped.
  for (uint32_t i = 0; i < 10; ++i) {
    uint8_t frame[8];
    std::memset(frame, static_cast<int>(i), sizeof(frame));
    prod.publish(frame, sizeof(frame));
  }

  uint8_t out[64];
  uint32_t len = 0;
  uint64_t resume = 0;
  auto st = cons.read(0, out, &len, &resume);
  assert(st == shm::Ring::FrameStatus::kLapped);
  // Producer wrote 10, ring holds 4 -> safe resume position is 10 - 4 = 6.
  assert(resume == 6);

  // Reading from the resume point yields the frame published at index 6.
  st = cons.read(resume, out, &len, &resume);
  assert(st == shm::Ring::FrameStatus::kOk);
  assert(out[0] == 6);
  printf("test_ring_lapping OK\n");
}

static void test_ring_rejects_overwrite_in_progress() {
  struct Frame {
    uint64_t generation;
    uint8_t payload[56];
  };

  std::vector<uint8_t> mem(shm::region_size(1));
  shm::TRing<pause_after_payload_write> prod;
  prod.attach(mem.data(), 1, /*init=*/true);
  shm::Ring cons;
  cons.attach(mem.data(), 1, /*init=*/false);

  Frame first{};
  first.generation = 1;
  std::memset(first.payload, 0x11, sizeof(first.payload));

  Frame second{};
  second.generation = 2;
  std::memset(second.payload, 0x22, sizeof(second.payload));
  publish_gate.store(PublishGate::kOpen, std::memory_order_relaxed);
  std::thread writer([&] {
    prod.publish(&first, sizeof(first));
    publish_gate.store(PublishGate::kPauseRequested,
                       std::memory_order_relaxed);
    prod.publish(&second, sizeof(second));
  });
  while (publish_gate.load(std::memory_order_acquire) !=
         PublishGate::kWriterPaused) {
    std::this_thread::yield();
  }

  Frame out{};
  uint32_t len = 0;
  uint64_t resume = 0;
  const auto status = cons.read(0, &out, &len, &resume);
  const bool accepted_overwrite =
      status == shm::Ring::FrameStatus::kOk &&
      (len != sizeof(first) || std::memcmp(&out, &first, sizeof(first)) != 0);

  publish_gate.store(PublishGate::kOpen, std::memory_order_release);
  writer.join();

  assert(!accepted_overwrite);
  printf("test_ring_rejects_overwrite_in_progress OK\n");
}

static void test_sequence_ring_zero_copy_ownership() {
  constexpr uint32_t slots = 2;
  void* memory = nullptr;
  assert(posix_memalign(&memory, shm::spsc::kCacheLine,
                        shm::spsc::sequence_region_size(slots)) == 0);
  std::memset(memory, 0, shm::spsc::sequence_region_size(slots));

  shm::spsc::SequenceRing producer;
  producer.attach(memory, slots, /*init=*/true);
  shm::spsc::SequenceRing consumer;
  consumer.attach(memory, slots, /*init=*/false);

  uint8_t* first = producer.reserve();
  assert(first != nullptr);
  std::memset(first, 0x11, sizeof(msg::Trade));
  reinterpret_cast<msg::Header*>(first)->seq_id = 1;
  producer.publish_reserved(sizeof(msg::Trade));

  uint8_t* second = producer.reserve();
  assert(second != nullptr);
  std::memset(second, 0x22, sizeof(msg::Trade));
  reinterpret_cast<msg::Header*>(second)->seq_id = 2;
  producer.publish_reserved(sizeof(msg::Trade));

  // Both slots are reader-owned. The non-blocking producer reports a full
  // queue instead of overwriting either view.
  assert(producer.reserve() == nullptr);

  const uint8_t* view = nullptr;
  uint32_t len = 0;
  uint64_t resume = 0;
  assert(consumer.acquire(0, &view, &len, &resume) ==
         shm::spsc::SequenceRing::FrameStatus::kOk);
  assert(view == first);
  assert(len == sizeof(msg::Trade));
  assert(reinterpret_cast<const msg::Header*>(view)->seq_id == 1);
  assert(view[sizeof(msg::Header)] == 0x11);

  consumer.commit(0);
  uint8_t* third = producer.reserve();
  assert(third == first);
  std::memset(third, 0x33, sizeof(msg::Trade));
  reinterpret_cast<msg::Header*>(third)->seq_id = 3;
  producer.publish_reserved(sizeof(msg::Trade));

  assert(consumer.acquire(1, &view, &len, &resume) ==
         shm::spsc::SequenceRing::FrameStatus::kOk);
  assert(view == second);
  assert(reinterpret_cast<const msg::Header*>(view)->seq_id == 2);
  consumer.commit(1);

  assert(consumer.acquire(2, &view, &len, &resume) ==
         shm::spsc::SequenceRing::FrameStatus::kOk);
  assert(view == third);
  assert(reinterpret_cast<const msg::Header*>(view)->seq_id == 3);
  consumer.commit(2);

  std::free(memory);
  printf("test_sequence_ring_zero_copy_ownership OK\n");
}

static void test_spsc_ring_zero_copy_wrap() {
  const size_t region_size =
      shm::spsc::experimental::cursor_region_size(2);
  void* memory = nullptr;
  assert(posix_memalign(&memory, shm::spsc::kCacheLine, region_size) == 0);
  std::memset(memory, 0, region_size);
  shm::spsc::experimental::CursorRing producer;
  producer.attach(memory, 2, /*init=*/true);
  shm::spsc::experimental::CursorRing consumer;
  consumer.attach(memory, 2, /*init=*/false);

  for (uint64_t sequence = 1; sequence <= 8; ++sequence) {
    auto* frame = reinterpret_cast<msg::Trade*>(producer.reserve());
    assert(frame != nullptr);
    frame->header.seq_id = sequence;
    frame->header.body_len = sizeof(*frame);
    producer.publish_reserved(sizeof(*frame));

    const uint8_t* view = nullptr;
    uint32_t len = 0;
    uint64_t resume = 0;
    assert(consumer.acquire(sequence - 1, &view, &len, &resume) ==
           shm::spsc::experimental::CursorRing::FrameStatus::kOk);
    assert(len == sizeof(*frame));
    assert(reinterpret_cast<const msg::Trade*>(view)->header.seq_id ==
           sequence);
    consumer.commit(sequence - 1);
  }

  std::free(memory);
  printf("test_spsc_ring_zero_copy_wrap OK\n");
}

static void test_sequence_ring_live_edge_fast_forward() {
  constexpr uint32_t slots = 4;
  void* memory = nullptr;
  assert(posix_memalign(&memory, shm::spsc::kCacheLine,
                        shm::spsc::sequence_region_size(slots)) == 0);
  std::memset(memory, 0, shm::spsc::sequence_region_size(slots));

  shm::spsc::SequenceRing producer;
  producer.attach(memory, slots, /*init=*/true);
  shm::spsc::SequenceRing consumer;
  consumer.attach(memory, slots, /*init=*/false);

  for (uint64_t sequence = 1; sequence <= 2; ++sequence) {
    uint8_t* frame = producer.reserve();
    assert(frame != nullptr);
    reinterpret_cast<msg::Header*>(frame)->seq_id = sequence;
    producer.publish_reserved(sizeof(msg::Trade));
  }

  assert(consumer.live_edge() == 2);

  // Publish a full fresh generation. The last two writes wrap over slots the
  // consumer skipped without an O(slots) cleanup pass.
  for (uint64_t sequence = 3; sequence <= 6; ++sequence) {
    uint8_t* frame = producer.reserve();
    assert(frame != nullptr);
    reinterpret_cast<msg::Header*>(frame)->seq_id = sequence;
    producer.publish_reserved(sizeof(msg::Trade));
  }
  assert(producer.reserve() == nullptr);

  for (uint64_t read_index = 2; read_index < 6; ++read_index) {
    const uint8_t* view = nullptr;
    uint32_t len = 0;
    uint64_t resume = 0;
    assert(consumer.acquire(read_index, &view, &len, &resume) ==
           shm::spsc::SequenceRing::FrameStatus::kOk);
    assert(reinterpret_cast<const msg::Header*>(view)->seq_id ==
           read_index + 1);
    consumer.commit(read_index);
  }

  std::free(memory);
  printf("test_sequence_ring_live_edge_fast_forward OK\n");
}

template <typename Ring>
static void test_split_sequence_layout_wrap(size_t region_size,
                                            const char* name) {
  void* memory = nullptr;
  assert(posix_memalign(&memory, shm::spsc::kCacheLine, region_size) == 0);
  std::memset(memory, 0, region_size);
  Ring producer;
  producer.attach(memory, 2, /*init=*/true);
  Ring consumer;
  consumer.attach(memory, 2, /*init=*/false);
  for (uint64_t sequence = 1; sequence <= 8; ++sequence) {
    auto* frame = reinterpret_cast<msg::Trade*>(producer.reserve());
    assert(frame != nullptr);
    frame->header.seq_id = sequence;
    frame->header.body_len = sizeof(*frame);
    producer.publish_reserved(sizeof(*frame));
    const uint8_t* view = nullptr;
    uint32_t len = 0;
    uint64_t resume = 0;
    assert(consumer.acquire(sequence - 1, &view, &len, &resume) ==
           Ring::FrameStatus::kOk);
    assert(len == sizeof(*frame));
    assert(reinterpret_cast<const msg::Trade*>(view)->header.seq_id ==
           sequence);
    consumer.commit(sequence - 1);
  }
  std::free(memory);
  printf("%s OK\n", name);
}

int main() {
  test_metrics_basic();
  test_metrics_drops();
  test_ring_roundtrip();
  test_ring_lapping();
  test_ring_rejects_overwrite_in_progress();
  test_sequence_ring_zero_copy_ownership();
  test_spsc_ring_zero_copy_wrap();
  test_sequence_ring_live_edge_fast_forward();
  test_split_sequence_layout_wrap<
      shm::spsc::experimental::SplitPaddedSequenceRing>(
      shm::spsc::experimental::split_padded_region_size(2),
      "test_split_padded_sequence_ring_wrap");
  test_split_sequence_layout_wrap<
      shm::spsc::experimental::SplitDenseSequenceRing>(
      shm::spsc::experimental::split_dense_region_size(2),
      "test_split_dense_sequence_ring_wrap");
  printf("ALL TESTS PASSED\n");
  return 0;
}
