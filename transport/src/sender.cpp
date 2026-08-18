module;

#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

#include "message.h"
#include "shm_segment.h"
#include "spsc_ring.h"
#include "util.h"

module spectral.transport;

import std;

namespace spectral::transport {
namespace {

struct SenderConfig {
  std::string shm_name = "/fanout_tx";
  std::uint32_t slots = 1024;
  std::string destination = "127.0.0.1";
  std::uint16_t port = 9000;
  std::uint64_t count = 0;
  bool from_edge = false;
  std::uint64_t idle_ms = 2000;
};

[[noreturn]] void sender_usage_error(std::string_view message) {
  std::println(stderr, "sender: {}", message);
  std::exit(2);
}

auto sender_parse_u64(const std::string &value, std::string_view option)
    -> std::uint64_t {
  std::size_t consumed = 0;
  std::uint64_t parsed = 0;
  try {
    parsed = std::stoull(value, &consumed);
  } catch (const std::exception &) {
    std::println(stderr, "sender: invalid value for {}: {}", option, value);
    std::exit(2);
  }
  if (consumed != value.size()) {
    std::println(stderr, "sender: invalid value for {}: {}", option, value);
    std::exit(2);
  }
  return parsed;
}

auto parse_sender_args(int argc, char **argv) -> SenderConfig {
  SenderConfig config;
  for (int index = 1; index < argc; ++index) {
    const std::string arg = argv[index];
    auto next = [&]() -> std::string {
      if (index + 1 >= argc)
        sender_usage_error("missing option value");
      return argv[++index];
    };

    if (arg == "--shm") {
      config.shm_name = next();
    } else if (arg == "--slots") {
      const auto value = sender_parse_u64(next(), "--slots");
      if (value == 0 || value > std::numeric_limits<std::uint32_t>::max()) {
        sender_usage_error("--slots is out of range");
      }
      config.slots = static_cast<std::uint32_t>(value);
    } else if (arg == "--dest") {
      config.destination = next();
    } else if (arg == "--port") {
      const auto value = sender_parse_u64(next(), "--port");
      if (value == 0 || value > std::numeric_limits<std::uint16_t>::max()) {
        sender_usage_error("--port must be in 1..65535");
      }
      config.port = static_cast<std::uint16_t>(value);
    } else if (arg == "--count") {
      config.count = sender_parse_u64(next(), "--count");
    } else if (arg == "--from-edge") {
      config.from_edge = true;
    } else if (arg == "--idle-ms") {
      config.idle_ms = sender_parse_u64(next(), "--idle-ms");
    } else {
      std::println(stderr, "sender: unknown option: {}", arg);
      std::exit(2);
    }
  }

  if ((config.slots & (config.slots - 1)) != 0) {
    sender_usage_error("--slots must be a power of two");
  }
  return config;
}

} // namespace

auto sender_main(int argc, char **argv) -> int {
  const auto config = parse_sender_args(argc, argv);

  sockaddr_in destination{};
  destination.sin_family = AF_INET;
  destination.sin_port = htons(config.port);
  if (inet_pton(AF_INET, config.destination.c_str(), &destination.sin_addr) !=
      1) {
    std::println(stderr, "sender: invalid IPv4 destination: {}",
                 config.destination);
    return 2;
  }

  const int socket_fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (socket_fd < 0) {
    std::println(stderr, "sender: socket failed: {}", std::strerror(errno));
    return 1;
  }

  auto segment = shm::Segment::open(
      config.shm_name, shm::spsc::sequence_region_size(config.slots),
      /*create=*/false);
  const auto *shared_header =
      static_cast<const shm::spsc::Header *>(segment.base());
  if (shared_header->magic != shm::spsc::kMagic ||
      shared_header->slot_count != config.slots ||
      shared_header->slot_size != sizeof(shm::spsc::SequenceSlot)) {
    std::println(stderr,
                 "sender: incompatible shared-memory layout: magic={:#x} "
                 "slots={} slot_size={} expected_slot_size={}",
                 shared_header->magic, shared_header->slot_count,
                 shared_header->slot_size, sizeof(shm::spsc::SequenceSlot));
    close(socket_fd);
    return 1;
  }
  shm::spsc::SequenceRing ring;
  ring.attach(segment.base(), config.slots, /*init=*/false);

  auto read_index = config.from_edge ? ring.live_edge() : 0;
  std::uint64_t processed = 0;
  std::uint64_t forwarded = 0;
  std::uint64_t send_errors = 0;
  std::uint64_t lapped_events = 0;
  auto last_progress = util::now_ns();
  const auto idle_ns = config.idle_ms * 1000000ull;
  alignas(64) std::uint8_t frame[shm::spsc::kFrameCap];

  std::println(stderr,
               "sender: shm={} slots={} dest={}:{} count={} from_edge={}",
               config.shm_name, config.slots, config.destination, config.port,
               config.count, config.from_edge ? "yes" : "no");
  ring.activate_reader();

  while (config.count == 0 || processed < config.count) {
    std::uint32_t frame_len = 0;
    std::uint64_t resume_at = 0;
    const auto status = ring.read(read_index, frame, &frame_len, &resume_at);

    if (status == shm::spsc::SequenceRing::FrameStatus::kOk) {
      ssize_t sent = -1;
      do {
        sent = sendto(socket_fd, frame, frame_len, 0,
                      reinterpret_cast<const sockaddr *>(&destination),
                      sizeof(destination));
      } while (sent < 0 && errno == EINTR);

      if (sent == static_cast<ssize_t>(frame_len)) {
        ++forwarded;
      } else {
        ++send_errors;
        if (sent < 0) {
          std::println(stderr, "sender: sendto failed at ring index {}: {}",
                       read_index, std::strerror(errno));
        } else {
          std::println(stderr, "sender: short datagram at ring index {}: {}/{}",
                       read_index, sent, frame_len);
        }
      }

      ring.commit(read_index);
      ++processed;
      ++read_index;
      last_progress = util::now_ns();
    } else if (status == shm::spsc::SequenceRing::FrameStatus::kLapped) {
      ++lapped_events;
      read_index = resume_at;
      last_progress = util::now_ns();
    } else if (config.idle_ms != 0 &&
               util::now_ns() - last_progress > idle_ns) {
      break;
    }
  }

  close(socket_fd);
  std::println(stderr,
               "sender: processed={} forwarded={} send_errors={} lapped={}",
               processed, forwarded, send_errors, lapped_events);
  return send_errors == 0 ? 0 : 1;
}

} // namespace spectral::transport
