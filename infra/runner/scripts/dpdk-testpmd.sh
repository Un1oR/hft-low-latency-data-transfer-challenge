#!/bin/sh
# Короткая функциональная проверка data ENI. Это не benchmark.
set -eu

role="${DPDK_PROBE_ROLE:?DPDK_PROBE_ROLE is required}"
peer_mac="${DPDK_PEER_MAC:-}"
source_ip="${DPDK_SOURCE_IP:-}"
destination_ip="${DPDK_DESTINATION_IP:-}"
. /etc/spectral-task/dpdk.env

testpmd_bin="${DPDK_TESTPMD_BIN:-}"
if [ -z "$testpmd_bin" ]; then
  if [ -x /usr/libexec/spectral-task/bin/dpdk-testpmd ]; then
    testpmd_bin=/usr/libexec/spectral-task/bin/dpdk-testpmd
  else
    testpmd_bin="$(command -v dpdk-testpmd)"
  fi
fi
test -x "$testpmd_bin"

test "$(basename "$(readlink -f "/sys/bus/pci/devices/$DATA_PCI/driver")")" = igb_uio
mountpoint -q /dev/hugepages

case "$role" in
  receiver)
    delayed_commands="sleep 5; printf 'show port info all\\nshow port 0 rx_offload capabilities\\nstart\\n'; sleep 15; printf 'stop\\nshow port stats all\\nshow port xstats all\\nquit\\n'"
    forwarding_args="--forward-mode=rxonly"
    ;;
  source)
    if [ -z "$peer_mac" ] || [ -z "$source_ip" ] || [ -z "$destination_ip" ]; then
      echo "Для source нужны DPDK_PEER_MAC, DPDK_SOURCE_IP и DPDK_DESTINATION_IP" >&2
      exit 2
    fi
    delayed_commands="sleep 8; printf 'show port info all\\nshow port 0 rx_offload capabilities\\nstart\\n'; sleep 0.005; printf 'stop\\nshow port stats all\\nshow port xstats all\\nquit\\n'"
    forwarding_args="--forward-mode=txonly --eth-peer=0,$peer_mac --tx-ip=$source_ip,$destination_ip --tx-udp=9000,9000 --txpkts=128 --burst=32"
    ;;
  *)
    echo "DPDK_PROBE_ROLE должен быть source или receiver" >&2
    exit 2
    ;;
esac

log="/tmp/spectral-testpmd-$role.log"
rm -f "$log"
# forwarding_args намеренно разделяется на отдельные CLI arguments.
# shellcheck disable=SC2086
(sh -c "$delayed_commands") |
  "$testpmd_bin" -l 2-3 -n 4 --file-prefix="spectral-$role" \
    -a "$DATA_PCI" -- -i $forwarding_args \
    --rxq=1 --txq=1 --nb-cores=1 >"$log" 2>&1

cat "$log"
rx_timestamp_capable=no
if grep -Eq '^[[:space:]]*Per Port[[:space:]]*:.*[[:space:]]TIMESTAMP([[:space:]]|$)' \
  "$log"; then
  rx_timestamp_capable=yes
fi
if [ "$role" = receiver ]; then
  packets="$(awk '/RX-packets:/ {for (i = 1; i <= NF; ++i) if ($i == "RX-packets:") value = $(i + 1)} END {print value + 0}' "$log")"
else
  packets="$(awk '/TX-packets:/ {for (i = 1; i <= NF; ++i) if ($i == "TX-packets:") value = $(i + 1)} END {print value + 0}' "$log")"
fi
if [ "$packets" -le 0 ]; then
  echo "testpmd не обработал пакеты в роли $role" >&2
  exit 1
fi

printf '%s\n' \
  "dpdk_probe_status=passed" \
  "dpdk_probe_role=$role" \
  "dpdk_probe_packets=$packets" \
  "dpdk_probe_binary=$testpmd_bin" \
  "dpdk_probe_rx_timestamp_capable=$rx_timestamp_capable" \
  "dpdk_probe_data_pci=$DATA_PCI"
