#!/bin/sh
# Этот файл исполняется на benchmark-узле через SSM от root.
set -eu

hugepage_count="${DPDK_HUGEPAGES_2M:-512}"
target_kernel="${PHC_TARGET_KERNEL:-$(uname -r)}"
case "$hugepage_count" in
  ''|*[!0-9]*)
    echo "DPDK_HUGEPAGES_2M должен быть целым числом" >&2
    exit 2
    ;;
esac
if [ "$hugepage_count" -lt 128 ]; then
  echo "DPDK_HUGEPAGES_2M должен быть не меньше 128" >&2
  exit 2
fi

missing_packages=""
for package in curl dpdk dpdk-dev dpdk-kmods-dkms; do
  if ! dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null |
    grep -qx installed; then
    missing_packages="$missing_packages $package"
  fi
done
if [ -n "$missing_packages" ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  # shellcheck disable=SC2086
  apt-get install -y --no-install-recommends $missing_packages
fi

# dpkg/DKMS автоматически собирает igb_uio только для текущего ядра. Bootstrap
# может готовить зафиксированное AWS-ядро, пока AMI ещё загружен на более новом;
# явно устанавливаем тот же модуль и для ядра следующей загрузки.
dpdk_kmods_source="$(find /usr/src -maxdepth 1 -type d \
  -name 'dpdk-kmods-*' -print -quit)"
if [ -z "$dpdk_kmods_source" ]; then
  echo "Не найден DKMS source dpdk-kmods" >&2
  exit 1
fi
dpdk_kmods_version="${dpdk_kmods_source##*/dpdk-kmods-}"
if ! dkms status -m dpdk-kmods -v "$dpdk_kmods_version" \
  -k "$target_kernel" 2>/dev/null | grep -q 'installed'; then
  dkms build -m dpdk-kmods -v "$dpdk_kmods_version" -k "$target_kernel"
  dkms install -m dpdk-kmods -v "$dpdk_kmods_version" -k "$target_kernel"
fi
modinfo -k "$target_kernel" igb_uio >/dev/null

for command in dpdk-testpmd dpdk-devbind.py; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "После установки отсутствует $command" >&2
    exit 1
  fi
done

install -d /etc/spectral-task /dev/hugepages
printf 'vm.nr_hugepages = %s\n' "$hugepage_count" \
  >/etc/sysctl.d/90-spectral-dpdk.conf
sysctl --system >/dev/null

if ! grep -Eq '^[^#]+[[:space:]]+/dev/hugepages[[:space:]]+hugetlbfs' \
  /etc/fstab; then
  printf '%s\n' 'nodev /dev/hugepages hugetlbfs defaults,pagesize=2M 0 0' \
    >>/etc/fstab
fi
if ! mountpoint -q /dev/hugepages; then
  mount /dev/hugepages
fi

printf '%s\n' 'options igb_uio wc_activate=1' \
  >/etc/modprobe.d/90-spectral-igb-uio.conf
printf '%s\n' 'igb_uio' >/etc/modules-load.d/90-spectral-dpdk.conf
modprobe igb_uio wc_activate=1

primary_interface="$(ip -4 route show default |
  awk 'NR == 1 {print $5}')"
if [ -z "$primary_interface" ] ||
  [ ! -e "/sys/class/net/$primary_interface/device" ]; then
  echo "Не удалось определить основной сетевой интерфейс" >&2
  exit 1
fi
primary_pci="$(basename "$(readlink -f "/sys/class/net/$primary_interface/device")")"

data_pci=""
for device_path in /sys/bus/pci/devices/*; do
  [ -r "$device_path/vendor" ] || continue
  [ "$(cat "$device_path/vendor")" = "0x1d0f" ] || continue
  [ "$(cat "$device_path/class")" = "0x020000" ] || continue
  candidate="$(basename "$device_path")"
  [ "$candidate" = "$primary_pci" ] && continue
  if [ -n "$data_pci" ]; then
    echo "Найдено больше одного дополнительного ENA PCI device" >&2
    exit 1
  fi
  data_pci="$candidate"
done
if [ -z "$data_pci" ]; then
  echo "Дополнительный ENA PCI device не найден" >&2
  exit 1
fi

data_interface=""
data_mac=""
data_ip=""
for interface_path in "/sys/bus/pci/devices/$data_pci"/net/*; do
  [ -e "$interface_path" ] || continue
  data_interface="$(basename "$interface_path")"
  data_mac="$(cat "$interface_path/address" 2>/dev/null || true)"
done
if [ -z "$data_mac" ] && [ -r /etc/spectral-task/dpdk.env ]; then
  data_mac="$(sed -n 's/^DATA_MAC=//p' /etc/spectral-task/dpdk.env | head -n 1)"
fi
if [ -z "$data_interface" ] && [ -r /etc/spectral-task/dpdk.env ]; then
  data_interface="$(sed -n 's/^DATA_INTERFACE=//p' /etc/spectral-task/dpdk.env | head -n 1)"
fi
if [ -r /etc/spectral-task/dpdk.env ]; then
  data_ip="$(sed -n 's/^DATA_IP=//p' /etc/spectral-task/dpdk.env | head -n 1)"
fi
if [ -z "$data_mac" ]; then
  # Восстанавливает узел, который до появления этого скрипта был вручную
  # привязан к igb_uio и поэтому ещё не имеет сохранённого MAC.
  modprobe ena 2>/dev/null || true
  dpdk-devbind.py --bind=ena "$data_pci"
  for attempt in 1 2 3 4 5; do
    for interface_path in "/sys/bus/pci/devices/$data_pci"/net/*; do
      [ -e "$interface_path" ] || continue
      data_interface="$(basename "$interface_path")"
      data_mac="$(cat "$interface_path/address" 2>/dev/null || true)"
    done
    [ -n "$data_mac" ] && break
    sleep 1
  done
fi
if [ -z "$data_mac" ]; then
  echo "Не удалось определить MAC дополнительного ENI" >&2
  exit 1
fi

if [ -z "$data_ip" ]; then
  imds_token="$(curl -fsS -X PUT \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    http://169.254.169.254/latest/api/token)"
  data_ip="$(curl -fsS \
    -H "X-aws-ec2-metadata-token: $imds_token" \
    "http://169.254.169.254/latest/meta-data/network/interfaces/macs/$data_mac/local-ipv4s" |
    sed -n '1p')"
fi
if ! printf '%s\n' "$data_ip" | grep -Eq \
  '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
  echo "Не удалось определить IPv4 дополнительного ENI" >&2
  exit 1
fi

cat >/etc/spectral-task/dpdk.env <<EOF
PRIMARY_INTERFACE=$primary_interface
PRIMARY_PCI=$primary_pci
DATA_INTERFACE=$data_interface
DATA_PCI=$data_pci
DATA_MAC=$data_mac
DATA_IP=$data_ip
HUGEPAGES_2M=$hugepage_count
EOF

cat >/usr/local/sbin/spectral-dpdk-bind <<'BIND'
#!/bin/sh
set -eu
. /etc/spectral-task/dpdk.env
modprobe igb_uio wc_activate=1
if [ -n "${DATA_INTERFACE:-}" ] && ip link show "$DATA_INTERFACE" >/dev/null 2>&1; then
  ip link set "$DATA_INTERFACE" down
fi
dpdk-devbind.py --bind=igb_uio "$DATA_PCI"
test "$(basename "$(readlink -f "/sys/bus/pci/devices/$DATA_PCI/driver")")" = igb_uio
BIND
chmod 0755 /usr/local/sbin/spectral-dpdk-bind

cat >/etc/systemd/system/spectral-dpdk-bind.service <<'SERVICE'
[Unit]
Description=Bind the dedicated Spectral data ENI to igb_uio
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/spectral-dpdk-bind
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable spectral-dpdk-bind.service
systemctl restart spectral-dpdk-bind.service
systemctl is-active --quiet spectral-dpdk-bind.service

test "$(basename "$(readlink -f "/sys/bus/pci/devices/$primary_pci/driver")")" = ena
test "$(basename "$(readlink -f "/sys/bus/pci/devices/$data_pci/driver")")" = igb_uio
ip -4 route show default | grep -q "dev $primary_interface"
mountpoint -q /dev/hugepages

actual_hugepages="$(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo)"
if [ "$actual_hugepages" -lt "$hugepage_count" ]; then
  echo "Выделено только $actual_hugepages из $hugepage_count hugepages" >&2
  exit 1
fi

dpdk_version="$(dpkg-query -W -f='${Version}' dpdk)"
printf '%s\n' \
  "dpdk_prepare_status=ready" \
  "primary_interface=$primary_interface" \
  "primary_pci=$primary_pci" \
  "data_pci=$data_pci" \
  "data_mac=$data_mac" \
  "data_ip=$data_ip" \
  "hugepages_2m=$actual_hugepages" \
  "igb_uio_wc_activate=1" \
  "dpdk_version=$dpdk_version"
