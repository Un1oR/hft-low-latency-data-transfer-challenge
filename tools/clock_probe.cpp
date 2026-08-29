#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <sched.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

namespace {

constexpr std::uint64_t kMagic = 0x5350434c4f434b31ull;

struct ProbeFrame {
  std::uint64_t magic = kMagic;
  std::uint64_t sequence = 0;
  std::uint64_t initiator_send_ns = 0;
  std::uint64_t reflector_receive_ns = 0;
  std::uint64_t reflector_send_ns = 0;
};

static_assert(sizeof(ProbeFrame) == 40);

volatile std::sig_atomic_t stop_requested = 0;

void handle_signal(int) { stop_requested = 1; }

auto realtime_ns() -> std::uint64_t {
  timespec value{};
  ::clock_gettime(CLOCK_REALTIME, &value);
  return static_cast<std::uint64_t>(value.tv_sec) * 1'000'000'000ull +
         static_cast<std::uint64_t>(value.tv_nsec);
}

auto monotonic_ns() -> std::uint64_t {
  timespec value{};
  ::clock_gettime(CLOCK_MONOTONIC_RAW, &value);
  return static_cast<std::uint64_t>(value.tv_sec) * 1'000'000'000ull +
         static_cast<std::uint64_t>(value.tv_nsec);
}

struct Config {
  bool reflect = false;
  bool probe = false;
  std::string bind_address = "0.0.0.0";
  std::string peer_address;
  std::uint16_t port = 51900;
  std::uint64_t count = 5000;
  std::uint64_t rate = 5000;
  std::uint64_t idle_ms = 30'000;
  int core = -1;
  std::string csv_path;
};

[[noreturn]] void usage_error(std::string_view message) {
  std::fprintf(stderr, "clock_probe: %.*s\n",
               static_cast<int>(message.size()), message.data());
  std::fprintf(stderr,
               "usage: clock_probe --reflect [--bind IP] [--port N] "
               "[--core N] [--idle-ms N]\n"
               "       clock_probe --probe --peer IP [--port N] "
               "[--count N] [--rate N] [--core N] [--csv PATH]\n");
  std::exit(2);
}

auto parse_u64(const std::string &text, std::string_view option)
    -> std::uint64_t {
  std::size_t consumed = 0;
  std::uint64_t value = 0;
  try {
    value = std::stoull(text, &consumed);
  } catch (const std::exception &) {
    usage_error(std::string(option) + " has an invalid value");
  }
  if (consumed != text.size()) {
    usage_error(std::string(option) + " has an invalid value");
  }
  return value;
}

auto parse_args(int argc, char **argv) -> Config {
  Config config;
  for (int index = 1; index < argc; ++index) {
    const std::string option = argv[index];
    auto next = [&]() -> std::string {
      if (index + 1 >= argc) usage_error("missing option value");
      return argv[++index];
    };

    if (option == "--reflect") {
      config.reflect = true;
    } else if (option == "--probe") {
      config.probe = true;
    } else if (option == "--bind") {
      config.bind_address = next();
    } else if (option == "--peer") {
      config.peer_address = next();
    } else if (option == "--port") {
      const auto value = parse_u64(next(), "--port");
      if (value == 0 || value > std::numeric_limits<std::uint16_t>::max()) {
        usage_error("--port must be in 1..65535");
      }
      config.port = static_cast<std::uint16_t>(value);
    } else if (option == "--count") {
      config.count = parse_u64(next(), "--count");
    } else if (option == "--rate") {
      config.rate = parse_u64(next(), "--rate");
    } else if (option == "--idle-ms") {
      config.idle_ms = parse_u64(next(), "--idle-ms");
    } else if (option == "--core") {
      const auto value = parse_u64(next(), "--core");
      if (value > static_cast<std::uint64_t>(std::numeric_limits<int>::max())) {
        usage_error("--core is out of range");
      }
      config.core = static_cast<int>(value);
    } else if (option == "--csv") {
      config.csv_path = next();
    } else {
      usage_error("unknown option: " + option);
    }
  }

  if (config.reflect == config.probe) {
    usage_error("exactly one of --reflect and --probe is required");
  }
  if (config.probe && config.peer_address.empty()) {
    usage_error("--probe requires --peer");
  }
  if (config.probe && (config.count == 0 || config.rate == 0)) {
    usage_error("--count and --rate must be positive");
  }
  return config;
}

auto pin_to_core(int core) -> bool {
  if (core < 0) return true;
  if (core >= CPU_SETSIZE) {
    std::fprintf(stderr, "clock_probe: core %d is out of range\n", core);
    return false;
  }
  cpu_set_t cpus;
  CPU_ZERO(&cpus);
  CPU_SET(core, &cpus);
  if (::sched_setaffinity(0, sizeof(cpus), &cpus) != 0) {
    std::fprintf(stderr, "clock_probe: sched_setaffinity: %s\n",
                 std::strerror(errno));
    return false;
  }
  return true;
}

auto ipv4_address(const std::string &address, std::uint16_t port,
                  sockaddr_in *result) -> bool {
  *result = {};
  result->sin_family = AF_INET;
  result->sin_port = htons(port);
  if (::inet_pton(AF_INET, address.c_str(), &result->sin_addr) != 1) {
    std::fprintf(stderr, "clock_probe: invalid IPv4 address: %s\n",
                 address.c_str());
    return false;
  }
  return true;
}

auto open_socket(const sockaddr_in *bind_address) -> int {
  const int descriptor = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (descriptor < 0) {
    std::fprintf(stderr, "clock_probe: socket: %s\n", std::strerror(errno));
    return -1;
  }

  const int tos = IPTOS_LOWDELAY;
  const int buffer_bytes = 4 << 20;
  const int busy_poll_us = 50;
  timeval timeout{};
  timeout.tv_usec = 200'000;
  ::setsockopt(descriptor, IPPROTO_IP, IP_TOS, &tos, sizeof(tos));
  ::setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &buffer_bytes,
               sizeof(buffer_bytes));
  ::setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &buffer_bytes,
               sizeof(buffer_bytes));
  ::setsockopt(descriptor, SOL_SOCKET, SO_BUSY_POLL, &busy_poll_us,
               sizeof(busy_poll_us));
  ::setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
               sizeof(timeout));

  if (bind_address != nullptr &&
      ::bind(descriptor, reinterpret_cast<const sockaddr *>(bind_address),
             sizeof(*bind_address)) != 0) {
    std::fprintf(stderr, "clock_probe: bind: %s\n", std::strerror(errno));
    ::close(descriptor);
    return -1;
  }
  return descriptor;
}

auto percentile(const std::vector<std::int64_t> &sorted, double quantile)
    -> std::int64_t {
  if (sorted.empty()) return 0;
  const auto index = static_cast<std::size_t>(
      quantile * static_cast<double>(sorted.size() - 1));
  return sorted[index];
}

auto run_reflector(const Config &config) -> int {
  sockaddr_in local{};
  if (!ipv4_address(config.bind_address, config.port, &local)) return 2;
  const int descriptor = open_socket(&local);
  if (descriptor < 0) return 1;

  std::uint64_t reflected = 0;
  auto last_progress = monotonic_ns();
  const auto idle_ns = config.idle_ms * 1'000'000ull;
  while (!stop_requested) {
    ProbeFrame frame{};
    sockaddr_in source{};
    socklen_t source_size = sizeof(source);
    const auto received = ::recvfrom(
        descriptor, &frame, sizeof(frame), 0,
        reinterpret_cast<sockaddr *>(&source), &source_size);
    if (received < 0) {
      if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
        std::fprintf(stderr, "clock_probe: recvfrom: %s\n",
                     std::strerror(errno));
        ::close(descriptor);
        return 1;
      }
      if (config.idle_ms != 0 && monotonic_ns() - last_progress > idle_ns) {
        break;
      }
      continue;
    }
    const auto receive_ns = realtime_ns();
    if (received != static_cast<ssize_t>(sizeof(frame)) ||
        frame.magic != kMagic) {
      continue;
    }
    frame.reflector_receive_ns = receive_ns;
    frame.reflector_send_ns = realtime_ns();
    const auto sent = ::sendto(
        descriptor, &frame, sizeof(frame), MSG_DONTWAIT,
        reinterpret_cast<const sockaddr *>(&source), source_size);
    if (sent == static_cast<ssize_t>(sizeof(frame))) {
      ++reflected;
      last_progress = monotonic_ns();
    }
  }

  std::printf("clock_reflector_reflected=%llu\n",
              static_cast<unsigned long long>(reflected));
  ::close(descriptor);
  return reflected == 0 ? 1 : 0;
}

auto run_probe(const Config &config) -> int {
  sockaddr_in peer{};
  if (!ipv4_address(config.peer_address, config.port, &peer)) return 2;
  const int descriptor = open_socket(nullptr);
  if (descriptor < 0) return 1;
  if (::connect(descriptor, reinterpret_cast<const sockaddr *>(&peer),
                sizeof(peer)) != 0) {
    std::fprintf(stderr, "clock_probe: connect: %s\n", std::strerror(errno));
    ::close(descriptor);
    return 1;
  }

  std::vector<std::int64_t> round_trip;
  std::vector<std::int64_t> turnaround;
  std::vector<std::int64_t> one_way;
  std::vector<std::int64_t> offset;
  round_trip.reserve(config.count);
  turnaround.reserve(config.count);
  one_way.reserve(config.count);
  offset.reserve(config.count);

  const auto period_ns = 1'000'000'000ull / config.rate;
  auto next_send = monotonic_ns();
  std::uint64_t lost = 0;
  std::uint64_t consecutive_lost = 0;
  for (std::uint64_t sequence = 0;
       sequence < config.count && !stop_requested; ++sequence) {
    next_send += period_ns;
    while (monotonic_ns() < next_send) {
    }

    ProbeFrame sent{};
    sent.sequence = sequence;
    sent.initiator_send_ns = realtime_ns();
    if (::send(descriptor, &sent, sizeof(sent), 0) !=
        static_cast<ssize_t>(sizeof(sent))) {
      ++lost;
      continue;
    }

    ProbeFrame received{};
    const auto received_size = ::recv(descriptor, &received, sizeof(received), 0);
    const auto initiator_receive_ns = realtime_ns();
    if (received_size != static_cast<ssize_t>(sizeof(received)) ||
        received.magic != kMagic || received.sequence != sequence) {
      ++lost;
      if (++consecutive_lost >= 50) break;
      continue;
    }
    consecutive_lost = 0;

    const auto rtt = static_cast<std::int64_t>(initiator_receive_ns) -
                     static_cast<std::int64_t>(received.initiator_send_ns);
    const auto turn =
        static_cast<std::int64_t>(received.reflector_send_ns) -
        static_cast<std::int64_t>(received.reflector_receive_ns);
    const auto estimated_one_way = (rtt - turn) / 2;
    const auto estimated_offset =
        static_cast<std::int64_t>(received.reflector_receive_ns) -
        static_cast<std::int64_t>(received.initiator_send_ns) -
        estimated_one_way;
    if (rtt < 0 || turn < 0 || estimated_one_way < 0) {
      ++lost;
      continue;
    }
    round_trip.push_back(rtt);
    turnaround.push_back(turn);
    one_way.push_back(estimated_one_way);
    offset.push_back(estimated_offset);
  }
  ::close(descriptor);

  auto sorted_rtt = round_trip;
  auto sorted_one_way = one_way;
  auto sorted_offset = offset;
  std::sort(sorted_rtt.begin(), sorted_rtt.end());
  std::sort(sorted_one_way.begin(), sorted_one_way.end());
  std::sort(sorted_offset.begin(), sorted_offset.end());

  std::printf("clock_probe_samples=%zu\n", offset.size());
  std::printf("clock_probe_lost=%llu\n",
              static_cast<unsigned long long>(lost));
  std::printf("clock_probe_rtt_p50_ns=%lld\n",
              static_cast<long long>(percentile(sorted_rtt, 0.5)));
  std::printf("clock_probe_rtt_p99_ns=%lld\n",
              static_cast<long long>(percentile(sorted_rtt, 0.99)));
  std::printf("clock_probe_oneway_p50_ns=%lld\n",
              static_cast<long long>(percentile(sorted_one_way, 0.5)));
  std::printf("clock_probe_offset_p50_ns=%lld\n",
              static_cast<long long>(percentile(sorted_offset, 0.5)));
  std::printf("clock_probe_offset_p01_ns=%lld\n",
              static_cast<long long>(percentile(sorted_offset, 0.01)));
  std::printf("clock_probe_offset_p99_ns=%lld\n",
              static_cast<long long>(percentile(sorted_offset, 0.99)));

  if (!config.csv_path.empty()) {
    std::FILE *csv = std::fopen(config.csv_path.c_str(), "w");
    if (csv == nullptr) {
      std::fprintf(stderr, "clock_probe: fopen %s: %s\n",
                   config.csv_path.c_str(), std::strerror(errno));
      return 1;
    }
    std::fprintf(csv,
                 "sample,rtt_ns,turnaround_ns,oneway_ns,offset_ns\n");
    for (std::size_t index = 0; index < offset.size(); ++index) {
      std::fprintf(csv, "%zu,%lld,%lld,%lld,%lld\n", index,
                   static_cast<long long>(round_trip[index]),
                   static_cast<long long>(turnaround[index]),
                   static_cast<long long>(one_way[index]),
                   static_cast<long long>(offset[index]));
    }
    std::fclose(csv);
  }

  const auto minimum_samples =
      std::max<std::uint64_t>(100, config.count - config.count / 10);
  return offset.size() >= minimum_samples ? 0 : 1;
}

}  // namespace

auto main(int argc, char **argv) -> int {
  const auto config = parse_args(argc, argv);
  std::signal(SIGINT, handle_signal);
  std::signal(SIGTERM, handle_signal);
  if (!pin_to_core(config.core)) return 1;
  return config.reflect ? run_reflector(config) : run_probe(config);
}
