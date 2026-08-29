#!/bin/sh
set -eu

target_kernel="6.17.0-1020-aws"
max_error_ns="${MAX_CLOCK_ERROR_NS:-150000}"
case "$max_error_ns" in
  ''|*[!0-9]*)
    echo "MAX_CLOCK_ERROR_NS должен быть целым числом наносекунд" >&2
    exit 2
    ;;
esac

test "$(uname -r)" = "$target_kernel"
case "$(modinfo -n ena)" in
  */updates/dkms/ena.ko*) ;;
  *) echo "Загружен не ENA DKMS module" >&2; exit 1 ;;
esac
test "$(cat /sys/module/ena/parameters/phc_enable)" = 1
test -e /dev/ptp_ena
clock_name="$(cat "/sys/class/ptp/$(basename "$(readlink -f /dev/ptp_ena)")/clock_name")"
case "$clock_name" in
  ena-ptp-*) ;;
  *) echo "Неожиданное PHC clock_name: $clock_name" >&2; exit 1 ;;
esac

primary_interface="$(ip -4 route show default | awk 'NR == 1 {print $5}')"
primary_pci="$(basename "$(readlink -f "/sys/class/net/$primary_interface/device")")"
phc_error_bound_ns="$(cat "/sys/bus/pci/devices/$primary_pci/phc_error_bound")"
case "$phc_error_bound_ns" in
  ''|*[!0-9]*) echo "Некорректный PHC error bound" >&2; exit 1 ;;
esac

chronyc waitsync 60 0 0 1
if ! chronyc sources | grep -Eq '^#\*[[:space:]]+PHC'; then
  echo "chrony не выбрал ENA PHC" >&2
  chronyc sources >&2
  exit 1
fi
if [ "$phc_error_bound_ns" -gt "$max_error_ns" ]; then
  echo "PHC error bound $phc_error_bound_ns превышает $max_error_ns нс" >&2
  exit 1
fi

. /etc/spectral-task/dpdk.env
test "$(basename "$(readlink -f "/sys/bus/pci/devices/$DATA_PCI/driver")")" = igb_uio

printf '%s\n' \
  "phc_verify_status=ready" \
  "phc_kernel=$target_kernel" \
  "phc_clock_name=$clock_name" \
  "phc_error_bound_ns=$phc_error_bound_ns" \
  "phc_primary_interface=$primary_interface" \
  "phc_primary_pci=$primary_pci" \
  "phc_data_driver=igb_uio"
