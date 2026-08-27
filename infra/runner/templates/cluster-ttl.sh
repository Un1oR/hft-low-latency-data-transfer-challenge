#!/bin/sh
# Файл встраивается в commands документа AWS-RunShellScript. SSM исполняет
# итоговый текст через /bin/sh, поэтому здесь допустим только POSIX shell.
set -eu

expires_at="${EXPIRES_AT:?EXPIRES_AT is required}"
cluster_paused="${CLUSTER_PAUSED:-false}"
if ! printf '%s\n' "$expires_at" | grep -Eq \
  '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  echo "Некорректный EXPIRES_AT: $expires_at" >&2
  exit 2
fi
# systemd распознаёт RFC3339 как timestamp, но OnCalendar требует calendar
# expression. После проверки формата безопасно переводим T/Z в пробел/UTC.
systemd_expires_at="$(printf '%s\n' "$expires_at" | sed 's/T/ /; s/Z$/ UTC/')"

# NAT bootstrap использует shutdown как защиту до появления SSM. На runner
# bootstrap создаёт относительный systemd timer. После регистрации в SSM оба
# варианта заменяются одним абсолютным временем из Terraform.
shutdown -c 2>/dev/null || true
systemctl disable --now spectral-runner-ttl.timer 2>/dev/null || true
systemctl disable --now spectral-runner-runtime-ttl.timer 2>/dev/null || true

if [ "$cluster_paused" = "true" ]; then
  exit 0
fi
if [ "$cluster_paused" != "false" ]; then
  echo "Некорректный CLUSTER_PAUSED: $cluster_paused" >&2
  exit 2
fi

cat >/etc/systemd/system/spectral-runner-ttl.service <<'SERVICE'
[Unit]
Description=Terminate the temporary Spectral node at the shared cluster TTL

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl poweroff
SERVICE

cat >/etc/systemd/system/spectral-runner-ttl.timer <<TIMER
[Unit]
Description=Shared absolute TTL for the temporary Spectral cluster

[Timer]
OnCalendar=$systemd_expires_at
AccuracySec=1s
Persistent=true
Unit=spectral-runner-ttl.service

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now spectral-runner-ttl.timer
systemctl is-active --quiet spectral-runner-ttl.timer
systemctl list-timers spectral-runner-ttl.timer --no-pager
