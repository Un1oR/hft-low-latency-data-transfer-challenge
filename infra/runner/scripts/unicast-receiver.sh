#!/bin/sh
set -eu

bin_dir="/usr/libexec/spectral-task/bin"
log_dir="/tmp/spectral-unicast"
latency_csv="$log_dir/latency.csv"
ready_file="$log_dir/READY"
shm_name="${RX_SHM:-/spectral_rx}"
slots="${SHM_SLOTS:-65536}"
message_count="${MESSAGE_COUNT:-1000000}"
idle_ms="${IDLE_MS:-30000}"
port="${UDP_PORT:-9000}"
shm_file="/dev/shm/${shm_name#/}"

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
  "$latency_csv" "$ready_file"

/usr/bin/taskset -c 2 "$bin_dir/receiver" \
  --shm "$shm_name" --slots "$slots" \
  --bind 0.0.0.0 --port "$port" \
  --count "$message_count" --idle-ms "$idle_ms" --busy-poll \
  >"$log_dir/receiver.log" 2>&1 &
receiver_pid=$!

for attempt in $(seq 1 200); do
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

/usr/bin/taskset -c 3 "$bin_dir/consumer" \
  --shm "$shm_name" --slots "$slots" \
  --count "$message_count" --from-edge --idle-ms "$idle_ms" \
  --csv "$latency_csv" \
  >"$log_dir/consumer.log" 2>&1 &
consumer_pid=$!

for attempt in $(seq 1 200); do
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

if [ "$receiver_status" -ne 0 ] || [ "$consumer_status" -ne 0 ]; then
  exit 1
fi
