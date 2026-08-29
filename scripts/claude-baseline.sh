#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
runner_dir="$repo_root/infra/runner"
expected_commit="${CLAUDE_BASELINE_COMMIT:-c86cc26ab2e84996137f922cf175d33e9a622c29}"
short_commit="${expected_commit:0:12}"
package_version="0.1.0+git${short_commit}"
package_name="claude-baseline_${package_version}_amd64.deb"
package_default="$repo_root/dist/$package_name"
ubuntu_image="ubuntu:24.04@sha256:019e8eb29a85e74d64925745884f2ec79aa27e3feab36353d24656f4d6b89467"
region="${AWS_RUNNER_REGION:-us-east-1}"
cleanup_source_id=""
cleanup_ids=()
declare -A clock_bounds_before=()
declare -A clock_bounds_after=()

usage() {
  printf '%s\n' \
    'Использование: scripts/claude-baseline.sh <build|install|run>' \
    '' \
    'build:' \
    '  CLAUDE_BASELINE_DIR       внешний checkout в ожидаемом коммите' \
    '' \
    'install:' \
    '  CLAUDE_BASELINE_PACKAGE   собранный .deb; иначе ожидаемый файл в dist/' \
    '  AWS_RUNNER_REGION         регион текущего Terraform-стенда' \
    '' \
    'run:' \
    '  CLAUDE_BASELINE_RATE      событий/с, по умолчанию 200000' \
    '  CLAUDE_BASELINE_RECEIVERS получателей на отдельных AWS-узлах: 1..3; по умолчанию 1' \
    '  CLAUDE_BASELINE_REPS      повторов, по умолчанию 3' \
    '  CLAUDE_BASELINE_SAMPLES   событий на повтор, по умолчанию 500000' \
    '  CLAUDE_BASELINE_DROP      начальных событий вне анализа, по умолчанию 16384' \
    '  CLAUDE_BASELINE_CLOCK_PROBE диагностическая UDP-проба: 0 или 1, по умолчанию 1'
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Не найдена обязательная команда: $1" >&2
    exit 1
  fi
}

check_source() {
  local source_dir commit
  source_dir="${CLAUDE_BASELINE_DIR:-}"
  if [[ -z "$source_dir" || ! -d "$source_dir/.git" ]]; then
    echo "CLAUDE_BASELINE_DIR должен указывать на внешний Git checkout" >&2
    exit 2
  fi
  source_dir="$(realpath -- "$source_dir")"
  commit="$(git -C "$source_dir" rev-parse HEAD)"
  if [[ "$commit" != "$expected_commit" ]]; then
    echo "Ожидался Claude baseline $expected_commit, найден $commit" >&2
    exit 2
  fi
  if [[ -n "$(git -C "$source_dir" status --porcelain)" ]]; then
    echo "Внешний Claude baseline содержит незакоммиченные изменения" >&2
    exit 2
  fi
  printf '%s\n' "$source_dir"
}

cmd_build() {
  local source_dir temporary host_uid host_gid
  require_command docker
  require_command git
  source_dir="$(check_source)"
  mkdir -p "$repo_root/dist"
  temporary="$(mktemp -d -t spectral-claude-baseline.XXXXXXXX)"
  trap "rm -rf -- $(printf '%q' "$temporary")" EXIT
  host_uid="$(id -u)"
  host_gid="$(id -g)"

  docker run --rm --platform linux/amd64 \
    --volume "$source_dir:/baseline:ro" \
    --volume "$temporary:/work" \
    --env "PACKAGE_VERSION=$package_version" \
    --env "PACKAGE_NAME=$package_name" \
    --env "EXPECTED_COMMIT=$expected_commit" \
    --env "HOST_UID=$host_uid" \
    --env "HOST_GID=$host_gid" \
    "$ubuntu_image" \
    bash -euxo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends build-essential ca-certificates python3
      rm -rf /var/lib/apt/lists/*

      install -d /work/source /work/package/DEBIAN /work/out
      cp -a /baseline/. /work/source/
      make --no-print-directory -C /work/source/harness clean all test
      make --no-print-directory -C /work/source/transport clean all test
      make --no-print-directory -C /work/source/tools clean all

      root=/work/package/usr/libexec/claude-baseline
      install -d "$root/harness/bin" "$root/transport/bin" "$root/tools/bin" \
        "$root/scripts"
      install -m 0755 /work/source/harness/bin/producer \
        /work/source/harness/bin/consumer "$root/harness/bin/"
      install -m 0755 /work/source/transport/bin/sender \
        /work/source/transport/bin/receiver "$root/transport/bin/"
      install -m 0755 /work/source/tools/bin/clock_probe "$root/tools/bin/"
      install -m 0755 /work/source/scripts/bench.sh \
        /work/source/scripts/check_cores.sh \
        /work/source/scripts/summarize.py "$root/scripts/"
      printf "%s\n" "$EXPECTED_COMMIT" >"$root/BASELINE_COMMIT"

      printf "%s\n" \
        "Package: claude-baseline" \
        "Version: $PACKAGE_VERSION" \
        "Architecture: amd64" \
        "Maintainer: spectral-task" \
        "Depends: libc6 (>= 2.39), libgcc-s1, libstdc++6, python3, procps" \
        "Description: immutable Claude c86cc26 comparison baseline" \
        >/work/package/DEBIAN/control
      dpkg-deb --root-owner-group --build /work/package "/work/out/$PACKAGE_NAME"
      chown -R "$HOST_UID:$HOST_GID" /work
    '

  docker run --rm --platform linux/amd64 \
    --volume "$temporary/out/$package_name:/tmp/claude-baseline.deb:ro" \
    "$ubuntu_image" \
    bash -euxo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends /tmp/claude-baseline.deb
      rm -rf /var/lib/apt/lists/*
      root=/usr/libexec/claude-baseline
      for binary in harness/bin/producer harness/bin/consumer \
        transport/bin/sender transport/bin/receiver tools/bin/clock_probe; do
        test -x "$root/$binary"
        ! ldd "$root/$binary" | grep -q "not found"
      done
      "$root/scripts/bench.sh" --help >/dev/null
      "$root/scripts/summarize.py" --help >/dev/null
      test "$(cat /usr/libexec/claude-baseline/BASELINE_COMMIT)" = \
        c86cc26ab2e84996137f922cf175d33e9a622c29
    '

  install -m 0644 "$temporary/out/$package_name" "$package_default"
  sha256sum "$package_default"
  echo "Готово: $package_default"
}

wait_command() {
  local command_id="$1"
  local expected="$2"
  local invocations total active failed
  local attempt
  for attempt in $(seq 1 90); do
    invocations="$(aws ssm list-command-invocations \
      --region "$region" --command-id "$command_id" --details --output json)"
    total="$(jq '.CommandInvocations | length' <<<"$invocations")"
    active="$(jq '[.CommandInvocations[] | select(
      .Status == "Pending" or .Status == "InProgress" or .Status == "Delayed"
    )] | length' <<<"$invocations")"
    failed="$(jq '[.CommandInvocations[] | select(
      .Status == "Failed" or .Status == "TimedOut" or
      .Status == "Cancelled" or .Status == "Cancelling"
    )] | length' <<<"$invocations")"
    if (( failed > 0 )); then
      jq '.CommandInvocations[] | {
        InstanceId, Status, StatusDetails,
        Plugins: [.CommandPlugins[] | {Name, Status, ResponseCode, Output}]
      }' <<<"$invocations" >&2
      return 1
    fi
    if (( total == expected && active == 0 )); then
      return 0
    fi
    sleep 2
  done
  echo "SSM command $command_id не завершилась вовремя" >&2
  return 1
}

cmd_install() {
  local package_path package_sha bucket object_key presigned_url params command_id
  local -a ids
  require_command aws
  require_command jq
  require_command terraform
  package_path="${CLAUDE_BASELINE_PACKAGE:-$package_default}"
  if [[ ! -f "$package_path" ]]; then
    echo "Не найден Claude baseline package: $package_path" >&2
    exit 2
  fi
  package_path="$(realpath -- "$package_path")"
  package_sha="$(sha256sum "$package_path" | awk '{print $1}')"
  bucket="$(terraform -chdir="$runner_dir" output -raw artifact_bucket)"
  mapfile -t ids < <(terraform -chdir="$runner_dir" \
    output -json runner_instance_ids | jq -r '.[]')
  if (( ${#ids[@]} != 4 )); then
    echo "Для установки ожидались четыре runner-узла" >&2
    exit 1
  fi

  object_key="results/claude-baseline/packages/$package_sha/$package_name"
  aws s3 cp "$package_path" "s3://$bucket/$object_key" \
    --region "$region" --only-show-errors
  presigned_url="$(aws s3 presign "s3://$bucket/$object_key" \
    --region "$region" --expires-in 900)"
  params="$(jq -nc \
    --arg url "$presigned_url" \
    --arg sha "$package_sha" \
    --arg commit "$expected_commit" \
    '{commands:[
      "set -eu",
      "url=" + ($url | @sh),
      "expected_sha=" + ($sha | @sh),
      "expected_commit=" + ($commit | @sh),
      "package=/tmp/claude-baseline.deb",
      "curl -fsSL \"$url\" -o \"$package\"",
      "printf \"%s  %s\\n\" \"$expected_sha\" \"$package\" | sha256sum --check -",
      "dpkg --install \"$package\"",
      "test \"$(cat /usr/libexec/claude-baseline/BASELINE_COMMIT)\" = \"$expected_commit\"",
      "for binary in harness/bin/producer harness/bin/consumer transport/bin/sender transport/bin/receiver tools/bin/clock_probe; do test -x \"/usr/libexec/claude-baseline/$binary\"; done",
      "echo claude_baseline_package_sha256=$expected_sha"
    ]}')"
  command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "${ids[@]}" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 180 \
    --output-s3-bucket-name "$bucket" \
    --output-s3-key-prefix "results/claude-baseline/setup/$package_sha" \
    --parameters "$params" \
    --query 'Command.CommandId' --output text)"
  wait_command "$command_id" "${#ids[@]}"
  echo "Claude baseline $expected_commit установлен на ${#ids[@]} узлах; SHA256=$package_sha"
}

validate_positive_integer() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name должен быть положительным целым числом: $value" >&2
    exit 2
  fi
}

shell_join() {
  local result="" part
  for part in "$@"; do
    printf -v part '%q' "$part"
    result+="$part "
  done
  printf '%s\n' "${result% }"
}

clock_snapshot() {
  local phase="$1" run_id="$2" bucket="$3"
  local params command_id instance_id output bound status
  local -a ids=("${@:4}")
  params="$(jq -Rs '{commands:[
    "export MAX_CLOCK_ERROR_NS=150000\n" +
    "export REQUIRE_PHC=1\n" + .
  ]}' \
    "$runner_dir/scripts/clock-snapshot.sh")"
  command_id="$(aws ssm send-command \
    --region "$region" --instance-ids "${ids[@]}" \
    --document-name AWS-RunShellScript --timeout-seconds 120 \
    --output-s3-bucket-name "$bucket" \
    --output-s3-key-prefix "results/claude-baseline/runs/$run_id/clock-$phase" \
    --parameters "$params" --query 'Command.CommandId' --output text)"
  wait_command "$command_id" "${#ids[@]}"
  for instance_id in "${ids[@]}"; do
    output="$(aws ssm get-command-invocation \
      --region "$region" --command-id "$command_id" --instance-id "$instance_id" \
      --query StandardOutputContent --output text)"
    bound="$(awk -F= '$1 == "clock_error_bound_ns" {print $2; exit}' <<<"$output")"
    status="$(awk -F= '$1 == "clock_snapshot_status" {print $2; exit}' <<<"$output")"
    echo "Claude clock $phase: instance=$instance_id bound_ns=$bound status=$status"
    if [[ ! "$bound" =~ ^[0-9]+$ || "$status" != "valid" ]]; then
      return 1
    fi
    case "$phase" in
      before) clock_bounds_before["$instance_id"]="$bound" ;;
      after) clock_bounds_after["$instance_id"]="$bound" ;;
      *) echo "Неизвестная фаза clock snapshot: $phase" >&2; return 2 ;;
    esac
  done
}

probe_direction() {
  local phase="$1" direction="$2" run_id="$3" bucket="$4"
  local initiator_id="$5" reflector_id="$6" reflector_ip="$7"
  local port=51900 reflector_params reflector_id_command ready_params ready_command
  local probe_params probe_command stop_params stop_command output attempt ready=0

  reflector_params="$(jq -nc --arg ip "$reflector_ip" --arg port "$port" \
    '{commands:[
      "pkill -INT -x clock_probe 2>/dev/null || true",
      "exec /usr/bin/taskset -c 2 /usr/libexec/spectral-task/bin/clock_probe " +
      "--reflect --bind " + $ip + " --port " + $port + " --core 2 --idle-ms 30000"
    ]}')"
  reflector_id_command="$(aws ssm send-command \
    --region "$region" --instance-ids "$reflector_id" \
    --document-name AWS-RunShellScript --timeout-seconds 60 \
    --output-s3-bucket-name "$bucket" \
    --output-s3-key-prefix "results/claude-baseline/runs/$run_id/probe-$phase/$direction/reflector" \
    --parameters "$reflector_params" --query 'Command.CommandId' --output text)"

  ready_params='{"commands":["ss -H -lun | grep -Eq \":51900[[:space:]]\""]}'
  for attempt in $(seq 1 20); do
    ready_command="$(aws ssm send-command \
      --region "$region" --instance-ids "$reflector_id" \
      --document-name AWS-RunShellScript --timeout-seconds 30 \
      --parameters "$ready_params" --query 'Command.CommandId' --output text)"
    if wait_command "$ready_command" 1 >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if (( ready != 1 )); then
    echo "Clock probe $phase/$direction: reflector не готов" >&2
    return 1
  fi

  probe_params="$(jq -nc --arg ip "$reflector_ip" --arg port "$port" \
    '{commands:[
      "exec /usr/bin/taskset -c 2 /usr/libexec/spectral-task/bin/clock_probe " +
      "--probe --peer " + $ip + " --port " + $port +
      " --count 5000 --rate 5000 --core 2"
    ]}')"
  probe_command="$(aws ssm send-command \
    --region "$region" --instance-ids "$initiator_id" \
    --document-name AWS-RunShellScript --timeout-seconds 60 \
    --output-s3-bucket-name "$bucket" \
    --output-s3-key-prefix "results/claude-baseline/runs/$run_id/probe-$phase/$direction/probe" \
    --parameters "$probe_params" --query 'Command.CommandId' --output text)"
  wait_command "$probe_command" 1

  stop_params='{"commands":["pkill -INT -x clock_probe 2>/dev/null || true"]}'
  stop_command="$(aws ssm send-command \
    --region "$region" --instance-ids "$reflector_id" \
    --document-name AWS-RunShellScript --timeout-seconds 30 \
    --parameters "$stop_params" --query 'Command.CommandId' --output text)"
  wait_command "$stop_command" 1
  wait_command "$reflector_id_command" 1

  output="$(aws ssm get-command-invocation \
    --region "$region" --command-id "$probe_command" --instance-id "$initiator_id" \
    --query StandardOutputContent --output text)"
  probe_offset="$(awk -F= '$1 == "clock_probe_offset_p50_ns" {print $2; exit}' <<<"$output")"
  if [[ ! "$probe_offset" =~ ^-?[0-9]+$ ]]; then
    echo "Clock probe $phase/$direction не вернул offset" >&2
    return 1
  fi
  echo "Claude probe $phase/$direction: offset_ns=$probe_offset"
}

probe_pair() {
  local phase="$1" run_id="$2" bucket="$3"
  local source_id="$4" source_ip="$5" receiver_id="$6" receiver_ip="$7"
  local forward reverse sum absolute_sum
  probe_direction "$phase" source-to-receiver "$run_id" "$bucket" \
    "$source_id" "$receiver_id" "$receiver_ip"
  forward="$probe_offset"
  probe_direction "$phase" receiver-to-source "$run_id" "$bucket" \
    "$receiver_id" "$source_id" "$source_ip"
  reverse="$probe_offset"
  pair_offset=$(((forward - reverse) / 2))
  sum=$((forward + reverse))
  absolute_sum="$sum"
  (( absolute_sum < 0 )) && absolute_sum=$((-absolute_sum))
  pair_disagreement=$((absolute_sum / 2))
  echo "Claude probe $phase: offset_ns=$pair_offset disagreement_ns=$pair_disagreement"
}

remote_cleanup() {
  if [[ -z "${cleanup_source_id:-}" ]]; then
    return
  fi
  local params command_id
  params='{"commands":["pkill -INT -x sender 2>/dev/null || true","pkill -INT -x receiver 2>/dev/null || true","pkill -TERM -x producer 2>/dev/null || true","pkill -TERM -x consumer 2>/dev/null || true"]}'
  command_id="$(aws ssm send-command --region "$region" \
    --instance-ids "${cleanup_ids[@]}" --document-name AWS-RunShellScript \
    --timeout-seconds 30 --parameters "$params" \
    --query 'Command.CommandId' --output text 2>/dev/null || true)"
  [[ -n "$command_id" ]] && wait_command "$command_id" "${#cleanup_ids[@]}" >/dev/null 2>&1 || true
}

cmd_run() {
  local rate="${CLAUDE_BASELINE_RATE:-200000}"
  local receiver_count="${CLAUDE_BASELINE_RECEIVERS:-1}"
  local reps="${CLAUDE_BASELINE_REPS:-3}"
  local samples="${CLAUDE_BASELINE_SAMPLES:-500000}"
  local drop="${CLAUDE_BASELINE_DROP:-16384}"
  local clock_probe="${CLAUDE_BASELINE_CLOCK_PROBE:-1}"
  local source_id source_ip receiver_id receiver_ip bucket run_id remote_out
  local receiver_args receiver_command receiver_params ready_params ready_command
  local source_args source_command source_params cleanup_command summary_command
  local summary_params summary_json artifact_command artifact_params artifact_key
  local package_sha runner_commit dirty
  local installed_spectral_sha spectral_package candidate candidate_sha
  local correction uncertainty phc_uncertainty b64_path raw_dir snapshot_dir attempt
  local source_before receiver_before source_after receiver_after
  local pair_before pair_after value
  local before_offset before_disagreement after_offset after_disagreement
  local offset_drift absolute_drift max_disagreement
  local ready=0 receiver_index receiver_number receiver_out artifact_dir
  local -a ids ips receiver_ids receiver_ips receiver_commands receiver_outs
  local -a before_offsets before_disagreements after_offsets after_disagreements
  local -a source_argv summary_files raw_summary_files
  local -a receiver_clock_uncertainties probe_corrections probe_uncertainties

  for tool in aws jq terraform base64 tar; do require_command "$tool"; done
  validate_positive_integer CLAUDE_BASELINE_RATE "$rate"
  validate_positive_integer CLAUDE_BASELINE_RECEIVERS "$receiver_count"
  validate_positive_integer CLAUDE_BASELINE_REPS "$reps"
  validate_positive_integer CLAUDE_BASELINE_SAMPLES "$samples"
  validate_positive_integer CLAUDE_BASELINE_DROP "$drop"
  if [[ "$clock_probe" != 0 && "$clock_probe" != 1 ]]; then
    echo "CLAUDE_BASELINE_CLOCK_PROBE должен быть 0 или 1" >&2
    exit 2
  fi
  if (( drop >= samples )); then
    echo "CLAUDE_BASELINE_DROP должен быть меньше CLAUDE_BASELINE_SAMPLES" >&2
    exit 2
  fi
  if (( receiver_count < 1 || receiver_count > 3 )); then
    echo "CLAUDE_BASELINE_RECEIVERS должен быть от 1 до 3" >&2
    exit 2
  fi

  installed_spectral_sha="$(terraform -chdir="$runner_dir" output -raw package_sha256)"
  spectral_package=""
  for candidate in "$repo_root"/dist/spectral-task_*.deb; do
    [[ -f "$candidate" ]] || continue
    candidate_sha="$(sha256sum "$candidate" | awk '{print $1}')"
    if [[ "$candidate_sha" == "$installed_spectral_sha" ]]; then
      spectral_package="$candidate"
      break
    fi
  done
  if [[ -z "$spectral_package" ]]; then
    echo "В dist/ не найден основной пакет с SHA256=$installed_spectral_sha" >&2
    exit 1
  fi
  AWS_RUNNER_PACKAGE="$spectral_package" AWS_RUNNER_TTL_MINUTES=120 AWS_RUNNER_AUTO_APPROVE=1 \
    "$runner_dir/scripts/cluster.sh" extend >/dev/null
  mapfile -t ids < <(terraform -chdir="$runner_dir" output -json runner_instance_ids | jq -r '.[]')
  mapfile -t ips < <(terraform -chdir="$runner_dir" output -json runner_private_ips | jq -r '.[]')
  if (( ${#ids[@]} < receiver_count + 1 || ${#ips[@]} < receiver_count + 1 )); then
    echo "Для Claude N=$receiver_count недостаточно runner-узлов" >&2
    exit 1
  fi
  source_id="${ids[0]}"; source_ip="${ips[0]}"
  receiver_ids=("${ids[@]:1:receiver_count}")
  receiver_ips=("${ips[@]:1:receiver_count}")
  receiver_id="${receiver_ids[0]}"; receiver_ip="${receiver_ips[0]}"
  bucket="$(terraform -chdir="$runner_dir" output -raw artifact_bucket)"
  run_id="claude-${short_commit}-r${rate}-n${receiver_count}-$(date -u +%Y%m%dT%H%M%SZ)"
  remote_out="/tmp/$run_id"
  raw_dir="$repo_root/artifacts/aws-runner/$run_id"
  snapshot_dir="$repo_root/data/baselines/claude-c86cc26/runs/$run_id"
  mkdir -p "$raw_dir" "$snapshot_dir"
  cleanup_source_id="$source_id"
  cleanup_ids=("$source_id" "${receiver_ids[@]}")
  trap remote_cleanup EXIT
  remote_cleanup

  clock_snapshot before "$run_id" "$bucket" "${cleanup_ids[@]}"
  for receiver_index in "${!receiver_ids[@]}"; do
    before_offsets[$receiver_index]=0
    before_disagreements[$receiver_index]=0
    if (( clock_probe == 1 )); then
      receiver_number=$((receiver_index + 1))
      probe_pair before "$run_id" "$bucket" \
        "$source_id" "$source_ip" \
        "${receiver_ids[$receiver_index]}" "${receiver_ips[$receiver_index]}"
      before_offsets[$receiver_index]="$pair_offset"
      before_disagreements[$receiver_index]="$pair_disagreement"
      echo "Claude receiver-$receiver_number probe before сохранён"
    fi
  done
  before_offset="${before_offsets[0]}"
  before_disagreement="${before_disagreements[0]}"

  for receiver_index in "${!receiver_ids[@]}"; do
    receiver_number=$((receiver_index + 1))
    receiver_id="${receiver_ids[$receiver_index]}"
    receiver_ip="${receiver_ips[$receiver_index]}"
    receiver_out="$remote_out/receiver-$receiver_number"
    receiver_outs[$receiver_index]="$receiver_out"
    receiver_args="$(shell_join \
      /usr/libexec/claude-baseline/scripts/bench.sh \
      --role recv --rate "$rate" --receivers 1 --reps "$reps" \
      --samples "$samples" --warmup-ms 2000 --drop "$drop" \
      --bind "$receiver_ip" --port 51000 --receiver-cores 2 --consumer-cores 3 \
      --src-shm "/claude_src_${run_id}" \
      --out-shm "/claude_out_${run_id}_r${receiver_number}" \
      --out-dir "$receiver_out" --tag "${run_id}-receiver-${receiver_number}" \
      --no-duplicate --backend udp)"
    receiver_params="$(jq -nc --arg out "$receiver_out" --arg command "$receiver_args" \
      '{commands:["set -eu", "rm -rf -- " + ($out | @sh), $command]}')"
    receiver_command="$(aws ssm send-command \
      --region "$region" --instance-ids "$receiver_id" \
      --document-name AWS-RunShellScript --timeout-seconds 300 \
      --output-s3-bucket-name "$bucket" \
      --output-s3-key-prefix "results/claude-baseline/runs/$run_id/receiver-$receiver_number" \
      --parameters "$receiver_params" --query 'Command.CommandId' --output text)"
    receiver_commands[$receiver_index]="$receiver_command"
  done

  ready_params='{"commands":["ss -H -lun | grep -Eq \":51000[[:space:]]\""]}'
  for receiver_index in "${!receiver_ids[@]}"; do
    receiver_number=$((receiver_index + 1))
    receiver_id="${receiver_ids[$receiver_index]}"
    ready=0
    for attempt in $(seq 1 30); do
      ready_command="$(aws ssm send-command --region "$region" \
        --instance-ids "$receiver_id" --document-name AWS-RunShellScript \
        --timeout-seconds 30 --parameters "$ready_params" \
        --query 'Command.CommandId' --output text)"
      if wait_command "$ready_command" 1 >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep 1
    done
    if (( ready != 1 )); then
      echo "Claude baseline receiver-$receiver_number не перешёл в READY" >&2
      exit 1
    fi
  done

  source_argv=(
    /usr/libexec/claude-baseline/scripts/bench.sh
    --role send --rate "$rate" --receivers "$receiver_count"
    --producer-core 2 --sender-core 3 --src-shm "/claude_src_${run_id}"
    --no-duplicate --backend udp --sender-idle-ms 60000
  )
  for receiver_ip in "${receiver_ips[@]}"; do
    source_argv+=(--peer "$receiver_ip:51000")
  done
  source_args="$(shell_join "${source_argv[@]}")"
  source_params="$(jq -nc --arg command "$source_args" '{commands:[$command]}')"
  source_command="$(aws ssm send-command \
    --region "$region" --instance-ids "$source_id" \
    --document-name AWS-RunShellScript --timeout-seconds 300 \
    --output-s3-bucket-name "$bucket" \
    --output-s3-key-prefix "results/claude-baseline/runs/$run_id/source" \
    --parameters "$source_params" --query 'Command.CommandId' --output text)"
  for receiver_command in "${receiver_commands[@]}"; do
    wait_command "$receiver_command" 1
  done
  remote_cleanup

  clock_snapshot after "$run_id" "$bucket" "${cleanup_ids[@]}"
  for receiver_index in "${!receiver_ids[@]}"; do
    after_offsets[$receiver_index]=0
    after_disagreements[$receiver_index]=0
    if (( clock_probe == 1 )); then
      receiver_number=$((receiver_index + 1))
      probe_pair after "$run_id" "$bucket" \
        "$source_id" "$source_ip" \
        "${receiver_ids[$receiver_index]}" "${receiver_ips[$receiver_index]}"
      after_offsets[$receiver_index]="$pair_offset"
      after_disagreements[$receiver_index]="$pair_disagreement"
      echo "Claude receiver-$receiver_number probe after сохранён"
    fi
  done

  source_before="${clock_bounds_before[$source_id]:-}"
  source_after="${clock_bounds_after[$source_id]:-}"
  phc_uncertainty=0
  for receiver_index in "${!receiver_ids[@]}"; do
    receiver_number=$((receiver_index + 1))
    receiver_id="${receiver_ids[$receiver_index]}"
    receiver_ip="${receiver_ips[$receiver_index]}"
    receiver_before="${clock_bounds_before[$receiver_id]:-}"
    receiver_after="${clock_bounds_after[$receiver_id]:-}"
    for value in "$source_before" "$receiver_before" "$source_after" "$receiver_after"; do
      if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "Нет корректной PHC-границы Claude receiver-$receiver_number" >&2
        exit 1
      fi
    done
    pair_before=$((source_before + receiver_before))
    pair_after=$((source_after + receiver_after))
    receiver_clock_uncertainties[$receiver_index]="$pair_before"
    (( pair_after > receiver_clock_uncertainties[$receiver_index] )) &&
      receiver_clock_uncertainties[$receiver_index]="$pair_after"
    if (( receiver_clock_uncertainties[$receiver_index] > 150000 )); then
      echo "PHC-граница Claude receiver-$receiver_number ${receiver_clock_uncertainties[$receiver_index]} превышает 150000 нс" >&2
      exit 1
    fi
    (( receiver_clock_uncertainties[$receiver_index] > phc_uncertainty )) &&
      phc_uncertainty="${receiver_clock_uncertainties[$receiver_index]}"

    before_offset="${before_offsets[$receiver_index]}"
    before_disagreement="${before_disagreements[$receiver_index]}"
    after_offset="${after_offsets[$receiver_index]}"
    after_disagreement="${after_disagreements[$receiver_index]}"
    offset_drift=$((after_offset - before_offset))
    absolute_drift="$offset_drift"
    (( absolute_drift < 0 )) && absolute_drift=$((-absolute_drift))
    max_disagreement="$before_disagreement"
    (( after_disagreement > max_disagreement )) &&
      max_disagreement="$after_disagreement"
    correction=$(((before_offset + after_offset) / 2))
    uncertainty=$((max_disagreement + absolute_drift / 2))
    if (( clock_probe == 1 && uncertainty > 150000 )); then
      # UDP probe is deliberately diagnostic only.  Network asymmetry can make
      # this bound large even when the shared ENA PHC scale above is valid; it
      # must never invalidate or correct the primary latency measurement.
      echo "Предупреждение: диагностическая UDP clock-probe Claude receiver-$receiver_number имеет uncertainty_ns=$uncertainty" >&2
    fi
    probe_corrections[$receiver_index]="$correction"
    probe_uncertainties[$receiver_index]="$uncertainty"

    # UDP probe остаётся только диагностикой: primary-метрика использует сырые
    # E2E timestamps на общей ENA PHC-шкале.
    jq -n --arg method aws_ena_phc \
      --argjson source_before_error_bound_ns "$source_before" \
      --argjson receiver_before_error_bound_ns "$receiver_before" \
      --argjson source_after_error_bound_ns "$source_after" \
      --argjson receiver_after_error_bound_ns "$receiver_after" \
      --argjson before_pair_error_bound_ns "$pair_before" \
      --argjson after_pair_error_bound_ns "$pair_after" \
      --argjson phc_uncertainty_ns "${receiver_clock_uncertainties[$receiver_index]}" \
      --argjson before_offset_ns "$before_offset" \
      --argjson before_direction_disagreement_ns "$before_disagreement" \
      --argjson after_offset_ns "$after_offset" \
      --argjson after_direction_disagreement_ns "$after_disagreement" \
      --argjson offset_drift_ns "$offset_drift" \
      --argjson probe_correction_ns "$correction" \
      --argjson probe_uncertainty_ns "$uncertainty" \
      --argjson probe_enabled "$clock_probe" \
      '{method:$method,
        source_before_error_bound_ns:$source_before_error_bound_ns,
        receiver_before_error_bound_ns:$receiver_before_error_bound_ns,
        source_after_error_bound_ns:$source_after_error_bound_ns,
        receiver_after_error_bound_ns:$receiver_after_error_bound_ns,
        before_pair_error_bound_ns:$before_pair_error_bound_ns,
        after_pair_error_bound_ns:$after_pair_error_bound_ns,
        phc_uncertainty_ns:$phc_uncertainty_ns,
        before_offset_ns:$before_offset_ns,
        before_direction_disagreement_ns:$before_direction_disagreement_ns,
        after_offset_ns:$after_offset_ns,
        after_direction_disagreement_ns:$after_direction_disagreement_ns,
        offset_drift_ns:$offset_drift_ns,
        correction_ns:0, uncertainty_ns:$phc_uncertainty_ns,
        probe_method:(if $probe_enabled == 1 then "udp_bidirectional_probe" else null end),
        probe_correction_ns:(if $probe_enabled == 1 then $probe_correction_ns else null end),
        probe_uncertainty_ns:(if $probe_enabled == 1 then $probe_uncertainty_ns else null end),
        status:"valid"}' >"$snapshot_dir/clock-bracket-receiver-$receiver_number.json"

    receiver_out="${receiver_outs[$receiver_index]}"
    summary_params="$(jq -nc --arg out "$receiver_out" --arg drop "$drop" \
      '{commands:[
        "/usr/libexec/claude-baseline/scripts/summarize.py --drop " + $drop +
        " --json " + ($out | @sh)
      ]}')"
    summary_command="$(aws ssm send-command --region "$region" \
      --instance-ids "$receiver_id" --document-name AWS-RunShellScript \
      --timeout-seconds 120 --parameters "$summary_params" \
      --query 'Command.CommandId' --output text)"
    wait_command "$summary_command" 1
    summary_json="$(aws ssm get-command-invocation --region "$region" \
      --command-id "$summary_command" --instance-id "$receiver_id" \
      --query StandardOutputContent --output text)"
    raw_summary_files[$receiver_index]="$snapshot_dir/receiver-$receiver_number-summary-raw.json"
    summary_files[$receiver_index]="$snapshot_dir/receiver-$receiver_number-summary.json"
    jq . <<<"$summary_json" >"${raw_summary_files[$receiver_index]}"
    jq -n --slurpfile raw "${raw_summary_files[$receiver_index]}" \
      --argjson receiver_index "$receiver_number" \
      --arg instance_id "$receiver_id" --arg private_ip "$receiver_ip" \
      --argjson correction_ns "$correction" \
      --argjson probe_uncertainty_ns "$uncertainty" \
      --argjson phc_uncertainty_ns "${receiver_clock_uncertainties[$receiver_index]}" \
      --argjson probe_enabled "$clock_probe" \
      '{receiver_index:$receiver_index, instance_id:$instance_id,
        private_ip:$private_ip, raw:$raw[0][0], primary_ns:($raw[0][0] | {
          min:.min.median, p50:.p50.median, p99:.p99.median,
          p99_9:.["p99.9"].median, p99_99:.["p99.99"].median,
          max:.max.median
        }),
        clock_correction_ns:0, clock_method:"aws_ena_phc",
        clock_uncertainty_ns:$phc_uncertainty_ns,
        clock_probe_correction_ns:(if $probe_enabled == 1 then $correction_ns else null end),
        clock_probe_method:(if $probe_enabled == 1 then "udp_bidirectional_probe" else null end),
        clock_probe_uncertainty_ns:(if $probe_enabled == 1 then $probe_uncertainty_ns else null end),
        corrected_ns:($raw[0][0] | {
          min:(.min.median - $correction_ns),
          p50:(.p50.median - $correction_ns),
          p99:(.p99.median - $correction_ns),
          p99_9:(.["p99.9"].median - $correction_ns),
          p99_99:(.["p99.99"].median - $correction_ns),
          max:(.max.median - $correction_ns)
        })}' >"${summary_files[$receiver_index]}"
  done

  if (( receiver_count == 1 )); then
    cp "${raw_summary_files[0]}" "$snapshot_dir/summary-raw.json"
    cp "${summary_files[0]}" "$snapshot_dir/summary.json"
    cp "$snapshot_dir/clock-bracket-receiver-1.json" \
      "$snapshot_dir/clock-bracket.json"
  else
    jq -s '.' "${raw_summary_files[@]}" >"$snapshot_dir/summary-raw.json"
    jq -s --argjson receiver_count "$receiver_count" '
      {receiver_count:$receiver_count, receivers:.,
       worst_receiver_primary_ns:{
         min:(map(.primary_ns.min)|max), p50:(map(.primary_ns.p50)|max),
         p99:(map(.primary_ns.p99)|max), p99_9:(map(.primary_ns.p99_9)|max),
         p99_99:(map(.primary_ns.p99_99)|max), max:(map(.primary_ns.max)|max)
       }}' "${summary_files[@]}" >"$snapshot_dir/summary.json"
  fi

  for receiver_index in "${!receiver_ids[@]}"; do
    receiver_number=$((receiver_index + 1))
    receiver_id="${receiver_ids[$receiver_index]}"
    receiver_out="${receiver_outs[$receiver_index]}"
    artifact_dir="$raw_dir/receivers/$receiver_id"
    mkdir -p "$artifact_dir"
    artifact_params="$(jq -nc --arg out "$receiver_out" \
      '{commands:["tar -C " + ($out | @sh) + " -czf - . | base64 -w 76"]}')"
    artifact_command="$(aws ssm send-command --region "$region" \
      --instance-ids "$receiver_id" --document-name AWS-RunShellScript \
      --timeout-seconds 180 --output-s3-bucket-name "$bucket" \
      --output-s3-key-prefix "results/claude-baseline/runs/$run_id/artifact-receiver-$receiver_number" \
      --parameters "$artifact_params" --query 'Command.CommandId' --output text)"
    wait_command "$artifact_command" 1
    artifact_key="results/claude-baseline/runs/$run_id/artifact-receiver-$receiver_number/$artifact_command/$receiver_id/awsrunShellScript/0.awsrunShellScript/stdout"
    b64_path="$artifact_dir/result.tar.gz.b64"
    for attempt in $(seq 1 30); do
      if aws s3 cp "s3://$bucket/$artifact_key" "$b64_path" \
          --region "$region" --only-show-errors 2>/dev/null; then break; fi
      sleep 2
    done
    base64 --decode "$b64_path" >"$artifact_dir/result.tar.gz"
    tar -xzf "$artifact_dir/result.tar.gz" -C "$artifact_dir"
  done
  (
    cd "$raw_dir"
    find receivers -type f \( -name 'result.tar.gz' -o -name 'rep*_c*.csv' \) \
      -print0 | sort -z | xargs -0 sha256sum
  ) >"$snapshot_dir/raw-artifacts.sha256"

  package_sha="$(sha256sum "${CLAUDE_BASELINE_PACKAGE:-$package_default}" | awk '{print $1}')"
  runner_commit="$(git -C "$repo_root" rev-parse HEAD)"
  dirty=false; [[ -n "$(git -C "$repo_root" status --porcelain)" ]] && dirty=true
  jq -n --arg run_id "$run_id" --arg baseline_commit "$expected_commit" \
    --arg package_sha256 "$package_sha" --arg runner_commit "$runner_commit" \
    --argjson runner_dirty "$dirty" --arg source_instance_id "$source_id" \
    --argjson receiver_instance_ids "$(printf '%s\n' "${receiver_ids[@]}" | jq -Rsc 'split("\n")[:-1]')" \
    --arg source_ip "$source_ip" \
    --argjson receiver_ips "$(printf '%s\n' "${receiver_ips[@]}" | jq -Rsc 'split("\n")[:-1]')" \
    --argjson receivers "$receiver_count" --argjson rate "$rate" \
    --argjson reps "$reps" --argjson samples_per_rep "$samples" \
    --argjson dropped_prefix_per_rep "$drop" \
    --argjson clock_probe_enabled "$clock_probe" \
    --argjson clock_uncertainty_ns "$phc_uncertainty" \
    '{run_id:$run_id, baseline_commit:$baseline_commit,
      package_sha256:$package_sha256, runner_commit:$runner_commit,
      runner_dirty:$runner_dirty, networking_backend:"udp", duplicate:false,
      receivers:$receivers, rate:$rate, reps:$reps, samples_per_rep:$samples_per_rep,
      dropped_prefix_per_rep:$dropped_prefix_per_rep,
      clock_probe_enabled:$clock_probe_enabled,
      source_instance_id:$source_instance_id,
      receiver_instance_ids:$receiver_instance_ids,
      source_ip:$source_ip, receiver_ips:$receiver_ips,
      clock_method:"aws_ena_phc",
      clock_correction_ns:0,
      clock_uncertainty_ns:$clock_uncertainty_ns}' >"$snapshot_dir/manifest.json"
  cp "$snapshot_dir/manifest.json" "$snapshot_dir/summary-raw.json" \
    "$snapshot_dir/summary.json" "$snapshot_dir/raw-artifacts.sha256" \
    "$raw_dir/"
  cp "$snapshot_dir"/clock-bracket-receiver-*.json "$raw_dir/"
  aws s3 cp "$snapshot_dir/manifest.json" \
    "s3://$bucket/results/claude-baseline/runs/$run_id/manifest.json" \
    --region "$region" --only-show-errors
  trap - EXIT
  cleanup_source_id=""
  echo "Claude baseline run: $run_id"
  jq . "$snapshot_dir/summary.json"
  echo "Clock primary=aws_ena_phc correction_ns=0 uncertainty_ns=$phc_uncertainty"
  if (( clock_probe == 1 )); then
    for receiver_index in "${!receiver_ids[@]}"; do
      receiver_number=$((receiver_index + 1))
      echo "Clock UDP receiver-$receiver_number diagnostic correction_ns=${probe_corrections[$receiver_index]} uncertainty_ns=${probe_uncertainties[$receiver_index]}"
    done
  fi
  echo "Snapshot: $snapshot_dir"
  echo "Raw artifacts: $raw_dir"
}

case "${1:-}" in
  build) cmd_build ;;
  install) cmd_install ;;
  run) cmd_run ;;
  -h|--help|'') usage ;;
  *) usage >&2; exit 2 ;;
esac
