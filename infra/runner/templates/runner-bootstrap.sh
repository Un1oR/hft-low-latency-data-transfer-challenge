#!/bin/sh
# Этот файл встраивается в commandLine документа AWS-RunRemoteScript после
# export-строк. SSM запускает итоговую команду через /bin/sh, поэтому этот
# shebang не выбирает интерпретатор: скрипт должен оставаться POSIX-совместимым.
set -eu

package_path="${PACKAGE_PATH:?PACKAGE_PATH is required}"
expected_sha256="${EXPECTED_SHA256:?EXPECTED_SHA256 is required}"
target_kernel="${PHC_TARGET_KERNEL:-$(uname -r)}"

printf '%s  %s\n' "$expected_sha256" "$package_path" | sha256sum --check -
dpkg --install "$package_path"
install -d /var/lib/spectral-task
printf '%s\n' "$expected_sha256" >/var/lib/spectral-task/package.sha256

for binary in producer sender receiver consumer clock_probe; do
  test -x "/usr/libexec/spectral-task/bin/$binary"
done

if ! command -v chronyc >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends chrony
fi

systemctl enable chrony
if [ "$(uname -r)" = "$target_kernel" ]; then
  systemctl restart chrony
  chronyc waitsync 60 0 0 1
  if ! test -e /dev/ptp_ena ||
    ! chronyc sources | grep -Eq '^#\*[[:space:]]+PHC'; then
    echo "chrony не выбрал ENA PHC на целевом ядре" >&2
    chronyc sources >&2
    exit 1
  fi
else
  # PHC появится только после загрузки целевого ядра и нового ENA. До reboot
  # запускаем chrony без будущего refclock, но возвращаем конфиг на место,
  # чтобы systemd подхватил его при следующей загрузке.
  phc_config=/etc/chrony/conf.d/spectral-phc.conf
  pending_phc_config=/var/lib/spectral-task/spectral-phc.conf.next-boot
  mv "$phc_config" "$pending_phc_config"
  restart_status=0
  systemctl restart chrony || restart_status=$?
  mv "$pending_phc_config" "$phc_config"
  if [ "$restart_status" -ne 0 ]; then
    echo "chrony не запустился без будущего PHC-источника" >&2
    exit "$restart_status"
  fi
  chronyc waitsync 60 0 0 1
  if ! chronyc sources | grep -Eq '^\^\*[[:space:]]+169\.254\.169\.123'; then
    echo "chrony не выбрал локальный AWS Time Sync Service до reboot" >&2
    chronyc sources >&2
    exit 1
  fi
fi

isolation_ready=false
if grep -qw 'nohz_full=2-3' /proc/cmdline &&
  grep -qw 'rcu_nocbs=2-3' /proc/cmdline &&
  grep -qw 'irqaffinity=0-1' /proc/cmdline; then
  isolation_ready=true
fi
if [ "$isolation_ready" = true ] && [ "$(uname -r)" = "$target_kernel" ]; then
  exit 0
fi

if [ "$isolation_ready" = false ]; then
  install -d /etc/default/grub.d /etc/systemd/system.conf.d
  cat >/etc/default/grub.d/99-spectral-runner.cfg <<'GRUB'
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT nohz_full=2-3 rcu_nocbs=2-3 irqaffinity=0-1 isolcpus=domain,managed_irq,2-3"
GRUB

  cat >/etc/systemd/system.conf.d/90-spectral-cpu-affinity.conf <<'SYSTEMD'
[Manager]
CPUAffinity=0 1
SYSTEMD

  if grep -q '^IRQBALANCE_BANNED_CPULIST=' /etc/default/irqbalance 2>/dev/null; then
    sed -i 's/^IRQBALANCE_BANNED_CPULIST=.*/IRQBALANCE_BANNED_CPULIST=2-3/' /etc/default/irqbalance
  else
    printf '%s\n' 'IRQBALANCE_BANNED_CPULIST=2-3' >>/etc/default/irqbalance
  fi
fi

update-grub

# Повтор association может прийти, пока предыдущая успешная установка уже
# ждёт отложенного reboot. В таком случае требуемое действие уже поставлено в
# очередь: второй transient unit не нужен и systemd закономерно его отвергнет.
if systemctl is-active --quiet spectral-isolation-reboot.timer; then
  echo "Reboot уже запланирован предыдущим bootstrap"
  exit 0
fi
systemctl stop spectral-isolation-reboot.timer spectral-isolation-reboot.service \
  >/dev/null 2>&1 || true
systemctl reset-failed spectral-isolation-reboot.timer spectral-isolation-reboot.service \
  >/dev/null 2>&1 || true
systemd-run \
  --unit=spectral-isolation-reboot \
  --on-active=45s \
  /usr/bin/systemctl reboot
