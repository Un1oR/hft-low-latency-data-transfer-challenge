#!/bin/sh
# Этот файл встраивается в commandLine документа AWS-RunRemoteScript после
# export-строк. SSM запускает итоговую команду через /bin/sh, поэтому этот
# shebang не выбирает интерпретатор: скрипт должен оставаться POSIX-совместимым.
set -eu

package_path="${PACKAGE_PATH:?PACKAGE_PATH is required}"
expected_sha256="${EXPECTED_SHA256:?EXPECTED_SHA256 is required}"

printf '%s  %s\n' "$expected_sha256" "$package_path" | sha256sum --check -
dpkg --install "$package_path"

for binary in producer sender receiver consumer; do
  test -x "/usr/libexec/spectral-task/bin/$binary"
done

if grep -qw 'nohz_full=2-3' /proc/cmdline &&
  grep -qw 'rcu_nocbs=2-3' /proc/cmdline &&
  grep -qw 'irqaffinity=0-1' /proc/cmdline; then
  exit 0
fi

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

update-grub

systemd-run \
  --unit=spectral-isolation-reboot \
  --on-active=15s \
  /usr/bin/systemctl reboot
