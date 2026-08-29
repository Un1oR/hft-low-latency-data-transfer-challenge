module;

#include <arpa/inet.h>
#include <fcntl.h>
#include <linux/ptp_clock.h>
#include <netinet/ip.h>
#include <sched.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include "message.h"
#include "shm_segment.h"
#include "spsc_ring.h"
#include "util.h"

module spectral.transport;

import std;
import spectral.wire;
#if SPECTRAL_HAS_DPDK
import spectral.dpdk;
#endif

namespace spectral::transport {
namespace {

enum class NetworkingBackend { kSocket, kDpdk };

constexpr unsigned int kPhcCalibrationCpu = 0;
constexpr auto kPhcCalibrationPeriod = std::chrono::milliseconds(20);

struct PhcRealtimeCalibration {
  std::int64_t realtime_minus_phc_ns = 0;
  std::uint64_t realtime_midpoint_ns = 0;
  std::uint64_t uncertainty_ns = 0;
  std::uint64_t bracket_ns = 0;
  std::uint32_t samples = 0;
  std::string_view method;
};

auto ptp_clock_time_ns(const ptp_clock_time& value) -> std::uint64_t {
  if (value.sec < 0 || value.nsec < 0 || value.nsec >= 1'000'000'000) {
    throw std::runtime_error("invalid PTP clock timestamp");
  }
  return static_cast<std::uint64_t>(value.sec) * 1'000'000'000ull +
         static_cast<std::uint64_t>(value.nsec);
}

auto timespec_ns(const timespec& value) -> std::uint64_t {
  if (value.tv_sec < 0 || value.tv_nsec < 0 ||
      value.tv_nsec >= 1'000'000'000) {
    throw std::runtime_error("invalid clock_gettime timestamp");
  }
  return static_cast<std::uint64_t>(value.tv_sec) * 1'000'000'000ull +
         static_cast<std::uint64_t>(value.tv_nsec);
}

auto make_calibration(std::uint64_t system_before_ns,
                      std::uint64_t phc_ns,
                      std::uint64_t system_after_ns,
                      std::uint32_t samples, std::string_view method)
    -> std::optional<PhcRealtimeCalibration> {
  if (system_after_ns < system_before_ns) return std::nullopt;
  const auto bracket_ns = system_after_ns - system_before_ns;
  const auto midpoint_ns = system_before_ns + bracket_ns / 2;
  if (midpoint_ns > static_cast<std::uint64_t>(
                        std::numeric_limits<std::int64_t>::max()) ||
      phc_ns > static_cast<std::uint64_t>(
                   std::numeric_limits<std::int64_t>::max())) {
    return std::nullopt;
  }
  return PhcRealtimeCalibration{
      .realtime_minus_phc_ns = static_cast<std::int64_t>(midpoint_ns) -
                               static_cast<std::int64_t>(phc_ns),
      .realtime_midpoint_ns = midpoint_ns,
      .uncertainty_ns = (bracket_ns + 1) / 2,
      .bracket_ns = bracket_ns,
      .samples = samples,
      .method = method,
  };
}

class PhcRealtimeCalibrator {
 public:
  explicit PhcRealtimeCalibrator(std::string_view device) {
    const std::string path(device);
    descriptor_ = ::open(path.c_str(), O_RDWR | O_CLOEXEC);
    if (descriptor_ < 0) {
      throw std::runtime_error(
          std::format("open({}) failed: {}", path, std::strerror(errno)));
    }
  }

  ~PhcRealtimeCalibrator() {
    if (descriptor_ >= 0) ::close(descriptor_);
  }

  PhcRealtimeCalibrator(const PhcRealtimeCalibrator&) = delete;
  auto operator=(const PhcRealtimeCalibrator&)
      -> PhcRealtimeCalibrator& = delete;

  auto sample() const -> PhcRealtimeCalibration {
    if (auto calibration = sample_extended(PTP_SYS_OFFSET_EXTENDED2,
                                           "PTP_SYS_OFFSET_EXTENDED2",
                                           PTP_MAX_SAMPLES)) {
      return *calibration;
    }
    if (auto calibration = sample_extended(PTP_SYS_OFFSET_EXTENDED,
                                           "PTP_SYS_OFFSET_EXTENDED",
                                           PTP_MAX_SAMPLES)) {
      return *calibration;
    }
    return sample_clock_gettime();
  }

  // ENA limits PHC get-time requests to 125/s. Periodic calibration uses one
  // hardware request and deliberately has no retry loop: the full fallback
  // below reads the PHC 128 times and would exceed that limit. A single direct
  // get-time is also known to return EBUSY promptly when ENA throttles it,
  // whereas the extended ioctl may wait in the driver while the process exits.
  auto sample_periodic() const -> std::optional<PhcRealtimeCalibration> {
    constexpr auto kClockFd = 3u;
    const auto descriptor_bits = static_cast<unsigned int>(descriptor_);
    const auto phc_clock = static_cast<clockid_t>(
        ((~descriptor_bits) << 3) | kClockFd);
    timespec before{};
    timespec phc{};
    timespec after{};
    if (::clock_gettime(CLOCK_REALTIME, &before) != 0 ||
        ::clock_gettime(phc_clock, &phc) != 0 ||
        ::clock_gettime(CLOCK_REALTIME, &after) != 0) {
      return std::nullopt;
    }
    return make_calibration(timespec_ns(before), timespec_ns(phc),
                            timespec_ns(after), 1,
                            "clock_gettime-midpoint-single");
  }

 private:
  auto sample_extended(unsigned long request, std::string_view method,
                       std::uint32_t sample_count) const
      -> std::optional<PhcRealtimeCalibration> {
    if (sample_count == 0 || sample_count > PTP_MAX_SAMPLES) {
      return std::nullopt;
    }
    ptp_sys_offset_extended samples{};
    samples.n_samples = sample_count;
    // Zero selects CLOCK_REALTIME both in the old rsv[3] ABI and in the
    // kernel >= 6.12 ABI where its first word is named clockid.
    if (::ioctl(descriptor_, request, &samples) != 0) return std::nullopt;

    std::optional<PhcRealtimeCalibration> best;
    for (std::uint32_t index = 0; index < samples.n_samples; ++index) {
      const auto candidate = make_calibration(
          ptp_clock_time_ns(samples.ts[index][0]),
          ptp_clock_time_ns(samples.ts[index][1]),
          ptp_clock_time_ns(samples.ts[index][2]), samples.n_samples, method);
      if (candidate &&
          (!best || candidate->bracket_ns < best->bracket_ns)) {
        best = candidate;
      }
    }
    return best;
  }

  auto sample_clock_gettime() const -> PhcRealtimeCalibration {
    constexpr std::uint32_t kSamples = 128;
    constexpr auto kClockFd = 3u;
    const auto descriptor_bits = static_cast<unsigned int>(descriptor_);
    const auto phc_clock = static_cast<clockid_t>(
        ((~descriptor_bits) << 3) | kClockFd);

    std::optional<PhcRealtimeCalibration> best;
    for (std::uint32_t index = 0; index < kSamples; ++index) {
      timespec before{};
      timespec phc{};
      timespec after{};
      if (::clock_gettime(CLOCK_REALTIME, &before) != 0 ||
          ::clock_gettime(phc_clock, &phc) != 0 ||
          ::clock_gettime(CLOCK_REALTIME, &after) != 0) {
        throw std::runtime_error(std::format(
            "PHC clock_gettime calibration failed: {}", std::strerror(errno)));
      }
      const auto candidate = make_calibration(
          timespec_ns(before), timespec_ns(phc), timespec_ns(after), kSamples,
          "clock_gettime-midpoint");
      if (candidate &&
          (!best || candidate->bracket_ns < best->bracket_ns)) {
        best = candidate;
      }
    }
    if (!best) throw std::runtime_error("PHC calibration produced no sample");
    return *best;
  }

  int descriptor_ = -1;
};

class PeriodicPhcThreadGuard {
 public:
  PeriodicPhcThreadGuard(std::atomic<bool>& stop_requested,
                         std::jthread& thread)
      : stop_requested_(stop_requested), thread_(thread) {}

  ~PeriodicPhcThreadGuard() { stop_and_join(); }

  PeriodicPhcThreadGuard(const PeriodicPhcThreadGuard&) = delete;
  auto operator=(const PeriodicPhcThreadGuard&)
      -> PeriodicPhcThreadGuard& = delete;

  void stop_and_join() {
    stop_requested_.store(true, std::memory_order_release);
    if (thread_.joinable()) {
      thread_.request_stop();
      thread_.join();
    }
  }

 private:
  std::atomic<bool>& stop_requested_;
  std::jthread& thread_;
};

auto phc_to_realtime(std::uint64_t phc_ns, std::int64_t offset_ns)
    -> std::uint64_t {
  if (offset_ns >= 0) {
    const auto positive = static_cast<std::uint64_t>(offset_ns);
    if (phc_ns > std::numeric_limits<std::uint64_t>::max() - positive) {
      throw std::runtime_error("calibrated hardware timestamp overflow");
    }
    return phc_ns + positive;
  }
  const auto magnitude =
      static_cast<std::uint64_t>(-(offset_ns + 1)) + 1;
  if (phc_ns < magnitude) {
    throw std::runtime_error("calibrated hardware timestamp underflow");
  }
  return phc_ns - magnitude;
}

#if SPECTRAL_HAS_DPDK
class DpdkReceiveLease {
 public:
  void acquire(dpdk::Port* port) { port_ = port; }
  ~DpdkReceiveLease() {
    if (port_ != nullptr) port_->release_received();
  }

  DpdkReceiveLease() = default;
  DpdkReceiveLease(const DpdkReceiveLease&) = delete;
  auto operator=(const DpdkReceiveLease&) -> DpdkReceiveLease& = delete;

 private:
  dpdk::Port* port_ = nullptr;
};
#endif

struct ReceiverConfig {
  std::string shm_name = "/fanout_rx";
  std::uint32_t slots = 1024;
  std::string bind_address = "0.0.0.0";
  std::uint16_t port = 9000;
  std::uint64_t count = 0;
  std::uint64_t idle_ms = 2000;
  std::uint32_t busy_poll_us = 0;
  bool stage_timestamps = false;
  bool dpdk_rx_hardware_timestamps = false;
  std::uint16_t dpdk_rx_burst_size = 32;
  std::uint16_t dpdk_rx_free_threshold = 0;
  NetworkingBackend networking_backend = NetworkingBackend::kSocket;
  std::string dpdk_pci;
  std::string local_mac;
};

[[noreturn]] void receiver_usage_error(std::string_view message) {
  std::println(stderr, "receiver: {}", message);
  std::exit(2);
}

auto receiver_parse_u64(const std::string& value, std::string_view option)
    -> std::uint64_t {
  std::size_t consumed = 0;
  std::uint64_t parsed = 0;
  try {
    parsed = std::stoull(value, &consumed);
  } catch (const std::exception&) {
    std::println(stderr, "receiver: invalid value for {}: {}", option, value);
    std::exit(2);
  }
  if (consumed != value.size()) {
    std::println(stderr, "receiver: invalid value for {}: {}", option, value);
    std::exit(2);
  }
  return parsed;
}

auto parse_receiver_args(int argc, char** argv) -> ReceiverConfig {
  ReceiverConfig config;
  for (int index = 1; index < argc; ++index) {
    const std::string arg = argv[index];
    auto next = [&]() -> std::string {
      if (index + 1 >= argc) receiver_usage_error("missing option value");
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
      config.busy_poll_us = 50;
    } else if (arg == "--busy-poll-us") {
      const auto value = receiver_parse_u64(next(), "--busy-poll-us");
      if (value == 0 || value > 1000000) {
        receiver_usage_error("--busy-poll-us must be in 1..1000000");
      }
      config.busy_poll_us = static_cast<std::uint32_t>(value);
    } else if (arg == "--stage-timestamps") {
      config.stage_timestamps = true;
    } else if (arg == "--dpdk-rx-hardware-timestamps") {
      config.dpdk_rx_hardware_timestamps = true;
    } else if (arg == "--dpdk-rx-burst-size") {
      const auto value = receiver_parse_u64(next(), "--dpdk-rx-burst-size");
      if (value == 0 || value > 32) {
        receiver_usage_error("--dpdk-rx-burst-size must be in 1..32");
      }
      config.dpdk_rx_burst_size = static_cast<std::uint16_t>(value);
    } else if (arg == "--dpdk-rx-free-threshold") {
      const auto value =
          receiver_parse_u64(next(), "--dpdk-rx-free-threshold");
      if (value >= 1024) {
        receiver_usage_error(
            "--dpdk-rx-free-threshold must be in 0..1023");
      }
      config.dpdk_rx_free_threshold = static_cast<std::uint16_t>(value);
    } else if (arg == "--networking-backend") {
      const auto value = next();
      if (value == "socket") {
        config.networking_backend = NetworkingBackend::kSocket;
      } else if (value == "dpdk") {
        config.networking_backend = NetworkingBackend::kDpdk;
      } else {
        receiver_usage_error("--networking-backend must be socket or dpdk");
      }
    } else if (arg == "--dpdk-pci") {
      config.dpdk_pci = next();
    } else if (arg == "--local-mac") {
      config.local_mac = next();
    } else {
      std::println(stderr, "receiver: unknown option: {}", arg);
      std::exit(2);
    }
  }

  if ((config.slots & (config.slots - 1)) != 0) {
    receiver_usage_error("--slots must be a power of two");
  }
  if (config.networking_backend == NetworkingBackend::kDpdk &&
      (config.dpdk_pci.empty() || config.local_mac.empty() ||
       config.bind_address == "0.0.0.0")) {
    receiver_usage_error(
        "DPDK requires --dpdk-pci, --local-mac and a concrete --bind IPv4");
  }
  if (config.dpdk_rx_hardware_timestamps &&
      config.networking_backend != NetworkingBackend::kDpdk) {
    receiver_usage_error(
        "--dpdk-rx-hardware-timestamps requires --networking-backend dpdk");
  }
  if (config.dpdk_rx_hardware_timestamps && !config.stage_timestamps) {
    receiver_usage_error(
        "--dpdk-rx-hardware-timestamps requires --stage-timestamps");
  }
  if (config.networking_backend != NetworkingBackend::kDpdk &&
      (config.dpdk_rx_burst_size != 32 ||
       config.dpdk_rx_free_threshold != 0)) {
    receiver_usage_error(
        "DPDK RX tuning requires --networking-backend dpdk");
  }
  return config;
}

}  // namespace

auto receiver_main(int argc, char** argv) -> int {
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

  // SO_BUSY_POLL is reached only by the blocking receive path. In spin mode the
  // socket is non-blocking and packets become visible after the regular softirq.
  const bool busy_poll = config.busy_poll_us != 0;
  int socket_fd = -1;
#if SPECTRAL_HAS_DPDK
  std::optional<dpdk::Address> dpdk_local;
  std::unique_ptr<dpdk::Port> dpdk_port;
#endif
  std::unique_ptr<PhcRealtimeCalibrator> phc_calibrator;
  std::optional<PhcRealtimeCalibration> initial_phc_calibration;
  std::vector<PhcRealtimeCalibration> periodic_phc_calibrations;
  std::uint64_t periodic_phc_failures = 0;
  std::atomic<int> periodic_phc_thread_state = 0;
  std::atomic<bool> periodic_phc_stop_requested = false;
  std::string periodic_phc_thread_error;
  std::jthread periodic_phc_thread;
  PeriodicPhcThreadGuard periodic_phc_thread_guard(
      periodic_phc_stop_requested, periodic_phc_thread);
  if (config.networking_backend == NetworkingBackend::kSocket) {
    const int socket_type = SOCK_DGRAM | (busy_poll ? 0 : SOCK_NONBLOCK);
    socket_fd = socket(AF_INET, socket_type, 0);
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

    const int receive_buffer = 8 << 20;
    if (setsockopt(socket_fd, SOL_SOCKET, SO_RCVBUF, &receive_buffer,
                   sizeof(receive_buffer)) != 0) {
      std::println(stderr, "receiver: SO_RCVBUF failed: {}",
                   std::strerror(errno));
      close(socket_fd);
      return 1;
    }
    const int tos = IPTOS_LOWDELAY;
    if (setsockopt(socket_fd, IPPROTO_IP, IP_TOS, &tos, sizeof(tos)) != 0) {
      std::println(stderr, "receiver: IP_TOS failed: {}",
                   std::strerror(errno));
      close(socket_fd);
      return 1;
    }

    if (busy_poll) {
      const int busy_poll_value = static_cast<int>(config.busy_poll_us);
      if (setsockopt(socket_fd, SOL_SOCKET, SO_BUSY_POLL, &busy_poll_value,
                     sizeof(busy_poll_value)) != 0) {
        std::println(stderr, "receiver: SO_BUSY_POLL={} failed: {}",
                     config.busy_poll_us, std::strerror(errno));
        close(socket_fd);
        return 1;
      }

      timeval receive_timeout{};
      const auto timeout_ms = config.idle_ms == 0
                                  ? std::uint64_t{100}
                                  : std::min(config.idle_ms,
                                             std::uint64_t{100});
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

    if (bind(socket_fd, reinterpret_cast<const sockaddr*>(&bind_address),
             sizeof(bind_address)) != 0) {
      std::println(stderr, "receiver: bind({}:{}) failed: {}",
                   config.bind_address, config.port, std::strerror(errno));
      close(socket_fd);
      return 1;
    }
  } else {
#if SPECTRAL_HAS_DPDK
    dpdk_local = dpdk::parse_address(config.bind_address, config.local_mac);
    if (!dpdk_local) {
      std::println(stderr, "receiver: invalid DPDK local address");
      return 2;
    }
    try {
      dpdk_port = std::make_unique<dpdk::Port>(
          config.dpdk_pci, *dpdk_local, "spectral-receiver",
          config.dpdk_rx_hardware_timestamps, config.dpdk_rx_burst_size,
          config.dpdk_rx_free_threshold);
    } catch (const std::exception& error) {
      std::println(stderr, "receiver: DPDK initialization failed: {}",
                   error.what());
      return 1;
    }
#else
    std::println(stderr, "receiver: this build does not include DPDK support");
    return 2;
#endif
  }

  if (config.dpdk_rx_hardware_timestamps) {
    try {
      phc_calibrator =
          std::make_unique<PhcRealtimeCalibrator>("/dev/ptp_ena");
      initial_phc_calibration = phc_calibrator->sample();
      std::println(
          stderr,
          "receiver: PHC calibration before method={} "
          "realtime_minus_phc_ns={} realtime_midpoint_ns={} "
          "uncertainty_ns={} bracket_ns={} samples={}",
          initial_phc_calibration->method,
          initial_phc_calibration->realtime_minus_phc_ns,
          initial_phc_calibration->realtime_midpoint_ns,
          initial_phc_calibration->uncertainty_ns,
          initial_phc_calibration->bracket_ns,
          initial_phc_calibration->samples);

      periodic_phc_thread = std::jthread([&](std::stop_token stop_token) {
        cpu_set_t cpu_set;
        CPU_ZERO(&cpu_set);
        CPU_SET(kPhcCalibrationCpu, &cpu_set);
        if (::sched_setaffinity(0, sizeof(cpu_set), &cpu_set) != 0) {
          periodic_phc_thread_error = std::format(
              "sched_setaffinity(cpu={}) failed: {}", kPhcCalibrationCpu,
              std::strerror(errno));
          periodic_phc_thread_state.store(-1, std::memory_order_release);
          return;
        }
        periodic_phc_thread_state.store(1, std::memory_order_release);

        while (!stop_token.stop_requested() &&
               !periodic_phc_stop_requested.load(
                   std::memory_order_acquire)) {
          try {
            if (auto calibration = phc_calibrator->sample_periodic()) {
              periodic_phc_calibrations.push_back(*calibration);
            } else {
              ++periodic_phc_failures;
            }
          } catch (const std::exception& error) {
            ++periodic_phc_failures;
            periodic_phc_thread_error = error.what();
          }
          std::this_thread::sleep_for(kPhcCalibrationPeriod);
        }
      });
      while (periodic_phc_thread_state.load(std::memory_order_acquire) == 0) {
        std::this_thread::yield();
      }
      if (periodic_phc_thread_state.load(std::memory_order_acquire) < 0) {
        std::println(stderr, "receiver: PHC periodic calibration failed: {}",
                     periodic_phc_thread_error);
        return 1;
      }
      std::println(stderr,
                   "receiver: PHC periodic calibration cpu={} period_ms={} "
                   "phc_requests_per_sample=1 "
                   "max_device_requests_per_second=125",
                   kPhcCalibrationCpu, kPhcCalibrationPeriod.count());
    } catch (const std::exception& error) {
      std::println(stderr, "receiver: PHC calibration failed: {}",
                   error.what());
      return 1;
    }
  }

  auto segment = shm::Segment::open(
      config.shm_name, shm::spsc::sequence_region_size(config.slots),
      /*create=*/true);
  shm::spsc::SequenceRing ring;
  ring.attach(segment.base(), config.slots, /*init=*/true);

  std::uint64_t received = 0;
  std::uint64_t frames_seen = 0;
  std::uint64_t datagrams_received = 0;
  std::uint64_t invalid = 0;
  std::uint64_t queue_dropped = 0;
  std::uint64_t datagram_gap_events = 0;
  std::uint64_t datagrams_lost = 0;
  std::uint64_t datagrams_reordered = 0;
  std::uint64_t next_datagram_seq = 0;
#if SPECTRAL_HAS_DPDK
  std::uint32_t empty_polls = 0;
#endif
  auto last_progress = util::now_ns();
  const auto idle_ns = config.idle_ms * 1000000ull;
  alignas(64) std::array<std::uint8_t, wire::kMaxDatagramBytes> datagram{};
  std::array<const std::uint8_t*, wire::kMaxFramesPerDatagram> frames{};
  std::array<std::uint32_t, wire::kMaxFramesPerDatagram> frame_lengths{};
  std::array<std::uint32_t, wire::kMaxFramesPerDatagram>
      frame_wire_lengths{};

  std::println(stderr,
               "receiver: bind={}:{} shm={} slots={} count={} busy_poll_us={} "
               "batch_protocol=v1 stage_timestamps={} "
               "stage_receive_timestamp=software "
               "stage_hardware_receive_timestamp={} networking_backend={} "
               "dpdk_rx_burst_size={} dpdk_rx_free_threshold={}",
               config.bind_address, config.port, config.shm_name, config.slots,
               config.count, config.busy_poll_us,
               config.stage_timestamps ? "yes" : "no",
               config.dpdk_rx_hardware_timestamps
                   ? "dpdk-hardware-calibrated-realtime"
                   : "off",
               config.networking_backend == NetworkingBackend::kSocket
                   ? "socket"
                   : "dpdk",
               config.dpdk_rx_burst_size,
               config.dpdk_rx_free_threshold);

  while (config.count == 0 || received < config.count) {
    ssize_t datagram_len = -1;
    const std::uint8_t* datagram_data = datagram.data();
    std::uint64_t hardware_receive_phc_ns = 0;
    std::uint64_t hardware_receive_realtime_ns = 0;
    std::uint64_t dpdk_rx_burst_return_realtime_ns = 0;
#if SPECTRAL_HAS_DPDK
    DpdkReceiveLease dpdk_receive_lease;
#endif
    if (config.networking_backend == NetworkingBackend::kSocket) {
      datagram_len = recvfrom(socket_fd, datagram.data(), datagram.size(),
                              MSG_TRUNC, nullptr, nullptr);
    } else {
#if SPECTRAL_HAS_DPDK
      const auto result = dpdk_port->receive(*dpdk_local, config.port);
      if (result.status == dpdk::ReceiveStatus::kEmpty) {
        ++empty_polls;
        if (config.idle_ms != 0 && (empty_polls & 0x3ffu) == 0 &&
            util::now_ns() - last_progress > idle_ns) {
          break;
        }
        continue;
      }
      if (result.status == dpdk::ReceiveStatus::kInvalid) {
        ++invalid;
        continue;
      }
      datagram_len = result.length;
      datagram_data = result.data;
      hardware_receive_phc_ns = result.hardware_timestamp_ns;
      dpdk_rx_burst_return_realtime_ns =
          result.burst_return_realtime_ns;
      dpdk_receive_lease.acquire(dpdk_port.get());
#endif
    }
    if (datagram_len < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        if (config.idle_ms != 0 && util::now_ns() - last_progress > idle_ns) {
          break;
        }
        continue;
      }
      std::println(stderr, "receiver: recvfrom failed: {}",
                   std::strerror(errno));
      if (socket_fd >= 0) close(socket_fd);
      segment.unlink();
      return 1;
    }

    const auto software_receive_ts_ns = util::now_ns();
    if (config.dpdk_rx_hardware_timestamps &&
        hardware_receive_phc_ns == 0) {
      std::println(stderr,
                   "receiver: DPDK packet is missing requested hardware RX "
                   "timestamp");
      segment.unlink();
      return 1;
    }
    if (config.dpdk_rx_hardware_timestamps) {
      hardware_receive_realtime_ns = phc_to_realtime(
          hardware_receive_phc_ns,
          initial_phc_calibration->realtime_minus_phc_ns);
    }
    constexpr std::uint64_t kTimestampSanityWindowNs = 1'000'000'000ull;
    if (config.dpdk_rx_hardware_timestamps &&
        (hardware_receive_realtime_ns >
             software_receive_ts_ns + kTimestampSanityWindowNs ||
         software_receive_ts_ns >
             hardware_receive_realtime_ns + kTimestampSanityWindowNs)) {
      std::println(stderr,
                   "receiver: calibrated DPDK hardware RX timestamp differs "
                   "from software CLOCK_REALTIME by over one second: "
                   "hardware={} software={}",
                   hardware_receive_realtime_ns, software_receive_ts_ns);
      segment.unlink();
      return 1;
    }
    const auto transport_receive_ts_ns = software_receive_ts_ns;
#if SPECTRAL_HAS_DPDK
    empty_polls = 0;
#endif
    last_progress = software_receive_ts_ns;
    if (datagram_data == nullptr ||
        datagram_len > static_cast<ssize_t>(datagram.size())) {
      ++invalid;
      continue;
    }

    wire::Walker walker;
    if (!walker.begin(datagram_data,
                      static_cast<std::uint32_t>(datagram_len))) {
      ++invalid;
      continue;
    }

    std::size_t frame_count = 0;
    bool malformed = false;
    while (true) {
      std::uint32_t frame_len = 0;
      std::uint32_t frame_wire_len = 0;
      const auto* frame =
          walker.next_wire(&frame_len, &frame_wire_len, &malformed);
      if (frame == nullptr) break;
      if (frame_count == frames.size()) {
        malformed = true;
        break;
      }
      frames[frame_count] = frame;
      frame_lengths[frame_count] = frame_len;
      frame_wire_lengths[frame_count] = frame_wire_len;
      ++frame_count;
    }
    if (malformed || frame_count != walker.frame_count()) {
      ++invalid;
      continue;
    }

    const auto datagram_seq = walker.datagram_seq();
    const auto transport_send_ts_ns = walker.send_ts_ns();
    if (next_datagram_seq == 0 || datagram_seq == next_datagram_seq) {
      next_datagram_seq = datagram_seq + 1;
    } else if (datagram_seq > next_datagram_seq) {
      ++datagram_gap_events;
      datagrams_lost += datagram_seq - next_datagram_seq;
      next_datagram_seq = datagram_seq + 1;
    } else {
      ++datagrams_reordered;
    }

    ++datagrams_received;
    frames_seen += frame_count;
    for (std::size_t frame_index = 0; frame_index < frame_count;
         ++frame_index) {
      bool published = false;
      if (walker.decoded_frames()) {
        auto* destination = ring.reserve();
        if (destination != nullptr) {
          if (walker.compact_frames()) {
            wire::decode_compact_frame(
                frames[frame_index], frame_wire_lengths[frame_index],
                destination, frame_lengths[frame_index]);
          } else {
            wire::decode_minimal_frame(frames[frame_index], destination,
                                       frame_lengths[frame_index]);
          }
          if (config.stage_timestamps) {
            ring.publish_reserved(
                frame_lengths[frame_index],
                shm::spsc::StageTimestamps{
                    .transport_send_ts_ns = transport_send_ts_ns,
                    .transport_receive_ts_ns = transport_receive_ts_ns,
                    .hardware_receive_realtime_ns =
                        hardware_receive_realtime_ns,
                    .dpdk_rx_burst_return_realtime_ns =
                        dpdk_rx_burst_return_realtime_ns,
                });
          } else {
            ring.publish_reserved(frame_lengths[frame_index]);
          }
          published = true;
        }
      } else {
        published =
            config.stage_timestamps
                ? ring.publish(
                      frames[frame_index], frame_lengths[frame_index],
                      shm::spsc::StageTimestamps{
                          .transport_send_ts_ns = transport_send_ts_ns,
                          .transport_receive_ts_ns = transport_receive_ts_ns,
                          .hardware_receive_realtime_ns =
                              hardware_receive_realtime_ns,
                          .dpdk_rx_burst_return_realtime_ns =
                              dpdk_rx_burst_return_realtime_ns,
                      })
                : ring.publish(frames[frame_index],
                               frame_lengths[frame_index]);
      }
      if (!published) {
        ++queue_dropped;
        continue;
      }
      ++received;
    }
  }

  int phc_calibration_status = 0;
  if (phc_calibrator) {
    if (periodic_phc_thread.joinable()) {
      std::println(stderr, "receiver: PHC periodic calibration stopping");
      periodic_phc_thread_guard.stop_and_join();
      std::println(stderr, "receiver: PHC periodic calibration stopped");
    }
    for (std::size_t index = 0; index < periodic_phc_calibrations.size();
         ++index) {
      const auto& calibration = periodic_phc_calibrations[index];
      std::println(
          stderr,
          "receiver: PHC calibration periodic index={} method={} "
          "realtime_minus_phc_ns={} realtime_midpoint_ns={} "
          "uncertainty_ns={} bracket_ns={} samples={}",
          index, calibration.method, calibration.realtime_minus_phc_ns,
          calibration.realtime_midpoint_ns, calibration.uncertainty_ns,
          calibration.bracket_ns, calibration.samples);
    }
    std::println(stderr,
                 "receiver: PHC periodic calibration samples={} failures={} "
                 "period_ms=20 last_error={}",
                 periodic_phc_calibrations.size(), periodic_phc_failures,
                 periodic_phc_thread_error.empty()
                     ? std::string_view("none")
                     : std::string_view(periodic_phc_thread_error));
    if (periodic_phc_calibrations.empty()) {
      std::println(stderr,
                   "receiver: PHC periodic calibration produced no samples");
      phc_calibration_status = 1;
    }
    try {
      const auto final_phc_calibration = phc_calibrator->sample();
      const auto drift_ns =
          final_phc_calibration.realtime_minus_phc_ns -
          initial_phc_calibration->realtime_minus_phc_ns;
      const auto drift_magnitude_ns =
          drift_ns < 0 ? static_cast<std::uint64_t>(-(drift_ns + 1)) + 1
                       : static_cast<std::uint64_t>(drift_ns);
      const auto run_uncertainty_ns =
          std::max(initial_phc_calibration->uncertainty_ns,
                   final_phc_calibration.uncertainty_ns) +
          drift_magnitude_ns;
      std::println(
          stderr,
          "receiver: PHC calibration after method={} "
          "realtime_minus_phc_ns={} realtime_midpoint_ns={} "
          "uncertainty_ns={} bracket_ns={} samples={} drift_ns={} "
          "run_uncertainty_ns={}",
          final_phc_calibration.method,
          final_phc_calibration.realtime_minus_phc_ns,
          final_phc_calibration.realtime_midpoint_ns,
          final_phc_calibration.uncertainty_ns,
          final_phc_calibration.bracket_ns, final_phc_calibration.samples,
          drift_ns, run_uncertainty_ns);
    } catch (const std::exception& error) {
      std::println(stderr, "receiver: final PHC calibration failed: {}",
                   error.what());
      phc_calibration_status = 1;
    }
  }

  if (socket_fd >= 0) close(socket_fd);
  segment.unlink();
  const double frames_per_datagram =
      datagrams_received == 0
          ? 0.0
          : static_cast<double>(frames_seen) /
                static_cast<double>(datagrams_received);
  std::println(stderr,
               "receiver: received={} frames_seen={} datagrams_received={} "
               "frames_per_datagram={:.3f} invalid={} queue_dropped={} "
               "datagram_gap_events={} datagrams_lost={} "
               "datagrams_reordered={}",
               received, frames_seen, datagrams_received, frames_per_datagram,
               invalid, queue_dropped, datagram_gap_events, datagrams_lost,
               datagrams_reordered);
#if SPECTRAL_HAS_DPDK
  if (dpdk_port) {
    const auto stats = dpdk_port->stats();
    std::println(stderr,
                 "receiver: dpdk_rx={} dpdk_tx={} dpdk_imissed={} "
                 "dpdk_ierrors={} dpdk_oerrors={} dpdk_rx_nombuf={} "
                 "dpdk_bw_in_exceeded={} dpdk_bw_out_exceeded={} "
                 "dpdk_pps_exceeded={} dpdk_conntrack_exceeded={} "
                 "dpdk_linklocal_exceeded={}",
                 stats.packets_received, stats.packets_sent,
                 stats.packets_missed, stats.receive_errors, stats.send_errors,
                 stats.receive_nombuf, stats.bw_in_allowance_exceeded,
                 stats.bw_out_allowance_exceeded,
                 stats.pps_allowance_exceeded,
                 stats.conntrack_allowance_exceeded,
                 stats.linklocal_allowance_exceeded);
  }
#endif
  return phc_calibration_status;
}

}  // namespace spectral::transport
