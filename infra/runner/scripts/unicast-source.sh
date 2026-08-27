#!/bin/sh
set -eu

destination="${DESTINATION:?DESTINATION is required}"
bin_dir="/usr/libexec/spectral-task/bin"
log_dir="/tmp/spectral-unicast"
shm_name="${TX_SHM:-/spectral_tx}"
slots="${SHM_SLOTS:-65536}"
message_count="${MESSAGE_COUNT:-1000000}"
message_rate="${MESSAGE_RATE:-200000}"
message_type="${MESSAGE_TYPE:-mixed}"
idle_ms="${IDLE_MS:-5000}"
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
  --count "$message_count" --rate "$message_rate" \
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

/usr/bin/taskset -c 3 "$bin_dir/sender" \
  --shm "$shm_name" --slots "$slots" \
  --dest "$destination" --port "$port" \
  --count "$message_count" --from-edge --idle-ms "$idle_ms" \
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
