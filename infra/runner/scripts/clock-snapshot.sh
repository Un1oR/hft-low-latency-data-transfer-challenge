#!/bin/sh
set -eu

max_error_ns="${MAX_CLOCK_ERROR_NS:-150000}"
require_phc="${REQUIRE_PHC:-0}"
case "$max_error_ns" in
  ''|*[!0-9]*)
    echo "MAX_CLOCK_ERROR_NS должен быть целым числом наносекунд" >&2
    exit 2
    ;;
esac
case "$require_phc" in
  0|1) ;;
  *) echo "REQUIRE_PHC должен быть 0 или 1" >&2; exit 2 ;;
esac

tracking_csv="$(chronyc -c tracking)"
sources="$(chronyc sources)"
system_time_s="$(printf '%s\n' "$tracking_csv" | awk -F, '{print $5}')"
root_delay_s="$(printf '%s\n' "$tracking_csv" | awk -F, '{print $11}')"
root_dispersion_s="$(printf '%s\n' "$tracking_csv" | awk -F, '{print $12}')"
leap_status="$(printf '%s\n' "$tracking_csv" | awk -F, '{print $14}')"
chrony_error_bound_ns="$(awk \
  -v system_time="$system_time_s" \
  -v delay="$root_delay_s" \
  -v dispersion="$root_dispersion_s" \
  'BEGIN {
    if (system_time < 0) system_time = -system_time;
    printf "%.0f", (system_time + delay / 2 + dispersion) * 1000000000;
  }')"

clock_source="aws_local_ntp"
phc_error_bound_ns=0
phc_clock_name=""
phc_primary_interface=""
phc_primary_pci=""
phc_available=0
if [ -e /dev/ptp_ena ]; then
  phc_primary_interface="$(ip -4 route show default | awk 'NR == 1 {print $5}')"
  phc_primary_pci="$(basename "$(readlink -f "/sys/class/net/$phc_primary_interface/device")")"
  phc_error_bound_path="/sys/bus/pci/devices/$phc_primary_pci/phc_error_bound"
  phc_error_bound_attempt=1
  while [ "$phc_error_bound_attempt" -le 20 ]; do
    if phc_error_bound_ns="$(cat "$phc_error_bound_path" 2>/dev/null)"; then
      break
    fi
    phc_error_bound_ns=""
    phc_error_bound_attempt=$((phc_error_bound_attempt + 1))
    sleep 0.05
  done
  case "$phc_error_bound_ns" in
    ''|*[!0-9]*)
      echo "Не удалось прочитать корректный PHC error bound за 20 попыток: $phc_error_bound_ns" >&2
      exit 1
      ;;
  esac
  phc_device="$(basename "$(readlink -f /dev/ptp_ena)")"
  phc_clock_name="$(cat "/sys/class/ptp/$phc_device/clock_name")"
  if printf '%s\n' "$sources" | grep -Eq '^#\*[[:space:]]+PHC'; then
    phc_available=1
    clock_source="aws_ena_phc"
  fi
fi
clock_error_bound_ns=$((chrony_error_bound_ns + phc_error_bound_ns))

printf 'clock_snapshot_version=3\n'
printf 'captured_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
printf 'hostname=%s\n' "$(hostname)"
printf 'clock_source=%s\n' "$clock_source"
printf 'chrony_system_time_s=%s\n' "$system_time_s"
printf 'chrony_root_delay_s=%s\n' "$root_delay_s"
printf 'chrony_root_dispersion_s=%s\n' "$root_dispersion_s"
printf 'chrony_error_bound_ns=%s\n' "$chrony_error_bound_ns"
printf 'phc_error_bound_ns=%s\n' "$phc_error_bound_ns"
printf 'phc_clock_name=%s\n' "$phc_clock_name"
printf 'phc_primary_interface=%s\n' "$phc_primary_interface"
printf 'phc_primary_pci=%s\n' "$phc_primary_pci"
printf 'clock_error_bound_ns=%s\n' "$clock_error_bound_ns"
printf 'max_clock_error_ns=%s\n' "$max_error_ns"
printf 'chrony_leap_status=%s\n' "$leap_status"
printf '%s\n' '--- chronyc sources ---'
printf '%s\n' "$sources"
printf '%s\n' '--- chronyc tracking ---'
chronyc tracking

if [ "$require_phc" = 1 ] && [ "$phc_available" != 1 ]; then
  echo "clock_snapshot_status=invalid"
  echo "clock_snapshot_reason=aws_ena_phc_not_selected"
  exit 1
fi
if [ "$require_phc" = 0 ] && [ "$phc_available" != 1 ] &&
  ! printf '%s\n' "$sources" | grep -Eq '^\^\*[[:space:]]+169\.254\.169\.123'; then
  echo "clock_snapshot_status=invalid"
  echo "clock_snapshot_reason=aws_time_source_not_selected"
  exit 1
fi
if [ "$leap_status" != "Normal" ]; then
  echo "clock_snapshot_status=invalid"
  echo "clock_snapshot_reason=chrony_not_synchronized"
  exit 1
fi
if [ "$clock_error_bound_ns" -gt "$max_error_ns" ]; then
  echo "clock_snapshot_status=invalid"
  echo "clock_snapshot_reason=clock_error_bound_exceeded"
  exit 1
fi

echo "clock_snapshot_status=valid"
