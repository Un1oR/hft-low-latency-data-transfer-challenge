module;

#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include "message.h"
#include "shm_segment.h"
#include "spsc_ring.h"
#include "util.h"

module spectral.transport;

import std;

namespace spectral::transport {
namespace {

struct ReceiverConfig {
  std::string shm_name = "/fanout_rx";
  std::uint32_t slots = 1024;
  std::string bind_address = "0.0.0.0";
  std::uint16_t port = 9000;
  std::uint64_t count = 0;
  std::uint64_t idle_ms = 2000;
  bool busy_poll = false;
};

[[noreturn]] void receiver_usage_error(std::string_view message) {
  std::println(stderr, "receiver: {}", message);
  std::exit(2);
}

auto receiver_parse_u64(const std::string &value, std::string_view option)
    -> std::uint64_t {
  std::size_t consumed = 0;
  std::uint64_t parsed = 0;
  try {
    parsed = std::stoull(value, &consumed);
  } catch (const std::exception &) {
    std::println(stderr, "receiver: invalid value for {}: {}", option, value);
    std::exit(2);
  }
  if (consumed != value.size()) {
    std::println(stderr, "receiver: invalid value for {}: {}", option, value);
    std::exit(2);
  }
  return parsed;
}

auto parse_receiver_args(int argc, char **argv) -> ReceiverConfig {
  ReceiverConfig config;
  for (int index = 1; index < argc; ++index) {
    const std::string arg = argv[index];
    auto next = [&]() -> std::string {
      if (index + 1 >= argc)
        receiver_usage_error("missing option value");
      return argv[++index];
    };

    if (arg == "--shm") {
      config.shm_name = next();
    } else if (arg == "--slots") {
      const auto value = receiver_parse_u64(next(), "--slots");
      if (value == 0 || value > std::numeric_limits<std::uint32_t>::max()) {
        receiver_usage_error("--slots is out of range");
      }
      config.slots = static_cast<std::uint32_t>(value);
    } else if (arg == "--bind") {
      config.bind_address = next();
    } else if (arg == "--port") {
      const auto value = receiver_parse_u64(next(), "--port");
      if (value == 0 || value > std::numeric_limits<std::uint16_t>::max()) {
        receiver_usage_error("--port must be in 1..65535");
      }
      config.port = static_cast<std::uint16_t>(value);
    } else if (arg == "--count") {
      config.count = receiver_parse_u64(next(), "--count");
    } else if (arg == "--idle-ms") {
      config.idle_ms = receiver_parse_u64(next(), "--idle-ms");
    } else if (arg == "--busy-poll") {
      config.busy_poll = true;
    } else {
      std::println(stderr, "receiver: unknown option: {}", arg);
      std::exit(2);
    }
  }

  if ((config.slots & (config.slots - 1)) != 0) {
    receiver_usage_error("--slots must be a power of two");
  }
  return config;
}

auto valid_frame(const std::uint8_t *frame, std::size_t frame_len) -> bool {
  if (frame_len < sizeof(msg::Header) ||
      frame_len > shm::spsc::kFrameCap) {
    return false;
  }
  const auto *header = reinterpret_cast<const msg::Header *>(frame);
  return header->body_len == frame_len;
}

} // namespace

auto receiver_main(int argc, char **argv) -> int {
  const auto config = parse_receiver_args(argc, argv);

  sockaddr_in bind_address{};
  bind_address.sin_family = AF_INET;
  bind_address.sin_port = htons(config.port);
  if (inet_pton(AF_INET, config.bind_address.c_str(), &bind_address.sin_addr) !=
      1) {
    std::println(stderr, "receiver: invalid IPv4 bind address: {}",
                 config.bind_address);
    return 2;
  }

  const int socket_type =
      SOCK_DGRAM | (config.busy_poll ? SOCK_NONBLOCK : 0);
  const int socket_fd = socket(AF_INET, socket_type, 0);
  if (socket_fd < 0) {
    std::println(stderr, "receiver: socket failed: {}", std::strerror(errno));
    return 1;
  }

  const int reuse_address = 1;
  if (setsockopt(socket_fd, SOL_SOCKET, SO_REUSEADDR, &reuse_address,
                 sizeof(reuse_address)) != 0) {
    std::println(stderr, "receiver: SO_REUSEADDR failed: {}",
                 std::strerror(errno));
    close(socket_fd);
    return 1;
  }

  if (!config.busy_poll) {
    timeval receive_timeout{};
    const auto timeout_ms = config.idle_ms == 0
                                ? std::uint64_t{100}
                                : std::min(config.idle_ms, std::uint64_t{100});
    receive_timeout.tv_sec = static_cast<time_t>(timeout_ms / 1000);
    receive_timeout.tv_usec =
        static_cast<suseconds_t>((timeout_ms % 1000) * 1000);
    if (setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &receive_timeout,
                   sizeof(receive_timeout)) != 0) {
      std::println(stderr, "receiver: SO_RCVTIMEO failed: {}",
                   std::strerror(errno));
      close(socket_fd);
      return 1;
    }
  }

  if (bind(socket_fd, reinterpret_cast<const sockaddr *>(&bind_address),
           sizeof(bind_address)) != 0) {
    std::println(stderr, "receiver: bind({}:{}) failed: {}",
                 config.bind_address, config.port, std::strerror(errno));
    close(socket_fd);
    return 1;
  }

  auto segment = shm::Segment::open(
      config.shm_name, shm::spsc::sequence_region_size(config.slots),
      /*create=*/true);
  shm::spsc::SequenceRing ring;
  ring.attach(segment.base(), config.slots, /*init=*/true);

  std::uint64_t received = 0;
  std::uint64_t invalid = 0;
  std::uint64_t queue_dropped = 0;
  auto last_progress = util::now_ns();
  const auto idle_ns = config.idle_ms * 1000000ull;
  alignas(64) std::uint8_t frame[shm::spsc::kFrameCap];

  std::println(stderr,
               "receiver: bind={}:{} shm={} slots={} count={} busy_poll={}",
               config.bind_address, config.port, config.shm_name, config.slots,
               config.count, config.busy_poll);

  while (config.count == 0 || received < config.count) {
    const auto datagram_len =
        recvfrom(socket_fd, frame, shm::spsc::kFrameCap, MSG_TRUNC, nullptr,
                 nullptr);
    if (datagram_len < 0) {
      if (errno == EINTR)
        continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        if (config.idle_ms != 0 && util::now_ns() - last_progress > idle_ns) {
          break;
        }
        continue;
      }
      std::println(stderr, "receiver: recvfrom failed: {}",
                   std::strerror(errno));
      close(socket_fd);
      segment.unlink();
      return 1;
    }

    last_progress = util::now_ns();
    if (!valid_frame(frame, static_cast<std::size_t>(datagram_len))) {
      ++invalid;
      continue;
    }

    if (!ring.publish(frame, static_cast<std::uint32_t>(datagram_len))) {
      ++queue_dropped;
      continue;
    }
    ++received;
  }

  close(socket_fd);
  segment.unlink();
  std::println(stderr,
               "receiver: received={} invalid={} queue_dropped={}", received,
               invalid, queue_dropped);
  return 0;
}

} // namespace spectral::transport
