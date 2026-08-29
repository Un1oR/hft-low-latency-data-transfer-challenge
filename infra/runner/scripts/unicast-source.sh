#!/bin/sh
set -eu

destinations="${DESTINATIONS:-${DESTINATION:-}}"
if [ -z "$destinations" ]; then
  echo "DESTINATIONS (or DESTINATION) is required" >&2
  exit 2
fi
networking_backend="${NETWORKING_BACKEND:-socket}"
destination_macs="${DESTINATION_MACS:-}"
case "$networking_backend" in
  socket) ;;
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
    ;;
  *)
    echo "NETWORKING_BACKEND must be socket or dpdk" >&2
    exit 2
    ;;
esac
bin_dir="/usr/libexec/spectral-task/bin"
log_dir="/tmp/spectral-unicast"
shm_name="${TX_SHM:-/spectral_tx}"
slots="${SHM_SLOTS:-65536}"
message_count="${MESSAGE_COUNT:-1000000}"
warmup_events="${WARMUP_EVENTS:-0}"
total_count=$((message_count + warmup_events))
message_rate="${MESSAGE_RATE:-200000}"
message_type="${MESSAGE_TYPE:-mixed}"
idle_ms="${IDLE_MS:-5000}"
batch_wait_ns="${BATCH_WAIT_NS:-0}"
batch_target_frames="${BATCH_TARGET_FRAMES:-2}"
llq_probe_minimal_wire="${LLQ_PROBE_MINIMAL_WIRE:-0}"
llq_probe_mixed_wire="${LLQ_PROBE_MIXED_WIRE:-0}"
compact_wire="${COMPACT_WIRE:-0}"
compact_wire_mixed="${COMPACT_WIRE_MIXED:-0}"
dpdk_llq_policy="${DPDK_LLQ_POLICY:-1}"
port="${UDP_PORT:-9000}"
shm_file="/dev/shm/${shm_name#/}"

producer_pid=""
sender_pid=""
cleanup() {
  for pid in "$sender_pid" "$producer_pid"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  rm -f "$shm_file"
}
trap cleanup EXIT INT TERM

mkdir -p "$log_dir"
rm -f "$shm_file" "$log_dir/producer.log" "$log_dir/sender.log"

/usr/bin/taskset -c 2 "$bin_dir/producer" \
  --shm "$shm_name" --slots "$slots" \
  --count "$total_count" --rate "$message_rate" \
  --type "$message_type" --wait-for-reader \
  >"$log_dir/producer.log" 2>&1 &
producer_pid=$!

for attempt in $(seq 1 200); do
  if grep -q '^producer: shm=' "$log_dir/producer.log" 2>/dev/null; then
    break
  fi
  if ! kill -0 "$producer_pid" 2>/dev/null; then
    break
  fi
  sleep 0.01
done
if ! grep -q '^producer: shm=' "$log_dir/producer.log"; then
  cat "$log_dir/producer.log" >&2
  exit 1
fi

set --
destination_count=0
for destination in $destinations; do
  set -- "$@" --dest "$destination"
  destination_count=$((destination_count + 1))
done
if [ "$destination_count" -gt 3 ]; then
  echo "At most three destinations are supported" >&2
  exit 2
fi
set -- "$@" --networking-backend "$networking_backend"
case "$llq_probe_minimal_wire" in
  0) ;;
  1)
    if [ "$networking_backend" != "dpdk" ]; then
      echo "LLQ_PROBE_MINIMAL_WIRE requires NETWORKING_BACKEND=dpdk" >&2
      exit 2
    fi
    set -- "$@" --llq-probe-minimal-wire
    ;;
  *)
    echo "LLQ_PROBE_MINIMAL_WIRE must be 0 or 1" >&2
    exit 2
    ;;
esac
case "$llq_probe_mixed_wire" in
  0) ;;
  1)
    if [ "$networking_backend" != "dpdk" ]; then
      echo "LLQ_PROBE_MIXED_WIRE requires NETWORKING_BACKEND=dpdk" >&2
      exit 2
    fi
    set -- "$@" --llq-probe-mixed-wire
    ;;
  *)
    echo "LLQ_PROBE_MIXED_WIRE must be 0 or 1" >&2
    exit 2
    ;;
esac
if [ "$llq_probe_minimal_wire" = "1" ] && [ "$llq_probe_mixed_wire" = "1" ]; then
  echo "LLQ_PROBE_MINIMAL_WIRE and LLQ_PROBE_MIXED_WIRE are exclusive" >&2
  exit 2
fi
case "$compact_wire" in
  0) ;;
  1) set -- "$@" --compact-wire ;;
  *)
    echo "COMPACT_WIRE must be 0 or 1" >&2
    exit 2
    ;;
esac
case "$compact_wire_mixed" in
  0) ;;
  1)
    if [ "$networking_backend" != "dpdk" ]; then
      echo "COMPACT_WIRE_MIXED requires NETWORKING_BACKEND=dpdk" >&2
      exit 2
    fi
    set -- "$@" --compact-wire-mixed
    ;;
  *)
    echo "COMPACT_WIRE_MIXED must be 0 or 1" >&2
    exit 2
    ;;
esac
if { [ "$compact_wire" = "1" ] || [ "$compact_wire_mixed" = "1" ]; } &&
   { [ "$llq_probe_minimal_wire" = "1" ] || [ "$llq_probe_mixed_wire" = "1" ]; }; then
  echo "COMPACT_WIRE and LLQ diagnostic formats are exclusive" >&2
  exit 2
fi
if [ "$compact_wire" = "1" ] && [ "$compact_wire_mixed" = "1" ]; then
  echo "COMPACT_WIRE and COMPACT_WIRE_MIXED are exclusive" >&2
  exit 2
fi
case "$dpdk_llq_policy" in
  0|1|2|3) ;;
  *)
    echo "DPDK_LLQ_POLICY must be 0, 1, 2 or 3" >&2
    exit 2
    ;;
esac
if [ "$networking_backend" != "dpdk" ] && [ "$dpdk_llq_policy" != "1" ]; then
  echo "DPDK_LLQ_POLICY requires NETWORKING_BACKEND=dpdk" >&2
  exit 2
fi
if [ "$networking_backend" = "dpdk" ]; then
  mac_count=0
  for destination_mac in $destination_macs; do
    set -- "$@" --dest-mac "$destination_mac"
    mac_count=$((mac_count + 1))
  done
  if [ "$mac_count" -ne "$destination_count" ]; then
    echo "DPDK requires one destination MAC for every destination IP" >&2
    exit 2
  fi
  set -- "$@" \
    --dpdk-pci "$DATA_PCI" --source-ip "$DATA_IP" --source-mac "$DATA_MAC" \
    --dpdk-llq-policy "$dpdk_llq_policy"
fi

/usr/bin/taskset -c 3 "$bin_dir/sender" \
  --shm "$shm_name" --slots "$slots" \
  "$@" --port "$port" \
  --count "$total_count" --from-edge --idle-ms "$idle_ms" \
  --batch-wait-ns "$batch_wait_ns" \
  --batch-target-frames "$batch_target_frames" \
  >"$log_dir/sender.log" 2>&1 &
sender_pid=$!

echo "producer_pid=$producer_pid"
/usr/bin/taskset -pc "$producer_pid"
echo "sender_pid=$sender_pid"
/usr/bin/taskset -pc "$sender_pid"

set +e
wait "$producer_pid"
producer_status=$?
wait "$sender_pid"
sender_status=$?
set -e
producer_pid=""
sender_pid=""

echo "--- producer ---"
cat "$log_dir/producer.log"
echo "--- sender ---"
cat "$log_dir/sender.log"
echo "producer_status=$producer_status sender_status=$sender_status"

if [ "$producer_status" -ne 0 ] || [ "$sender_status" -ne 0 ]; then
  exit 1
fi
