#!/bin/sh
set -eu

bin_dir="/usr/libexec/spectral-task/bin"
log_dir="/tmp/spectral-unicast"
latency_csv="$log_dir/latency.csv"
stage_csv="$log_dir/stage-latency.csv"
ready_file="$log_dir/READY"
shm_name="${RX_SHM:-/spectral_rx}"
slots="${SHM_SLOTS:-65536}"
message_count="${MESSAGE_COUNT:-1000000}"
warmup_events="${WARMUP_EVENTS:-0}"
total_count=$((message_count + warmup_events))
idle_ms="${IDLE_MS:-30000}"
port="${UDP_PORT:-9000}"
stage_timestamps="${STAGE_TIMESTAMPS:-0}"
dpdk_rx_hardware_timestamps="${DPDK_RX_HARDWARE_TIMESTAMPS:-0}"
dpdk_rx_burst_size="${DPDK_RX_BURST_SIZE:-32}"
dpdk_rx_free_threshold="${DPDK_RX_FREE_THRESHOLD:-0}"
networking_backend="${NETWORKING_BACKEND:-socket}"
shm_file="/dev/shm/${shm_name#/}"

if [ "$stage_timestamps" != "0" ] && [ "$stage_timestamps" != "1" ]; then
  echo "STAGE_TIMESTAMPS must be 0 or 1" >&2
  exit 2
fi
if [ "$dpdk_rx_hardware_timestamps" != "0" ] &&
  [ "$dpdk_rx_hardware_timestamps" != "1" ]; then
  echo "DPDK_RX_HARDWARE_TIMESTAMPS must be 0 or 1" >&2
  exit 2
fi
case "$dpdk_rx_burst_size" in
  ''|*[!0-9]*)
    echo "DPDK_RX_BURST_SIZE must be an integer from 1 to 32" >&2
    exit 2
    ;;
esac
if [ "$dpdk_rx_burst_size" -lt 1 ] || [ "$dpdk_rx_burst_size" -gt 32 ]; then
  echo "DPDK_RX_BURST_SIZE must be an integer from 1 to 32" >&2
  exit 2
fi
case "$dpdk_rx_free_threshold" in
  ''|*[!0-9]*)
    echo "DPDK_RX_FREE_THRESHOLD must be an integer from 0 to 1023" >&2
    exit 2
    ;;
esac
if [ "$dpdk_rx_free_threshold" -gt 1023 ]; then
  echo "DPDK_RX_FREE_THRESHOLD must be an integer from 0 to 1023" >&2
  exit 2
fi
case "$networking_backend" in
  socket)
    bind_address="0.0.0.0"
    ;;
  dpdk)
    if [ ! -r /etc/spectral-task/dpdk.env ]; then
      echo "/etc/spectral-task/dpdk.env is required for DPDK" >&2
      exit 2
    fi
    # shellcheck disable=SC1091
    . /etc/spectral-task/dpdk.env
    for variable in DATA_PCI DATA_MAC DATA_IP; do
      eval "value=\${$variable:-}"
      if [ -z "$value" ]; then
        echo "$variable is required for DPDK" >&2
        exit 2
      fi
    done
    bind_address="$DATA_IP"
    ;;
  *)
    echo "NETWORKING_BACKEND must be socket or dpdk" >&2
    exit 2
    ;;
esac

receiver_pid=""
consumer_pid=""
cleanup() {
  for pid in "$consumer_pid" "$receiver_pid"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  rm -f "$shm_file" "$ready_file"
}
trap cleanup EXIT INT TERM

mkdir -p "$log_dir"
rm -f "$shm_file" "$log_dir/receiver.log" "$log_dir/consumer.log" \
  "$latency_csv" "$stage_csv" "$ready_file"

set --
if [ "$stage_timestamps" = "1" ]; then
  set -- --stage-timestamps
fi
if [ "$dpdk_rx_hardware_timestamps" = "1" ]; then
  set -- "$@" --dpdk-rx-hardware-timestamps
fi
set -- "$@" --networking-backend "$networking_backend"
if [ "$networking_backend" = "dpdk" ]; then
  set -- "$@" --dpdk-pci "$DATA_PCI" --local-mac "$DATA_MAC" \
    --dpdk-rx-burst-size "$dpdk_rx_burst_size" \
    --dpdk-rx-free-threshold "$dpdk_rx_free_threshold"
else
  set -- "$@" --busy-poll
fi

/usr/bin/taskset -c 2 "$bin_dir/receiver" \
  --shm "$shm_name" --slots "$slots" \
  --bind "$bind_address" --port "$port" \
  --count "$total_count" --idle-ms "$idle_ms" \
  "$@" \
  >"$log_dir/receiver.log" 2>&1 &
receiver_pid=$!

for attempt in $(seq 1 1000); do
  if grep -q '^receiver: bind=' "$log_dir/receiver.log" 2>/dev/null; then
    break
  fi
  if ! kill -0 "$receiver_pid" 2>/dev/null; then
    break
  fi
  sleep 0.01
done
if ! grep -q '^receiver: bind=' "$log_dir/receiver.log"; then
  cat "$log_dir/receiver.log" >&2
  exit 1
fi

set --
if [ "$stage_timestamps" = "1" ]; then
  set -- --stage-csv "$stage_csv"
fi

/usr/bin/taskset -c 3 "$bin_dir/consumer" \
  --shm "$shm_name" --slots "$slots" \
  --count "$message_count" --from-edge --idle-ms "$idle_ms" \
  --warmup-through-seq "$warmup_events" \
  --csv "$latency_csv" \
  "$@" \
  >"$log_dir/consumer.log" 2>&1 &
consumer_pid=$!

for attempt in $(seq 1 1000); do
  if grep -q '^consumer: ring=' "$log_dir/consumer.log" 2>/dev/null; then
    break
  fi
  if ! kill -0 "$consumer_pid" 2>/dev/null; then
    break
  fi
  sleep 0.01
done
if ! grep -q '^consumer: ring=' "$log_dir/consumer.log"; then
  cat "$log_dir/consumer.log" >&2
  exit 1
fi
date -u +%Y-%m-%dT%H:%M:%SZ >"$ready_file"

echo "receiver_pid=$receiver_pid"
/usr/bin/taskset -pc "$receiver_pid"
echo "consumer_pid=$consumer_pid"
/usr/bin/taskset -pc "$consumer_pid"

set +e
wait "$receiver_pid"
receiver_status=$?
wait "$consumer_pid"
consumer_status=$?
set -e
receiver_pid=""
consumer_pid=""

echo "--- receiver ---"
cat "$log_dir/receiver.log"
echo "--- consumer ---"
cat "$log_dir/consumer.log"
echo "receiver_status=$receiver_status consumer_status=$consumer_status"
echo "latency_csv=$latency_csv"
if [ "$stage_timestamps" = "1" ]; then
  echo "stage_csv=$stage_csv"
fi

if [ "$receiver_status" -ne 0 ] || [ "$consumer_status" -ne 0 ]; then
  exit 1
fi
