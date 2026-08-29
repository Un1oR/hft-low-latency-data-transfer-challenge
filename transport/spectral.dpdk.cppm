module;

#include <arpa/inet.h>
#include <netinet/ip.h>
#include <sched.h>
#include <time.h>

#include <rte_byteorder.h>
#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_ethdev.h>
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_mbuf.h>
#include <rte_mbuf_dyn.h>
#include <rte_pause.h>
#include <rte_udp.h>

export module spectral.dpdk;

import std;

export namespace spectral::dpdk {

struct Address {
  std::array<std::uint8_t, RTE_ETHER_ADDR_LEN> mac{};
  std::uint32_t ipv4_be = 0;

  bool operator==(const Address&) const = default;
};

enum class ReceiveStatus { kEmpty, kPacket, kInvalid };

struct ReceiveResult {
  ReceiveStatus status = ReceiveStatus::kEmpty;
  const std::uint8_t* data = nullptr;
  std::uint32_t length = 0;
  std::uint64_t hardware_timestamp_ns = 0;
  std::uint64_t burst_return_realtime_ns = 0;
};

struct Stats {
  std::uint64_t packets_received = 0;
  std::uint64_t packets_sent = 0;
  std::uint64_t packets_missed = 0;
  std::uint64_t receive_errors = 0;
  std::uint64_t send_errors = 0;
  std::uint64_t receive_nombuf = 0;
  std::uint64_t bw_in_allowance_exceeded = 0;
  std::uint64_t bw_out_allowance_exceeded = 0;
  std::uint64_t pps_allowance_exceeded = 0;
  std::uint64_t conntrack_allowance_exceeded = 0;
  std::uint64_t linklocal_allowance_exceeded = 0;
};

struct Payload {
  const std::uint8_t* data = nullptr;
  std::uint32_t length = 0;
};

struct ScatterPayload {
  std::span<const Payload> segments;
};

auto parse_address(std::string_view ipv4, std::string_view mac)
    -> std::optional<Address>;

class Port {
 public:
  Port(std::string_view pci_address, const Address& local,
       std::string_view file_prefix, bool receive_hardware_timestamps = false,
       std::uint16_t receive_burst_size = 32,
       std::uint16_t receive_free_threshold = 0,
       std::uint8_t llq_policy = 1);
  ~Port();

  Port(const Port&) = delete;
  auto operator=(const Port&) -> Port& = delete;
  Port(Port&&) = delete;
  auto operator=(Port&&) -> Port& = delete;

  [[nodiscard]] auto send(std::span<const std::uint8_t> payload,
                          const Address& source, const Address& destination,
                          std::uint16_t source_port,
                          std::uint16_t destination_port) -> bool;
  [[nodiscard]] auto send_many(std::span<const Payload> payloads,
                               const Address& source,
                               const Address& destination,
                               std::uint16_t source_port,
                               std::uint16_t destination_port) -> std::size_t;
  [[nodiscard]] auto send_many_scattered(
      std::span<const ScatterPayload> payloads, const Address& source,
      const Address& destination, std::uint16_t source_port,
      std::uint16_t destination_port) -> std::size_t;
  [[nodiscard]] auto send_fanout_scattered(
      std::span<const ScatterPayload> payloads, const Address& source,
      std::span<const Address> destinations, std::size_t first_destination,
      std::uint16_t source_port, std::uint16_t destination_port)
      -> std::size_t;
  void prime_transmit(std::size_t count);
  [[nodiscard]] auto receive(const Address& local,
                             std::uint16_t destination_port) -> ReceiveResult;
  void release_received();
  [[nodiscard]] auto stats() const -> Stats;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace spectral::dpdk

namespace spectral::dpdk {
namespace {

auto as_ether_address(const Address& address) -> rte_ether_addr {
  rte_ether_addr result{};
  std::memcpy(result.addr_bytes, address.mac.data(), address.mac.size());
  return result;
}

[[noreturn]] void fail(std::string_view operation, int error) {
  throw std::runtime_error(
      std::format("{} failed: {}", operation, rte_strerror(-error)));
}

void pin_current_thread(int cpu) {
  cpu_set_t cpus;
  CPU_ZERO(&cpus);
  CPU_SET(cpu, &cpus);
  if (sched_setaffinity(0, sizeof(cpus), &cpus) != 0 ||
      sched_getcpu() != cpu) {
    throw std::runtime_error(
        std::format("failed to pin DPDK main thread to CPU {}", cpu));
  }
}

}  // namespace

struct Port::Impl {
  static constexpr std::uint16_t kQueueId = 0;
  static constexpr std::uint16_t kDescriptorCount = 1024;
  static constexpr std::uint16_t kBurstSize = 32;
  static constexpr std::uint16_t kMaxFanout = 3;
  static constexpr std::uint16_t kMaxTransmitBurst =
      kBurstSize * kMaxFanout;
  static constexpr std::size_t kPacketHeaderBytes =
      sizeof(rte_ether_hdr) + sizeof(rte_ipv4_hdr) + sizeof(rte_udp_hdr);

  struct HeaderTemplate {
    Address source;
    Address destination;
    std::uint16_t source_port = 0;
    std::uint16_t destination_port = 0;
    alignas(4) std::array<std::uint8_t, kPacketHeaderBytes> bytes{};
  };

  std::uint16_t port_id = RTE_MAX_ETHPORTS;
  rte_mempool* pool = nullptr;
  std::array<rte_mbuf*, kMaxTransmitBurst> transmit_reserve{};
  std::uint16_t transmit_reserve_count = 0;
  std::vector<HeaderTemplate> header_templates;
  std::array<rte_mbuf*, kBurstSize> pending{};
  std::uint16_t pending_index = 0;
  std::uint16_t pending_count = 0;
  std::uint64_t pending_burst_return_realtime_ns = 0;
  rte_mbuf* borrowed = nullptr;
  rte_eth_stats initial_stats{};
  std::unordered_map<std::uint64_t, std::uint64_t> initial_xstats;
  bool ipv4_checksum_offload = false;
  bool receive_hardware_timestamps = false;
  std::uint16_t receive_burst_size = kBurstSize;
  std::uint16_t receive_free_threshold = 0;
  int receive_timestamp_offset = -1;
  std::uint64_t receive_timestamp_flag = 0;
  bool eal_ready = false;

  auto header_template(const Address& source, const Address& destination,
                       std::uint16_t source_port,
                       std::uint16_t destination_port)
      -> const HeaderTemplate& {
    auto found = std::find_if(
        header_templates.begin(), header_templates.end(),
        [&](const HeaderTemplate& candidate) {
          return candidate.source == source &&
                 candidate.destination == destination &&
                 candidate.source_port == source_port &&
                 candidate.destination_port == destination_port;
        });
    if (found != header_templates.end()) return *found;

    HeaderTemplate item{
        .source = source,
        .destination = destination,
        .source_port = source_port,
        .destination_port = destination_port,
    };
    auto* ethernet = reinterpret_cast<rte_ether_hdr*>(item.bytes.data());
    ethernet->src_addr = as_ether_address(source);
    ethernet->dst_addr = as_ether_address(destination);
    ethernet->ether_type = rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4);

    auto* ipv4 = reinterpret_cast<rte_ipv4_hdr*>(ethernet + 1);
    *ipv4 = rte_ipv4_hdr{};
    ipv4->version_ihl = RTE_IPV4_VHL_DEF;
    ipv4->type_of_service = IPTOS_LOWDELAY;
    ipv4->fragment_offset = rte_cpu_to_be_16(RTE_IPV4_HDR_DF_FLAG);
    ipv4->time_to_live = 64;
    ipv4->next_proto_id = IPPROTO_UDP;
    ipv4->src_addr = source.ipv4_be;
    ipv4->dst_addr = destination.ipv4_be;

    auto* udp = reinterpret_cast<rte_udp_hdr*>(ipv4 + 1);
    udp->src_port = rte_cpu_to_be_16(source_port);
    udp->dst_port = rte_cpu_to_be_16(destination_port);
    udp->dgram_cksum = 0;
    header_templates.push_back(item);
    return header_templates.back();
  }

  auto prepare_packet(const ScatterPayload& payload,
                      const HeaderTemplate& header_template) -> rte_mbuf* {
    std::uint32_t payload_length = 0;
    if (payload.segments.empty()) return nullptr;
    for (const auto& segment : payload.segments) {
      if (segment.data == nullptr ||
          segment.length > RTE_ETHER_MTU - sizeof(rte_ipv4_hdr) -
                               sizeof(rte_udp_hdr) - payload_length) {
        return nullptr;
      }
      payload_length += segment.length;
    }

    auto* mbuf = transmit_reserve_count == 0
                     ? rte_pktmbuf_alloc(pool)
                     : transmit_reserve[--transmit_reserve_count];
    if (mbuf == nullptr) return nullptr;
    const auto packet_length = kPacketHeaderBytes + payload_length;
    auto* packet =
        rte_pktmbuf_append(mbuf, static_cast<std::uint16_t>(packet_length));
    if (packet == nullptr) {
      rte_pktmbuf_free(mbuf);
      return nullptr;
    }

    std::memcpy(packet, header_template.bytes.data(), kPacketHeaderBytes);
    auto* ethernet = reinterpret_cast<rte_ether_hdr*>(packet);
    auto* ipv4 = reinterpret_cast<rte_ipv4_hdr*>(ethernet + 1);
    ipv4->total_length = rte_cpu_to_be_16(static_cast<std::uint16_t>(
        sizeof(rte_ipv4_hdr) + sizeof(rte_udp_hdr) + payload_length));
    ipv4->hdr_checksum = 0;

    auto* udp = reinterpret_cast<rte_udp_hdr*>(ipv4 + 1);
    udp->dgram_len = rte_cpu_to_be_16(static_cast<std::uint16_t>(
        sizeof(rte_udp_hdr) + payload_length));
    if (ipv4_checksum_offload) {
      mbuf->ol_flags = RTE_MBUF_F_TX_IPV4 | RTE_MBUF_F_TX_IP_CKSUM;
      mbuf->l2_len = sizeof(rte_ether_hdr);
      mbuf->l3_len = sizeof(rte_ipv4_hdr);
    } else {
      ipv4->hdr_checksum = rte_ipv4_cksum(ipv4);
    }
    auto* output = reinterpret_cast<std::uint8_t*>(udp + 1);
    for (const auto& segment : payload.segments) {
      if (segment.length == 32) {
        __builtin_memcpy(output, segment.data, 32);
      } else if (segment.length == 64) {
        __builtin_memcpy(output, segment.data, 64);
      } else if (segment.length == 80) {
        __builtin_memcpy(output, segment.data, 80);
      } else if (segment.length == 160) {
        __builtin_memcpy(output, segment.data, 160);
      } else {
        std::memcpy(output, segment.data, segment.length);
      }
      output += segment.length;
    }
    return mbuf;
  }

  auto transmit(std::span<rte_mbuf*> packets) -> std::size_t {
    std::uint16_t sent = 0;
    const auto count = static_cast<std::uint16_t>(packets.size());
    for (std::uint32_t attempt = 0; sent < count && attempt < 1024;
         ++attempt) {
      sent += rte_eth_tx_burst(port_id, kQueueId, packets.data() + sent,
                               count - sent);
      if (sent < count) rte_pause();
    }
    for (std::uint16_t index = sent; index < count; ++index) {
      rte_pktmbuf_free(packets[index]);
    }
    return sent;
  }
};

auto parse_address(std::string_view ipv4, std::string_view mac)
    -> std::optional<Address> {
  Address result;
  const std::string ipv4_string(ipv4);
  if (inet_pton(AF_INET, ipv4_string.c_str(), &result.ipv4_be) != 1) {
    return std::nullopt;
  }
  const std::string mac_string(mac);
  rte_ether_addr parsed_mac{};
  if (rte_ether_unformat_addr(mac_string.c_str(), &parsed_mac) != 0) {
    return std::nullopt;
  }
  std::memcpy(result.mac.data(), parsed_mac.addr_bytes, result.mac.size());
  return result;
}

Port::Port(std::string_view pci_address, const Address& local,
           std::string_view file_prefix, bool receive_hardware_timestamps,
           std::uint16_t receive_burst_size,
           std::uint16_t receive_free_threshold, std::uint8_t llq_policy)
    : impl_(std::make_unique<Impl>()) {
  if (receive_burst_size == 0 || receive_burst_size > Impl::kBurstSize) {
    throw std::invalid_argument(std::format(
        "receive burst size must be in 1..{}", Impl::kBurstSize));
  }
  if (receive_free_threshold >= Impl::kDescriptorCount) {
    throw std::invalid_argument(std::format(
        "receive free threshold must be below {}",
        Impl::kDescriptorCount));
  }
  if (llq_policy > 3) {
    throw std::invalid_argument("LLQ policy must be in 0..3");
  }
  impl_->receive_burst_size = receive_burst_size;
  impl_->receive_free_threshold = receive_free_threshold;
  const int cpu = sched_getcpu();
  if (cpu < 0) throw std::runtime_error("sched_getcpu failed");

  const auto device_argument =
      std::format("{},llq_policy={}", pci_address, llq_policy);
  std::vector<std::string> arguments{
      "spectral-dpdk",       "-l",
      std::to_string(cpu),    "--main-lcore",
      std::to_string(cpu),    "--file-prefix",
      std::string(file_prefix), "--huge-dir",
      "/dev/hugepages",      "--no-telemetry",
      "--log-level",         "lib.eal:warning",
      "--log-level",         "pmd.net.ena:warning",
      "-a",                  device_argument,
  };
  std::vector<char*> argument_pointers;
  argument_pointers.reserve(arguments.size());
  for (auto& argument : arguments) argument_pointers.push_back(argument.data());

  const int eal_result = rte_eal_init(
      static_cast<int>(argument_pointers.size()), argument_pointers.data());
  if (eal_result < 0) {
    throw std::runtime_error(
        std::format("rte_eal_init failed: {}", rte_strerror(rte_errno)));
  }
  impl_->eal_ready = true;
  // EAL is allowed to adjust the main lcore's affinity while it initializes.
  // Make the benchmark contract explicit after EAL has finished doing so.
  pin_current_thread(cpu);

  if (rte_eth_dev_count_avail() != 1) {
    throw std::runtime_error(std::format(
        "expected exactly one DPDK port, found {}", rte_eth_dev_count_avail()));
  }
  RTE_ETH_FOREACH_DEV(impl_->port_id) { break; }
  if (impl_->port_id == RTE_MAX_ETHPORTS) {
    throw std::runtime_error("DPDK port not found");
  }

  const std::string pool_name = std::string(file_prefix) + "-mbufs";
  impl_->pool = rte_pktmbuf_pool_create(
      pool_name.c_str(), 16383, 256, 0, RTE_MBUF_DEFAULT_BUF_SIZE,
      rte_socket_id());
  if (impl_->pool == nullptr) {
    throw std::runtime_error(std::format("rte_pktmbuf_pool_create failed: {}",
                                         rte_strerror(rte_errno)));
  }

  rte_eth_dev_info device_info{};
  int result = rte_eth_dev_info_get(impl_->port_id, &device_info);
  if (result != 0) fail("rte_eth_dev_info_get", result);

  rte_eth_conf port_config{};
  port_config.rxmode.mq_mode = RTE_ETH_MQ_RX_NONE;
  port_config.txmode.mq_mode = RTE_ETH_MQ_TX_NONE;
  if (receive_hardware_timestamps) {
    if ((device_info.rx_offload_capa & RTE_ETH_RX_OFFLOAD_TIMESTAMP) == 0) {
      throw std::runtime_error(
          "DPDK port does not support hardware RX timestamps");
    }
    result = rte_mbuf_dyn_rx_timestamp_register(
        &impl_->receive_timestamp_offset,
        &impl_->receive_timestamp_flag);
    if (result != 0) fail("rte_mbuf_dyn_rx_timestamp_register", result);
    port_config.rxmode.offloads |= RTE_ETH_RX_OFFLOAD_TIMESTAMP;
    impl_->receive_hardware_timestamps = true;
  }
  if ((device_info.tx_offload_capa & RTE_ETH_TX_OFFLOAD_IPV4_CKSUM) != 0) {
    port_config.txmode.offloads |= RTE_ETH_TX_OFFLOAD_IPV4_CKSUM;
    impl_->ipv4_checksum_offload = true;
  }
  result = rte_eth_dev_configure(impl_->port_id, 1, 1, &port_config);
  if (result != 0) fail("rte_eth_dev_configure", result);

  std::uint16_t rx_descriptors = Impl::kDescriptorCount;
  std::uint16_t tx_descriptors = Impl::kDescriptorCount;
  result = rte_eth_dev_adjust_nb_rx_tx_desc(
      impl_->port_id, &rx_descriptors, &tx_descriptors);
  if (result != 0) fail("rte_eth_dev_adjust_nb_rx_tx_desc", result);

  auto rx_config = device_info.default_rxconf;
  rx_config.offloads = port_config.rxmode.offloads;
  rx_config.rx_free_thresh = impl_->receive_free_threshold;
  result = rte_eth_rx_queue_setup(impl_->port_id, Impl::kQueueId,
                                  rx_descriptors, rte_socket_id(),
                                  &rx_config, impl_->pool);
  if (result != 0) fail("rte_eth_rx_queue_setup", result);
  auto tx_config = device_info.default_txconf;
  tx_config.offloads = port_config.txmode.offloads;
  result = rte_eth_tx_queue_setup(impl_->port_id, Impl::kQueueId,
                                  tx_descriptors, rte_socket_id(),
                                  &tx_config);
  if (result != 0) fail("rte_eth_tx_queue_setup", result);
  result = rte_eth_dev_set_mtu(impl_->port_id, RTE_ETHER_MTU);
  if (result != 0) fail("rte_eth_dev_set_mtu", result);
  result = rte_eth_dev_start(impl_->port_id);
  if (result != 0) fail("rte_eth_dev_start", result);

  rte_eth_link link{};
  bool link_up = false;
  for (std::uint32_t attempt = 0; attempt < 5000; ++attempt) {
    result = rte_eth_link_get_nowait(impl_->port_id, &link);
    if (result != 0) fail("rte_eth_link_get_nowait", result);
    if (link.link_status == RTE_ETH_LINK_UP) {
      link_up = true;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  if (!link_up) {
    throw std::runtime_error("DPDK port did not reach link-up within 5 seconds");
  }

  rte_ether_addr actual_mac{};
  result = rte_eth_macaddr_get(impl_->port_id, &actual_mac);
  if (result != 0) fail("rte_eth_macaddr_get", result);
  const auto expected_mac = as_ether_address(local);
  if (!rte_is_same_ether_addr(&actual_mac, &expected_mac)) {
    throw std::runtime_error("DPDK port MAC does not match configured MAC");
  }
  std::println(stderr,
               "spectral-dpdk: IPv4 checksum offload={} "
               "RX hardware timestamps={} rx_descriptors={} "
               "tx_descriptors={} rx_burst_size={} "
               "rx_free_threshold={}",
               impl_->ipv4_checksum_offload ? "on" : "off",
               impl_->receive_hardware_timestamps ? "on" : "off",
               rx_descriptors, tx_descriptors, impl_->receive_burst_size,
               impl_->receive_free_threshold);

  result = rte_eth_stats_get(impl_->port_id, &impl_->initial_stats);
  if (result != 0) fail("rte_eth_stats_get", result);
  const int xstat_count =
      rte_eth_xstats_get_names(impl_->port_id, nullptr, 0);
  if (xstat_count > 0) {
    std::vector<rte_eth_xstat> initial_xstats(
        static_cast<std::size_t>(xstat_count));
    if (rte_eth_xstats_get(impl_->port_id, initial_xstats.data(),
                           xstat_count) == xstat_count) {
      for (const auto& xstat : initial_xstats) {
        impl_->initial_xstats.emplace(xstat.id, xstat.value);
      }
    }
  }
}

Port::~Port() {
  if (!impl_) return;
  if (impl_->borrowed != nullptr) {
    rte_pktmbuf_free(impl_->borrowed);
    impl_->borrowed = nullptr;
  }
  while (impl_->pending_index < impl_->pending_count) {
    rte_pktmbuf_free(impl_->pending[impl_->pending_index++]);
  }
  while (impl_->transmit_reserve_count != 0) {
    rte_pktmbuf_free(
        impl_->transmit_reserve[--impl_->transmit_reserve_count]);
  }
  if (impl_->port_id != RTE_MAX_ETHPORTS) {
    rte_eth_dev_stop(impl_->port_id);
  }
  // Ubuntu 24.04 ships DPDK 23.11.4. Its ENA close path releases queues before
  // asynchronously unregistering the interrupt callback, which can race in
  // the dpdk-intr thread. This process owns one Port for its whole lifetime,
  // so stop the datapath and let process exit release the remaining EAL state.
}

auto Port::send(std::span<const std::uint8_t> payload,
                const Address& source, const Address& destination,
                std::uint16_t source_port, std::uint16_t destination_port)
    -> bool {
  const Payload item{.data = payload.data(),
                     .length = static_cast<std::uint32_t>(payload.size())};
  return send_many(std::span<const Payload>(&item, 1), source, destination,
                   source_port, destination_port) == 1;
}

auto Port::send_many(std::span<const Payload> payloads,
                     const Address& source, const Address& destination,
                     std::uint16_t source_port, std::uint16_t destination_port)
    -> std::size_t {
  if (payloads.size() > Impl::kBurstSize) {
    throw std::invalid_argument("DPDK burst exceeds configured burst size");
  }
  std::array<ScatterPayload, Impl::kBurstSize> scattered{};
  for (std::size_t index = 0; index < payloads.size(); ++index) {
    scattered[index].segments =
        std::span<const Payload>(&payloads[index], std::size_t{1});
  }
  return send_many_scattered(
      std::span<const ScatterPayload>(scattered.data(), payloads.size()),
      source, destination, source_port, destination_port);
}

auto Port::send_many_scattered(
    std::span<const ScatterPayload> payloads, const Address& source,
    const Address& destination, std::uint16_t source_port,
    std::uint16_t destination_port) -> std::size_t {
  if (payloads.empty()) return 0;
  if (payloads.size() > Impl::kBurstSize) {
    throw std::invalid_argument("DPDK burst exceeds configured burst size");
  }

  std::array<rte_mbuf*, Impl::kBurstSize> packets{};
  std::uint16_t prepared = 0;
  const auto& header_template = impl_->header_template(
      source, destination, source_port, destination_port);
  for (const auto& payload : payloads) {
    auto* packet = impl_->prepare_packet(payload, header_template);
    if (packet == nullptr) break;
    packets[prepared++] = packet;
  }
  return impl_->transmit(
      std::span<rte_mbuf*>(packets.data(), prepared));
}

auto Port::send_fanout_scattered(
    std::span<const ScatterPayload> payloads, const Address& source,
    std::span<const Address> destinations, std::size_t first_destination,
    std::uint16_t source_port, std::uint16_t destination_port) -> std::size_t {
  if (payloads.empty() || destinations.empty()) return 0;
  if (payloads.size() > Impl::kBurstSize) {
    throw std::invalid_argument("DPDK burst exceeds configured burst size");
  }
  if (destinations.size() > Impl::kMaxFanout) {
    throw std::invalid_argument("DPDK fan-out exceeds configured maximum");
  }

  std::array<rte_mbuf*, Impl::kMaxTransmitBurst> packets{};
  std::uint16_t prepared = 0;
  first_destination %= destinations.size();
  for (std::size_t payload_index = 0; payload_index < payloads.size();
       ++payload_index) {
    for (std::size_t offset = 0; offset < destinations.size(); ++offset) {
      const auto destination_index =
          (first_destination + payload_index + offset) % destinations.size();
      const auto& header_template = impl_->header_template(
          source, destinations[destination_index], source_port,
          destination_port);
      auto* packet =
          impl_->prepare_packet(payloads[payload_index], header_template);
      if (packet == nullptr) {
        return impl_->transmit(
            std::span<rte_mbuf*>(packets.data(), prepared));
      }
      packets[prepared++] = packet;
    }
  }
  return impl_->transmit(
      std::span<rte_mbuf*>(packets.data(), prepared));
}

void Port::prime_transmit(std::size_t count) {
  const auto target = static_cast<std::uint16_t>(
      std::min<std::size_t>(count, impl_->transmit_reserve.size()));
  while (impl_->transmit_reserve_count < target) {
    auto* mbuf = rte_pktmbuf_alloc(impl_->pool);
    if (mbuf == nullptr) break;
    impl_->transmit_reserve[impl_->transmit_reserve_count++] = mbuf;
  }
}

auto Port::receive(const Address& local, std::uint16_t destination_port)
    -> ReceiveResult {
  if (impl_->borrowed != nullptr) {
    throw std::logic_error(
        "release_received must be called before the next receive");
  }
  if (impl_->pending_index == impl_->pending_count) {
    impl_->pending_count = rte_eth_rx_burst(
        impl_->port_id, Impl::kQueueId, impl_->pending.data(),
        impl_->receive_burst_size);
    impl_->pending_index = 0;
    if (impl_->pending_count == 0) return {};
    if (impl_->receive_hardware_timestamps) {
      timespec timestamp{};
      if (::clock_gettime(CLOCK_REALTIME, &timestamp) != 0) {
        throw std::runtime_error(std::format(
            "clock_gettime after rte_eth_rx_burst failed: {}",
            std::strerror(errno)));
      }
      impl_->pending_burst_return_realtime_ns =
          static_cast<std::uint64_t>(timestamp.tv_sec) * 1'000'000'000ull +
          static_cast<std::uint64_t>(timestamp.tv_nsec);
    }
  }

  auto* mbuf = impl_->pending[impl_->pending_index++];
  const auto invalid = [&]() {
    rte_pktmbuf_free(mbuf);
    return ReceiveResult{.status = ReceiveStatus::kInvalid};
  };
  if (!rte_pktmbuf_is_contiguous(mbuf)) return invalid();
  const auto packet_length = rte_pktmbuf_pkt_len(mbuf);
  constexpr std::uint32_t kMinimumPacketBytes =
      sizeof(rte_ether_hdr) + sizeof(rte_ipv4_hdr) + sizeof(rte_udp_hdr);
  if (packet_length < kMinimumPacketBytes) return invalid();

  const auto* ethernet = rte_pktmbuf_mtod(mbuf, const rte_ether_hdr*);
  if (ethernet->ether_type != rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4)) {
    return invalid();
  }
  const auto* ipv4 = reinterpret_cast<const rte_ipv4_hdr*>(ethernet + 1);
  if ((ipv4->version_ihl >> 4) != 4 || ipv4->next_proto_id != IPPROTO_UDP ||
      ipv4->dst_addr != local.ipv4_be) {
    return invalid();
  }
  const auto ipv4_header_length =
      static_cast<std::uint32_t>(ipv4->version_ihl & 0x0f) * 4;
  if (ipv4_header_length < sizeof(rte_ipv4_hdr) ||
      packet_length < sizeof(rte_ether_hdr) + ipv4_header_length +
                          sizeof(rte_udp_hdr)) {
    return invalid();
  }
  const auto* udp = reinterpret_cast<const rte_udp_hdr*>(
      reinterpret_cast<const std::uint8_t*>(ipv4) + ipv4_header_length);
  const auto udp_length = rte_be_to_cpu_16(udp->dgram_len);
  if (udp->dst_port != rte_cpu_to_be_16(destination_port) ||
      udp_length < sizeof(rte_udp_hdr) ||
      sizeof(rte_ether_hdr) + ipv4_header_length + udp_length >
          packet_length) {
    return invalid();
  }
  const auto payload_length = udp_length - sizeof(rte_udp_hdr);
  std::uint64_t hardware_timestamp_ns = 0;
  if (impl_->receive_hardware_timestamps &&
      (mbuf->ol_flags & impl_->receive_timestamp_flag) != 0) {
    hardware_timestamp_ns = *RTE_MBUF_DYNFIELD(
        mbuf, impl_->receive_timestamp_offset, rte_mbuf_timestamp_t*);
  }
  impl_->borrowed = mbuf;
  return ReceiveResult{.status = ReceiveStatus::kPacket,
                       .data = reinterpret_cast<const std::uint8_t*>(udp + 1),
                       .length = static_cast<std::uint32_t>(payload_length),
                       .hardware_timestamp_ns = hardware_timestamp_ns,
                       .burst_return_realtime_ns =
                           impl_->pending_burst_return_realtime_ns};
}

void Port::release_received() {
  if (impl_->borrowed == nullptr) return;
  rte_pktmbuf_free(impl_->borrowed);
  impl_->borrowed = nullptr;
}

auto Port::stats() const -> Stats {
  rte_eth_stats raw{};
  if (rte_eth_stats_get(impl_->port_id, &raw) != 0) return {};
  const auto delta = [](std::uint64_t current, std::uint64_t initial) {
    return current >= initial ? current - initial : std::uint64_t{0};
  };
  Stats result{
      .packets_received = delta(raw.ipackets, impl_->initial_stats.ipackets),
      .packets_sent = delta(raw.opackets, impl_->initial_stats.opackets),
      .packets_missed = delta(raw.imissed, impl_->initial_stats.imissed),
      .receive_errors = delta(raw.ierrors, impl_->initial_stats.ierrors),
      .send_errors = delta(raw.oerrors, impl_->initial_stats.oerrors),
      .receive_nombuf = delta(raw.rx_nombuf, impl_->initial_stats.rx_nombuf),
  };
  const int count = rte_eth_xstats_get_names(impl_->port_id, nullptr, 0);
  if (count <= 0) return result;
  std::vector<rte_eth_xstat_name> names(static_cast<std::size_t>(count));
  std::vector<rte_eth_xstat> values(static_cast<std::size_t>(count));
  if (rte_eth_xstats_get_names(impl_->port_id, names.data(), count) != count ||
      rte_eth_xstats_get(impl_->port_id, values.data(), count) != count) {
    return result;
  }
  for (int index = 0; index < count; ++index) {
    const std::string_view name(names[static_cast<std::size_t>(index)].name);
    const auto& xstat = values[static_cast<std::size_t>(index)];
    const auto initial = impl_->initial_xstats.contains(xstat.id)
                             ? impl_->initial_xstats.at(xstat.id)
                             : std::uint64_t{0};
    const auto value = delta(xstat.value, initial);
    if (name == "bw_in_allowance_exceeded") {
      result.bw_in_allowance_exceeded = value;
    } else if (name == "bw_out_allowance_exceeded") {
      result.bw_out_allowance_exceeded = value;
    } else if (name == "pps_allowance_exceeded") {
      result.pps_allowance_exceeded = value;
    } else if (name == "conntrack_allowance_exceeded") {
      result.conntrack_allowance_exceeded = value;
    } else if (name == "linklocal_allowance_exceeded") {
      result.linklocal_allowance_exceeded = value;
    }
  }
  return result;
}

}  // namespace spectral::dpdk
