#!/bin/sh
# Воспроизводимая внешняя perf-диагностика DPDK hot path.
# Исполняется через SSM от root; измеряемые процессы не линкуются с libperf.
set -eu

action="${1:-}"
work_dir="${DPDK_PERF_WORK_DIR:-/tmp/spectral-dpdk-perf}"
unit="spectral-dpdk-perf"
duration_seconds="${DPDK_PERF_DURATION_SECONDS:-180}"
sample_cpu="${DPDK_PERF_SAMPLE_CPU:-2}"
sample_frequency="${DPDK_PERF_SAMPLE_FREQUENCY:-997}"
entry_event="probe_librte_net_ena:spectral_ena_refill"
return_event="probe_librte_net_ena:spectral_ena_refill_ret__return"

case "$duration_seconds" in
  ''|*[!0-9]*)
    echo "DPDK_PERF_DURATION_SECONDS must be an integer" >&2
    exit 2
    ;;
esac
if [ "$duration_seconds" -lt 1 ] || [ "$duration_seconds" -gt 3600 ]; then
  echo "DPDK_PERF_DURATION_SECONDS must be in 1..3600" >&2
  exit 2
fi
case "$sample_cpu" in
  ''|*[!0-9]*)
    echo "DPDK_PERF_SAMPLE_CPU must be a non-negative integer" >&2
    exit 2
    ;;
esac
case "$sample_frequency" in
  ''|*[!0-9]*)
    echo "DPDK_PERF_SAMPLE_FREQUENCY must be an integer" >&2
    exit 2
    ;;
esac
if [ "$sample_frequency" -lt 1 ] || [ "$sample_frequency" -gt 4000 ]; then
  echo "DPDK_PERF_SAMPLE_FREQUENCY must be in 1..4000" >&2
  exit 2
fi

remove_probes() {
  perf probe --list 2>/dev/null |
    awk '$1 ~ /^probe_librte_net_ena:spectral_ena_refill/ {print $1}' |
    while IFS= read -r event; do
      [ -n "$event" ] || continue
      perf probe --del "$event" >/dev/null
    done
}

stop_unit() {
  systemctl stop "$unit.service" >/dev/null 2>&1 || true
  systemctl reset-failed "$unit.service" >/dev/null 2>&1 || true
}

find_ena_library() {
  find /usr/libexec/spectral-task -type f \
    -path '*/dpdk-*/lib/*/dpdk/pmds-*/librte_net_ena.so.*' \
    -print | sort -V | tail -n 1
}

case "$action" in
  start)
    command -v perf >/dev/null
    command -v nm >/dev/null
    if pgrep -af '[s]pectral-receiver' >/dev/null; then
      echo "spectral-receiver is already running" >&2
      exit 1
    fi
    ena_library="$(find_ena_library)"
    if [ -z "$ena_library" ] || [ ! -r "$ena_library" ]; then
      echo "ENA PMD library was not found" >&2
      exit 1
    fi
    nm -an "$ena_library" | grep -q ' ena_populate_rx_queue$'

    stop_unit
    remove_probes
    if [ -e "$work_dir" ]; then
      rm -rf -- "$work_dir"
    fi
    install -d "$work_dir"

    perf probe -x "$ena_library" \
      --add spectral_ena_refill=ena_populate_rx_queue >/dev/null
    perf probe -x "$ena_library" \
      --add spectral_ena_refill_ret=ena_populate_rx_queue%return >/dev/null

    {
      printf 'kernel=%s\n' "$(uname -r)"
      printf 'perf_version=%s\n' "$(perf version | awk '{print $3}')"
      printf 'ena_library=%s\n' "$ena_library"
      printf 'ena_library_sha256=%s\n' \
        "$(sha256sum "$ena_library" | awk '{print $1}')"
      printf 'duration_seconds=%s\n' "$duration_seconds"
    } >"$work_dir/metadata.txt"

    systemd-run --unit="$unit" --collect --property=Type=exec \
      /usr/bin/perf record -a \
      -e "$entry_event" -e "$return_event" \
      -o "$work_dir/perf.data" -- sleep "$duration_seconds" >/dev/null
    systemctl is-active --quiet "$unit.service"
    cat "$work_dir/metadata.txt"
    echo "dpdk_perf_status=recording"
    ;;

  stop)
    stop_unit
    test -s "$work_dir/perf.data"
    perf script -i "$work_dir/perf.data" --ns -F tid,time,event |
      gzip -1 >"$work_dir/events.txt.gz"
    gzip -dc "$work_dir/events.txt.gz" |
      awk '
        /spectral_ena_refill:/ && !/ret__return/ {
          tid=$1; time=$2; sub(/:$/, "", time)
          start[tid]=time; entries++
        }
        /spectral_ena_refill_ret__return:/ {
          tid=$1; time=$2; sub(/:$/, "", time); returns++
          if (tid in start) {
            duration=(time-start[tid])*1000000000
            printf "%.0f\n", duration
            delete start[tid]; paired++
          }
        }
        END {
          printf "entries=%d\nreturns=%d\npaired=%d\nunmatched=%d\n",
            entries, returns, paired, entries-paired > status
        }
      ' status="$work_dir/pairing.txt" \
      >"$work_dir/durations-ns.txt"
    sort -n "$work_dir/durations-ns.txt" \
      >"$work_dir/durations-ns.sorted"
    awk '
      NR == 1 { minimum=$1 }
      { values[NR]=$1; total+=$1; maximum=$1 }
      END {
        count=NR
        if (count == 0) exit 1
        p50=values[int((count-1)*0.50)+1]
        p99=values[int((count-1)*0.99)+1]
        p999=values[int((count-1)*0.999)+1]
        p9999=values[int((count-1)*0.9999)+1]
        printf "count=%d\nmin_ns=%d\nmean_ns=%.1f\np50_ns=%d\n",
          count, minimum, total/count, p50
        printf "p99_ns=%d\np99_9_ns=%d\np99_99_ns=%d\nmax_ns=%d\n",
          p99, p999, p9999, maximum
      }
    ' "$work_dir/durations-ns.sorted" >"$work_dir/summary.txt"
    remove_probes
    cat "$work_dir/metadata.txt" "$work_dir/pairing.txt" \
      "$work_dir/summary.txt"
    echo "dpdk_perf_status=complete"
    ;;

  sample-start)
    command -v perf >/dev/null
    stop_unit
    remove_probes
    if [ -e "$work_dir" ]; then
      rm -rf -- "$work_dir"
    fi
    install -d "$work_dir"
    {
      printf 'mode=cpu-samples\n'
      printf 'kernel=%s\n' "$(uname -r)"
      printf 'perf_version=%s\n' "$(perf version | awk '{print $3}')"
      printf 'package_sha256=%s\n' \
        "$(cat /var/lib/spectral-task/package.sha256 2>/dev/null || echo unknown)"
      printf 'cpu=%s\n' "$sample_cpu"
      printf 'frequency=%s\n' "$sample_frequency"
      printf 'duration_seconds=%s\n' "$duration_seconds"
    } >"$work_dir/metadata.txt"

    # Ядро изолировано от обычных задач, поэтому профиль CPU охватывает
    # целевой sender/receiver даже если его PID появляется после старта perf.
    systemd-run --unit="$unit" --collect --property=Type=exec \
      /usr/bin/perf record -C "$sample_cpu" -e cycles:u \
      -F "$sample_frequency" -o "$work_dir/perf.data" \
      -- sleep "$duration_seconds" >/dev/null
    systemctl is-active --quiet "$unit.service"
    cat "$work_dir/metadata.txt"
    echo "dpdk_perf_status=sampling"
    ;;

  sample-stop)
    stop_unit
    test -s "$work_dir/perf.data"
    perf report --stdio --no-children --percent-limit 0.05 \
      --sort comm,dso,symbol -i "$work_dir/perf.data" \
      >"$work_dir/report.txt"
    perf script -i "$work_dir/perf.data" \
      -F comm,pid,tid,cpu,time,event,ip,sym,dso |
      gzip -1 >"$work_dir/samples.txt.gz"
    cat "$work_dir/metadata.txt" "$work_dir/report.txt"
    echo "dpdk_perf_status=sample-complete"
    ;;

  clean)
    stop_unit
    remove_probes
    echo "dpdk_perf_status=clean"
    ;;

  *)
    echo "usage: dpdk-perf.sh <start|stop|sample-start|sample-stop|clean>" >&2
    exit 2
    ;;
esac
