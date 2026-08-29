#!/bin/sh
# Готовит штатное Ubuntu AWS kernel и официальный ENA driver с PHC.
# Исполняется через SSM от root и безопасно повторяется.
set -eu

target_kernel="6.17.0-1020-aws"
kernel_meta_version="6.17.0-1020.20~24.04.1+1"
perf_package="linux-tools-$target_kernel"
ena_version="2.17.2"
ena_commit="acddbf23ac6eb0f2f607d223076628b29b05780a"
ena_source="/usr/src/amzn-drivers-$ena_version"

export DEBIAN_FRONTEND=noninteractive
installed_kernel_meta="$(dpkg-query -W -f='${Version}' linux-aws-6.17 2>/dev/null || true)"
if [ "$installed_kernel_meta" != "$kernel_meta_version" ] ||
  ! command -v dkms >/dev/null 2>&1 ||
  ! command -v gcc >/dev/null 2>&1 ||
  ! command -v git >/dev/null 2>&1 ||
  ! command -v make >/dev/null 2>&1 ||
  ! command -v chronyc >/dev/null 2>&1 ||
  ! dpkg-query -W -f='${db:Status-Status}' "$perf_package" 2>/dev/null |
    grep -qx installed; then
  apt-get update
  apt-get install -y --no-install-recommends \
    "linux-aws-6.17=$kernel_meta_version" \
    "$perf_package" chrony dkms gcc git make
fi

test -d "/lib/modules/$target_kernel/build"
grep -q '^CONFIG_ENA_ETHERNET=m$' "/lib/modules/$target_kernel/build/.config"
grep -q '^CONFIG_PTP_1588_CLOCK=y$' "/lib/modules/$target_kernel/build/.config"

if [ ! -d "$ena_source/.git" ]; then
  if [ -e "$ena_source" ]; then
    echo "$ena_source существует, но не является git checkout" >&2
    exit 1
  fi
  git clone --quiet --depth 1 --branch "ena_linux_$ena_version" \
    https://github.com/amzn/amzn-drivers.git "$ena_source"
fi
actual_commit="$(git -C "$ena_source" rev-parse HEAD)"
if [ "$actual_commit" != "$ena_commit" ]; then
  echo "Неожиданный ENA commit: $actual_commit" >&2
  exit 1
fi

cat >"$ena_source/dkms.conf" <<'DKMS'
PACKAGE_NAME="amzn-drivers"
PACKAGE_VERSION="2.17.2"
CLEAN="make -C kernel/linux/ena clean"
MAKE[0]="ENA_PHC_INCLUDE=1 make -C kernel/linux/ena BUILD_KERNEL=${kernelver}"
BUILT_MODULE_NAME[0]="ena"
BUILT_MODULE_LOCATION[0]="kernel/linux/ena"
DEST_MODULE_LOCATION[0]="/updates/dkms"
DEST_MODULE_NAME[0]="ena"
AUTOINSTALL="yes"
DKMS

if ! dkms status -m amzn-drivers -v "$ena_version" 2>/dev/null |
  grep -q .; then
  dkms add -m amzn-drivers -v "$ena_version"
fi
if ! dkms status -m amzn-drivers -v "$ena_version" -k "$target_kernel" 2>/dev/null |
  grep -q 'installed'; then
  dkms build -m amzn-drivers -v "$ena_version" -k "$target_kernel"
  dkms install -m amzn-drivers -v "$ena_version" -k "$target_kernel"
fi

ena_module="$(modinfo -k "$target_kernel" -n ena)"
case "$ena_module" in
  */updates/dkms/ena.ko*) ;;
  *)
    echo "Для $target_kernel выбран не DKMS ENA module: $ena_module" >&2
    exit 1
    ;;
esac
if ! modinfo -k "$target_kernel" ena | grep -q '^parm:[[:space:]]*phc_enable:'; then
  echo "Собранный ENA module не содержит phc_enable" >&2
  exit 1
fi

printf '%s\n' 'options ena phc_enable=1' \
  >/etc/modprobe.d/90-spectral-ena-phc.conf
cat >/etc/udev/rules.d/53-spectral-ena-phc.rules <<'UDEV'
SUBSYSTEM=="ptp", ATTR{clock_name}=="ena-ptp-*", SYMLINK += "ptp_ena"
UDEV

install -d /etc/chrony/conf.d
cat >/etc/chrony/conf.d/spectral-phc.conf <<'CHRONY'
refclock PHC /dev/ptp_ena poll 0 delay 0.000010 prefer
CHRONY
if ! grep -Eq '^[[:space:]]*confdir[[:space:]]+/etc/chrony/conf\.d' \
  /etc/chrony/chrony.conf; then
  echo 'confdir /etc/chrony/conf.d' >>/etc/chrony/chrony.conf
fi

# Noble AMI может уже содержать ядро с номером выше зафиксированного нами.
# GRUB_DEFAULT=0 тогда молча загружает его, хотя целевое ядро и ENA DKMS
# установлены. Имя submenu одинаково на Ubuntu, а entry проверяется ниже через
# сгенерированный grub.cfg до того, как будет запланирован reboot.
install -d /etc/default/grub.d
cat >/etc/default/grub.d/99-spectral-kernel.cfg <<EOF
GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux $target_kernel"
EOF

update-initramfs -u -k "$target_kernel"
update-grub
grep -Fq "menuentry 'Ubuntu, with Linux $target_kernel'" /boot/grub/grub.cfg

printf '%s\n' \
  "phc_prepare_status=ready_for_reboot" \
  "phc_target_kernel=$target_kernel" \
  "phc_ena_version=$ena_version" \
  "phc_ena_commit=$ena_commit" \
  "phc_ena_module=$ena_module"

if [ "$(uname -r)" != "$target_kernel" ]; then
  reboot_required=yes
else
  reboot_required=no
fi
printf 'phc_reboot_required=%s\n' "$reboot_required"

if [ "$reboot_required" = yes ] && [ "${PHC_SCHEDULE_REBOOT:-0}" = 1 ]; then
  systemd-run --quiet --unit=spectral-phc-reboot --on-active=45s \
    /usr/bin/systemctl reboot
fi
