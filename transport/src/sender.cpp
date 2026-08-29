module;

#include <arpa/inet.h>
#include <netinet/ip.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#if SPECTRAL_HAS_DPDK
#include <rte_cycles.h>
#endif

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

struct SenderConfig {
  std::string shm_name = "/fanout_tx";
  std::uint32_t slots = 1024;
  std::vector<std::string> destinations;
  std::vector<std::string> destination_macs;
  std::uint16_t port = 9000;
  std::uint32_t datagram_bytes = wire::kDefaultDatagramBytes;
  std::uint64_t count = 0;
  bool from_edge = false;
  std::uint64_t idle_ms = 2000;
  std::uint64_t batch_wait_ns = 0;
  std::uint32_t batch_target_frames = 2;
  bool llq_probe_minimal_wire = false;
  bool llq_probe_mixed_wire = false;
  bool compact_wire = false;
  bool compact_wire_mixed = false;
  std::uint8_t dpdk_llq_policy = 1;
  NetworkingBackend networking_backend = NetworkingBackend::kSocket;
  std::string dpdk_pci;
  std::string source_ip;
  std::string source_mac;
};

struct DestinationSocket {
  std::string address;
  int fd = -1;
  std::uint64_t forwarded = 0;
  std::uint64_t datagrams = 0;
  std::uint64_t send_errors = 0;
};

[[noreturn]] void sender_usage_error(std::string_view message) {
  std::println(stderr, "sender: {}", message);
  std::exit(2);
}

auto sender_parse_u64(const std::string& value, std::string_view option)
    -> std::uint64_t {
  std::size_t consumed = 0;
  std::uint64_t parsed = 0;
  try {
    parsed = std::stoull(value, &consumed);
  } catch (const std::exception&) {
    std::println(stderr, "sender: invalid value for {}: {}", option, value);
    std::exit(2);
  }
  if (consumed != value.size()) {
    std::println(stderr, "sender: invalid value for {}: {}", option, value);
    std::exit(2);
  }
  return parsed;
}

auto parse_sender_args(int argc, char** argv) -> SenderConfig {
  SenderConfig config;
  for (int index = 1; index < argc; ++index) {
    const std::string arg = argv[index];
    auto next = [&]() -> std::string {
      if (index + 1 >= argc) sender_usage_error("missing option value");
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
      config.destinations.push_back(next());
    } else if (arg == "--dest-mac") {
      config.destination_macs.push_back(next());
    } else if (arg == "--port") {
      const auto value = sender_parse_u64(next(), "--port");
      if (value == 0 || value > std::numeric_limits<std::uint16_t>::max()) {
        sender_usage_error("--port must be in 1..65535");
      }
      config.port = static_cast<std::uint16_t>(value);
    } else if (arg == "--datagram-bytes") {
      const auto value = sender_parse_u64(next(), "--datagram-bytes");
      if (value < wire::kMinDatagramBytes ||
          value > wire::kMaxDatagramBytes) {
        sender_usage_error("--datagram-bytes is outside the supported range");
      }
      config.datagram_bytes = static_cast<std::uint32_t>(value);
    } else if (arg == "--count") {
      config.count = sender_parse_u64(next(), "--count");
    } else if (arg == "--from-edge") {
      config.from_edge = true;
    } else if (arg == "--idle-ms") {
      config.idle_ms = sender_parse_u64(next(), "--idle-ms");
    } else if (arg == "--batch-wait-ns") {
      config.batch_wait_ns = sender_parse_u64(next(), "--batch-wait-ns");
      if (config.batch_wait_ns > 1000000) {
        sender_usage_error("--batch-wait-ns must not exceed 1000000");
      }
    } else if (arg == "--batch-target-frames") {
      const auto value = sender_parse_u64(next(), "--batch-target-frames");
      if (value == 0 || value > 64) {
        sender_usage_error("--batch-target-frames must be in 1..64");
      }
      config.batch_target_frames = static_cast<std::uint32_t>(value);
    } else if (arg == "--llq-probe-minimal-wire") {
      config.llq_probe_minimal_wire = true;
    } else if (arg == "--llq-probe-mixed-wire") {
      config.llq_probe_mixed_wire = true;
    } else if (arg == "--compact-wire") {
      config.compact_wire = true;
    } else if (arg == "--compact-wire-mixed") {
      config.compact_wire_mixed = true;
    } else if (arg == "--dpdk-llq-policy") {
      const auto value = sender_parse_u64(next(), "--dpdk-llq-policy");
      if (value > 3) {
        sender_usage_error("--dpdk-llq-policy must be in 0..3");
      }
      config.dpdk_llq_policy = static_cast<std::uint8_t>(value);
    } else if (arg == "--networking-backend") {
      const auto value = next();
      if (value == "socket") {
        config.networking_backend = NetworkingBackend::kSocket;
      } else if (value == "dpdk") {
        config.networking_backend = NetworkingBackend::kDpdk;
      } else {
        sender_usage_error("--networking-backend must be socket or dpdk");
      }
    } else if (arg == "--dpdk-pci") {
      config.dpdk_pci = next();
    } else if (arg == "--source-ip") {
      config.source_ip = next();
    } else if (arg == "--source-mac") {
      config.source_mac = next();
    } else {
      std::println(stderr, "sender: unknown option: {}", arg);
      std::exit(2);
    }
  }

  if ((config.slots & (config.slots - 1)) != 0) {
    sender_usage_error("--slots must be a power of two");
  }
  if (config.destinations.empty()) {
    config.destinations.emplace_back("127.0.0.1");
  }
  if (config.destinations.size() > 3) {
    sender_usage_error("--dest may be specified at most three times");
  }
  if (config.llq_probe_minimal_wire && config.llq_probe_mixed_wire) {
    sender_usage_error(
        "--llq-probe-minimal-wire and --llq-probe-mixed-wire are exclusive");
  }
  if ((config.compact_wire || config.compact_wire_mixed) &&
      (config.llq_probe_minimal_wire || config.llq_probe_mixed_wire)) {
    sender_usage_error(
        "compact wire and LLQ diagnostic formats are exclusive");
  }
  if (config.compact_wire && config.compact_wire_mixed) {
    sender_usage_error(
        "--compact-wire and --compact-wire-mixed are exclusive");
  }
  if (config.networking_backend == NetworkingBackend::kDpdk) {
    if (config.dpdk_pci.empty() || config.source_ip.empty() ||
        config.source_mac.empty()) {
      sender_usage_error(
          "DPDK requires --dpdk-pci, --source-ip and --source-mac");
    }
    if (config.destination_macs.size() != config.destinations.size()) {
      sender_usage_error("DPDK requires one --dest-mac for every --dest");
    }
  } else if (!config.destination_macs.empty()) {
    sender_usage_error("--dest-mac is only valid with DPDK");
  } else if (config.llq_probe_minimal_wire || config.llq_probe_mixed_wire ||
             config.dpdk_llq_policy != 1) {
    sender_usage_error("LLQ probe options are only valid with DPDK");
  }
  if (config.compact_wire_mixed &&
      config.networking_backend != NetworkingBackend::kDpdk) {
    sender_usage_error("--compact-wire-mixed is only valid with DPDK");
  }
  return config;
}

void close_destination_sockets(
    std::vector<DestinationSocket>& destinations) {
  for (auto& destination : destinations) {
    if (destination.fd >= 0) {
      close(destination.fd);
      destination.fd = -1;
    }
  }
}

auto clock_ns(clockid_t clock_id) -> std::uint64_t {
  timespec value{};
  if (clock_gettime(clock_id, &value) != 0) return 0;
  return static_cast<std::uint64_t>(value.tv_sec) * 1000000000ull +
         static_cast<std::uint64_t>(value.tv_nsec);
}

#if SPECTRAL_HAS_DPDK
void append_compact_segments(std::vector<dpdk::Payload>& segments,
                             const std::uint8_t* frame,
                             std::uint32_t frame_len) {
  segments.push_back(
      dpdk::Payload{.data = frame, .length = wire::kCompactHeaderBytes});
  if (frame_len == sizeof(msg::Trade) || frame_len == sizeof(msg::Bbo)) {
    segments.push_back(dpdk::Payload{
        .data = frame + sizeof(msg::Header),
        .length = static_cast<std::uint32_t>(frame_len - sizeof(msg::Header)),
    });
    return;
  }
  // OrderBook omits Header::reserved, OrderBook::reserved and both trailing
  // BookSide::reserved fields.  Port::send_many_scattered copies these ranges
  // straight into the mbuf, so no intermediate compact frame is constructed.
  segments.push_back(dpdk::Payload{.data = frame + 32, .length = 10});
  segments.push_back(dpdk::Payload{.data = frame + 44, .length = 4});
  segments.push_back(dpdk::Payload{
      .data = frame + 48, .length = wire::kCompactBookSideBytes});
  segments.push_back(dpdk::Payload{
      .data = frame + 104, .length = wire::kCompactBookSideBytes});
}
#endif

}  // namespace

auto sender_main(int argc, char** argv) -> int {
  const auto config = parse_sender_args(argc, argv);

  std::vector<DestinationSocket> destinations;
  destinations.reserve(config.destinations.size());
#if SPECTRAL_HAS_DPDK
  std::optional<dpdk::Address> dpdk_source;
  std::vector<dpdk::Address> dpdk_destinations;
  std::unique_ptr<dpdk::Port> dpdk_port;
#endif
  if (config.networking_backend == NetworkingBackend::kSocket) {
    for (const auto& address : config.destinations) {
      sockaddr_in socket_address{};
      socket_address.sin_family = AF_INET;
      socket_address.sin_port = htons(config.port);
      if (inet_pton(AF_INET, address.c_str(), &socket_address.sin_addr) != 1) {
        std::println(stderr, "sender: invalid IPv4 destination: {}", address);
        close_destination_sockets(destinations);
        return 2;
      }

      const int socket_fd = socket(AF_INET, SOCK_DGRAM, 0);
      if (socket_fd < 0) {
        std::println(stderr, "sender: socket failed for {}:{}: {}", address,
                     config.port, std::strerror(errno));
        close_destination_sockets(destinations);
        return 1;
      }
      const int send_buffer = 8 << 20;
      if (setsockopt(socket_fd, SOL_SOCKET, SO_SNDBUF, &send_buffer,
                     sizeof(send_buffer)) != 0) {
        std::println(stderr, "sender: SO_SNDBUF failed for {}: {}", address,
                     std::strerror(errno));
        close(socket_fd);
        close_destination_sockets(destinations);
        return 1;
      }
      const int tos = IPTOS_LOWDELAY;
      if (setsockopt(socket_fd, IPPROTO_IP, IP_TOS, &tos, sizeof(tos)) != 0) {
        std::println(stderr, "sender: IP_TOS failed for {}: {}", address,
                     std::strerror(errno));
        close(socket_fd);
        close_destination_sockets(destinations);
        return 1;
      }
      const int mtu_discovery = IP_PMTUDISC_DO;
      if (setsockopt(socket_fd, IPPROTO_IP, IP_MTU_DISCOVER, &mtu_discovery,
                     sizeof(mtu_discovery)) != 0) {
        std::println(stderr, "sender: IP_MTU_DISCOVER failed for {}: {}",
                     address, std::strerror(errno));
        close(socket_fd);
        close_destination_sockets(destinations);
        return 1;
      }
      if (connect(socket_fd,
                  reinterpret_cast<const sockaddr*>(&socket_address),
                  sizeof(socket_address)) != 0) {
        std::println(stderr, "sender: connect failed for {}:{}: {}", address,
                     config.port, std::strerror(errno));
        close(socket_fd);
        close_destination_sockets(destinations);
        return 1;
      }
      destinations.push_back(
          DestinationSocket{.address = address, .fd = socket_fd});
    }
  } else {
#if SPECTRAL_HAS_DPDK
    dpdk_source = dpdk::parse_address(config.source_ip, config.source_mac);
    if (!dpdk_source) {
      std::println(stderr, "sender: invalid DPDK source address");
      return 2;
    }
    for (std::size_t index = 0; index < config.destinations.size(); ++index) {
      auto destination = dpdk::parse_address(config.destinations[index],
                                             config.destination_macs[index]);
      if (!destination) {
        std::println(stderr, "sender: invalid DPDK destination[{}]", index);
        return 2;
      }
      dpdk_destinations.push_back(*destination);
      destinations.push_back(
          DestinationSocket{.address = config.destinations[index]});
    }
    try {
      dpdk_port = std::make_unique<dpdk::Port>(
          config.dpdk_pci, *dpdk_source, "spectral-sender", false, 32, 0,
          config.dpdk_llq_policy);
    } catch (const std::exception& error) {
      std::println(stderr, "sender: DPDK initialization failed: {}",
                   error.what());
      return 1;
    }
#else
    std::println(stderr, "sender: this build does not include DPDK support");
    return 2;
#endif
  }

  auto segment = shm::Segment::open(
      config.shm_name, shm::spsc::sequence_region_size(config.slots),
      /*create=*/false);
  const auto* shared_header =
      static_cast<const shm::spsc::Header*>(segment.base());
  if (shared_header->magic != shm::spsc::kMagic ||
      shared_header->slot_count != config.slots ||
      shared_header->slot_size != sizeof(shm::spsc::SequenceSlot)) {
    std::println(stderr,
                 "sender: incompatible shared-memory layout: magic={:#x} "
                 "slots={} slot_size={} expected_slot_size={}",
                 shared_header->magic, shared_header->slot_count,
                 shared_header->slot_size, sizeof(shm::spsc::SequenceSlot));
    close_destination_sockets(destinations);
    return 1;
  }
  shm::spsc::SequenceRing ring;
  ring.attach(segment.base(), config.slots, /*init=*/false);

  auto read_index = config.from_edge ? ring.live_edge() : 0;
  std::uint64_t processed = 0;
  std::uint64_t forwarded = 0;
  std::uint64_t datagrams_built = 0;
  std::uint64_t datagrams_forwarded = 0;
  std::uint64_t network_send_calls = 0;
  std::uint64_t bytes_forwarded = 0;
  std::uint64_t send_errors = 0;
  std::uint64_t partially_forwarded = 0;
  std::uint64_t lapped_events = 0;
  auto last_progress = util::now_ns();
  const auto idle_ns = config.idle_ms * 1000000ull;
#if SPECTRAL_HAS_DPDK
  std::uint64_t dpdk_batch_wait_cycles = 0;
  if (config.networking_backend == NetworkingBackend::kDpdk &&
      config.batch_wait_ns != 0) {
    // This deadline is local to a pinned data-plane thread.  It does not need
    // the synchronized CLOCK_REALTIME used by cross-host wire timestamps.
    const auto cycles_per_second = rte_get_tsc_hz();
    constexpr std::uint64_t kNanosecondsPerSecond = 1000000000ull;
    dpdk_batch_wait_cycles =
        (config.batch_wait_ns * cycles_per_second +
         kNanosecondsPerSecond - 1) /
        kNanosecondsPerSecond;
  }
#endif
  constexpr std::size_t kMaxDpdkBurst = 32;
  struct ReadyDatagram {
    std::uint8_t* bytes = nullptr;
    std::uint32_t length = 0;
    std::uint16_t frames = 0;
    bool minimal_wire = false;
    bool compact_wire = false;
    wire::DatagramHeader header{};
  };
  std::vector<std::vector<std::uint8_t>> datagram_buffers;
  std::vector<wire::Packer> packers;
  datagram_buffers.reserve(kMaxDpdkBurst);
  packers.reserve(kMaxDpdkBurst);
  for (std::size_t index = 0; index < kMaxDpdkBurst; ++index) {
    datagram_buffers.emplace_back(config.datagram_bytes);
    packers.emplace_back(datagram_buffers.back().data(), config.datagram_bytes);
  }
  std::array<ReadyDatagram, kMaxDpdkBurst> ready_datagrams{};
  std::array<std::size_t, kMaxDpdkBurst> receivers_reached{};
#if SPECTRAL_HAS_DPDK
  std::array<std::vector<dpdk::Payload>, kMaxDpdkBurst> dpdk_segments;
  std::array<std::vector<std::uint64_t>, kMaxDpdkBurst> dpdk_frame_indices;
  std::array<std::vector<std::uint8_t>, kMaxDpdkBurst> dpdk_encoded_frames;
  std::array<dpdk::ScatterPayload, kMaxDpdkBurst> dpdk_payloads{};
  for (auto& segments : dpdk_segments) {
    segments.reserve(wire::kMaxFramesPerDatagram * 5 + 1);
  }
  for (auto& indices : dpdk_frame_indices) {
    indices.reserve(wire::kMaxFramesPerDatagram);
  }
  for (auto& frames : dpdk_encoded_frames) {
    frames.reserve(config.datagram_bytes - sizeof(wire::DatagramHeader));
  }
#endif

  std::println(stderr,
               "sender: shm={} slots={} destinations={} port={} count={} "
               "datagram_bytes={} from_edge={} rotate_first=yes batching={} "
               "batch_wait_ns={} batch_target_frames={} "
               "llq_probe_minimal_wire={} llq_probe_mixed_wire={} "
               "compact_wire={} "
               "compact_wire_mixed={} "
               "dpdk_llq_policy={} networking_backend={}",
               config.shm_name, config.slots, destinations.size(), config.port,
               config.count, config.datagram_bytes,
               config.from_edge ? "yes" : "no",
               config.batch_wait_ns == 0 ? "opportunistic" : "bounded-target",
               config.batch_wait_ns, config.batch_target_frames,
               config.llq_probe_minimal_wire ? "yes" : "no",
               config.llq_probe_mixed_wire ? "yes" : "no",
               config.compact_wire ? "yes" : "no",
               config.compact_wire_mixed ? "yes" : "no",
               config.dpdk_llq_policy,
               config.networking_backend == NetworkingBackend::kSocket
                   ? "socket"
                   : "dpdk");
  for (std::size_t index = 0; index < destinations.size(); ++index) {
    std::println(stderr, "sender: destination[{}]={}:{}", index,
                 destinations[index].address, config.port);
  }
  const auto wall_started_ns = clock_ns(CLOCK_MONOTONIC_RAW);
  const auto cpu_started_ns = clock_ns(CLOCK_THREAD_CPUTIME_ID);
#if SPECTRAL_HAS_DPDK
  if (dpdk_port) {
    dpdk_port->prime_transmit(kMaxDpdkBurst * destinations.size());
  }
#endif
  ring.activate_reader();

  while (config.count == 0 || processed < config.count) {
    const auto burst_limit =
        config.networking_backend == NetworkingBackend::kDpdk
            ? kMaxDpdkBurst
            : std::size_t{1};
    std::size_t ready_count = 0;
    while (ready_count < burst_limit &&
           (config.count == 0 || processed < config.count)) {
      auto& packer = packers[ready_count];
      auto& ready = ready_datagrams[ready_count];
      ready = ReadyDatagram{};
      if (config.networking_backend == NetworkingBackend::kSocket) {
        packer.reset(datagrams_built + ready_count + 1,
                     config.compact_wire);
      } else {
#if SPECTRAL_HAS_DPDK
        auto& segments = dpdk_segments[ready_count];
        segments.clear();
        segments.push_back({});
        dpdk_frame_indices[ready_count].clear();
        dpdk_encoded_frames[ready_count].clear();
        ready.length = sizeof(wire::DatagramHeader);
#endif
      }
      std::uint64_t batch_wait_started = 0;

      while (config.count == 0 || processed < config.count) {
        // Within-run wire comparisons keep exactly one event per datagram so
        // each latency observation belongs unambiguously to one encoding.
        if ((config.llq_probe_mixed_wire || config.compact_wire_mixed) &&
            ready.frames != 0) {
          break;
        }
        const std::uint8_t* frame = nullptr;
        std::uint32_t frame_len = 0;
        std::uint64_t resume_at = 0;
        const auto status =
            ring.acquire(read_index, &frame, &frame_len, &resume_at);
        if (status == shm::spsc::SequenceRing::FrameStatus::kEmpty) {
          if (ready.frames == 0 || config.batch_wait_ns == 0 ||
              ready.frames >= config.batch_target_frames) {
            break;
          }
#if SPECTRAL_HAS_DPDK
          if (config.networking_backend == NetworkingBackend::kDpdk) {
            const auto now_cycles = rte_rdtsc();
            if (batch_wait_started == 0) batch_wait_started = now_cycles;
            if (now_cycles - batch_wait_started >= dpdk_batch_wait_cycles) {
              break;
            }
            continue;
          }
#endif
          const auto now_ns = util::now_ns();
          if (batch_wait_started == 0) batch_wait_started = now_ns;
          if (now_ns - batch_wait_started >= config.batch_wait_ns) break;
          continue;
        }
        if (status == shm::spsc::SequenceRing::FrameStatus::kLapped) {
          ++lapped_events;
          read_index = resume_at;
          continue;
        }
        if (frame_len < sizeof(msg::Header) ||
            msg::frame_size(
                reinterpret_cast<const msg::Header*>(frame)->type) !=
                frame_len) {
          std::println(stderr, "sender: invalid frame at ring index {}",
                       read_index);
          close_destination_sockets(destinations);
          return 1;
        }
        if (ready.frames == 0) {
          const auto seq_id =
              reinterpret_cast<const msg::Header*>(frame)->seq_id;
          // ABBA rather than simple odd/even assignment balances both modes
          // across adjacent producer phases while remaining trivial to split.
          ready.minimal_wire = config.llq_probe_minimal_wire ||
                               (config.llq_probe_mixed_wire &&
                                ((seq_id & 3u) == 0 || (seq_id & 3u) == 3));
          ready.compact_wire =
              config.compact_wire ||
              (config.compact_wire_mixed &&
               ((seq_id & 3u) == 0 || (seq_id & 3u) == 3));
        }
        const auto wire_frame_len =
            ready.minimal_wire
                ? wire::kMinimalFrameBytes
                : (ready.compact_wire
                       ? wire::compact_frame_size_from_native(frame_len)
                       : frame_len);
        const bool has_room =
            config.networking_backend == NetworkingBackend::kSocket
                ? packer.has_room(frame_len)
                : ready.length + wire_frame_len <= config.datagram_bytes;
        if (!has_room) break;

        if (config.networking_backend == NetworkingBackend::kSocket) {
          packer.add(frame, frame_len);
          ring.commit(read_index);
        } else {
#if SPECTRAL_HAS_DPDK
          if (ready.minimal_wire) {
            auto& encoded_frames = dpdk_encoded_frames[ready_count];
            const auto old_size = encoded_frames.size();
            encoded_frames.resize(old_size + wire_frame_len);
            wire::encode_minimal_frame(frame,
                                       encoded_frames.data() + old_size);
          } else if (ready.compact_wire) {
            append_compact_segments(dpdk_segments[ready_count], frame,
                                    frame_len);
          } else {
            dpdk_segments[ready_count].push_back(
                dpdk::Payload{.data = frame, .length = frame_len});
          }
          dpdk_frame_indices[ready_count].push_back(read_index);
          ready.length += wire_frame_len;
#endif
        }
        ++ready.frames;
        ++read_index;
        ++processed;
      }

      if (ready.frames == 0) break;
      const auto transport_send_ts_ns = util::now_ns();
      if (config.networking_backend == NetworkingBackend::kSocket) {
        ready.bytes = packer.finish(transport_send_ts_ns, &ready.length);
      } else {
#if SPECTRAL_HAS_DPDK
        ready.header = wire::make_datagram_header(
            datagrams_built + ready_count + 1, ready.frames,
            ready.length - sizeof(wire::DatagramHeader),
            transport_send_ts_ns,
            ready.minimal_wire
                ? wire::kFlagMinimalFrames
                : (ready.compact_wire ? wire::kFlagCompactFrames : 0));
        auto& segments = dpdk_segments[ready_count];
        segments[0] = dpdk::Payload{
            .data = reinterpret_cast<const std::uint8_t*>(&ready.header),
            .length = sizeof(ready.header),
        };
        if (ready.minimal_wire) {
          const auto& encoded_frames = dpdk_encoded_frames[ready_count];
          segments.push_back(dpdk::Payload{
              .data = encoded_frames.data(),
              .length = static_cast<std::uint32_t>(encoded_frames.size()),
          });
        }
        dpdk_payloads[ready_count].segments =
            std::span<const dpdk::Payload>(segments.data(), segments.size());
#endif
      }
      last_progress = transport_send_ts_ns;
      ++ready_count;
    }

    if (ready_count == 0) {
#if SPECTRAL_HAS_DPDK
      if (dpdk_port) {
        dpdk_port->prime_transmit(kMaxDpdkBurst * destinations.size());
      }
#endif
      if (config.idle_ms != 0 && util::now_ns() - last_progress > idle_ns) {
        break;
      }
      continue;
    }

    std::fill_n(receivers_reached.begin(), ready_count, std::size_t{0});
    const auto first_destination =
        static_cast<std::size_t>(datagrams_built % destinations.size());
    if (config.networking_backend == NetworkingBackend::kSocket) {
      for (std::size_t offset = 0; offset < destinations.size(); ++offset) {
        const auto destination_index =
            (first_destination + offset) % destinations.size();
        auto& destination = destinations[destination_index];
        std::size_t sent_count = 0;
        ++network_send_calls;
        ssize_t sent = -1;
        do {
          sent = send(destination.fd, ready_datagrams[0].bytes,
                      ready_datagrams[0].length, 0);
        } while (sent < 0 && errno == EINTR);
        if (sent == static_cast<ssize_t>(ready_datagrams[0].length)) {
          sent_count = 1;
        }
        for (std::size_t index = 0; index < sent_count; ++index) {
          destination.forwarded += ready_datagrams[index].frames;
          ++destination.datagrams;
          ++datagrams_forwarded;
          bytes_forwarded += ready_datagrams[index].length;
          ++receivers_reached[index];
        }
        const auto failed_count = ready_count - sent_count;
        destination.send_errors += failed_count;
        send_errors += failed_count;
        if (failed_count != 0) {
          std::println(stderr,
                       "sender: {} of {} datagrams failed for destination[{}] "
                       "near ring index {} on socket backend",
                       failed_count, ready_count, destination_index,
                       read_index);
        }
      }
    } else {
#if SPECTRAL_HAS_DPDK
      ++network_send_calls;
      const auto sent_packets = dpdk_port->send_fanout_scattered(
          std::span<const dpdk::ScatterPayload>(dpdk_payloads.data(),
                                                ready_count),
          *dpdk_source,
          std::span<const dpdk::Address>(dpdk_destinations.data(),
                                         dpdk_destinations.size()),
          first_destination, config.port, config.port);
      const auto requested_packets = ready_count * destinations.size();
      for (std::size_t packet_index = 0; packet_index < sent_packets;
           ++packet_index) {
        const auto datagram_index = packet_index / destinations.size();
        const auto offset = packet_index % destinations.size();
        const auto destination_index =
            (first_destination + datagram_index + offset) %
            destinations.size();
        auto& destination = destinations[destination_index];
        destination.forwarded += ready_datagrams[datagram_index].frames;
        ++destination.datagrams;
        ++datagrams_forwarded;
        bytes_forwarded += ready_datagrams[datagram_index].length;
        ++receivers_reached[datagram_index];
      }
      for (std::size_t packet_index = sent_packets;
           packet_index < requested_packets; ++packet_index) {
        const auto datagram_index = packet_index / destinations.size();
        const auto offset = packet_index % destinations.size();
        const auto destination_index =
            (first_destination + datagram_index + offset) %
            destinations.size();
        ++destinations[destination_index].send_errors;
        ++send_errors;
      }
      if (sent_packets != requested_packets) {
        std::println(stderr,
                     "sender: {} of {} fan-out packets failed near ring "
                     "index {} on dpdk backend",
                     requested_packets - sent_packets, requested_packets,
                     read_index);
      }
#endif
    }

#if SPECTRAL_HAS_DPDK
    if (config.networking_backend == NetworkingBackend::kDpdk) {
      for (std::size_t index = 0; index < ready_count; ++index) {
        for (const auto frame_index : dpdk_frame_indices[index]) {
          ring.commit(frame_index);
        }
      }
    }
#endif

    for (std::size_t index = 0; index < ready_count; ++index) {
      if (receivers_reached[index] == destinations.size()) {
        forwarded += ready_datagrams[index].frames;
      } else if (receivers_reached[index] != 0) {
        partially_forwarded += ready_datagrams[index].frames;
      }
    }
    datagrams_built += ready_count;
  }

  const auto wall_elapsed_ns =
      clock_ns(CLOCK_MONOTONIC_RAW) - wall_started_ns;
  const auto cpu_elapsed_ns =
      clock_ns(CLOCK_THREAD_CPUTIME_ID) - cpu_started_ns;
  close_destination_sockets(destinations);
  const double frames_per_datagram =
      datagrams_built == 0
          ? 0.0
          : static_cast<double>(processed) /
                static_cast<double>(datagrams_built);
  const double datagrams_per_send_call =
      network_send_calls == 0
          ? 0.0
          : static_cast<double>(datagrams_forwarded) /
                static_cast<double>(network_send_calls);
  std::println(stderr,
               "sender: processed={} forwarded={} datagrams_built={} "
               "datagrams_forwarded={} bytes_forwarded={} "
               "frames_per_datagram={:.3f} partially_forwarded={} "
               "send_errors={} lapped={} network_send_calls={} "
               "datagrams_per_send_call={:.3f}",
               processed, forwarded, datagrams_built, datagrams_forwarded,
               bytes_forwarded, frames_per_datagram, partially_forwarded,
               send_errors, lapped_events, network_send_calls,
               datagrams_per_send_call);
  const double effective_frames_per_second =
      wall_elapsed_ns == 0
          ? 0.0
          : static_cast<double>(processed) * 1000000000.0 /
                static_cast<double>(wall_elapsed_ns);
  const double cpu_percent =
      wall_elapsed_ns == 0
          ? 0.0
          : static_cast<double>(cpu_elapsed_ns) * 100.0 /
                static_cast<double>(wall_elapsed_ns);
  std::println(stderr,
               "sender: wall_ns={} thread_cpu_ns={} cpu_percent={:.2f} "
               "effective_frames_per_second={:.0f}",
               wall_elapsed_ns, cpu_elapsed_ns, cpu_percent,
               effective_frames_per_second);
  for (std::size_t index = 0; index < destinations.size(); ++index) {
    const auto& destination = destinations[index];
    std::println(stderr,
                 "sender: destination[{}]={}:{} forwarded={} datagrams={} "
                 "send_errors={}",
                 index, destination.address, config.port,
                 destination.forwarded, destination.datagrams,
                 destination.send_errors);
  }
#if SPECTRAL_HAS_DPDK
  if (dpdk_port) {
    const auto stats = dpdk_port->stats();
    std::println(stderr,
                 "sender: dpdk_rx={} dpdk_tx={} dpdk_imissed={} "
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
  return send_errors == 0 ? 0 : 1;
}

}  // namespace spectral::transport
