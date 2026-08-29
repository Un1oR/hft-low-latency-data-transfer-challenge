#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runner_dir="$(cd -- "$script_dir/.." && pwd)"
repo_root="$(cd -- "$runner_dir/../.." && pwd)"
region="${AWS_RUNNER_REGION:-us-east-1}"
runtime_minutes="${AWS_RUNNER_TTL_MINUTES:-15}"
max_clock_error_ns="${AWS_RUNNER_MAX_CLOCK_ERROR_NS:-150000}"
declare -A clock_bounds_before=()
declare -A clock_bounds_after=()

terraform_cmd=(terraform -chdir="$runner_dir")
approval_args=()
if [[ "${AWS_RUNNER_AUTO_APPROVE:-0}" == "1" ]]; then
  approval_args=(-auto-approve)
fi

usage() {
  cat <<'USAGE'
Использование: cluster.sh <up|start|stop|update|extend|run|fetch|status|audit|down|e2e>

Переменные окружения:
  AWS_RUNNER_PACKAGE       путь к .deb; иначе нужен ровно один dist/*.deb
  AWS_RUNNER_AVAILABILITY_ZONE  желаемая AZ; иначе новая инфраструктура берёт
                                первую совместимую, а существующая помнит свою
  AWS_RUNNER_TTL_MINUTES   TTL от up/extend, по умолчанию 15
  AWS_RUNNER_AUTO_APPROVE  1 добавляет -auto-approve к Terraform
  AWS_RUNNER_MESSAGE_COUNT число сообщений, по умолчанию 1000000
  AWS_RUNNER_MESSAGE_RATE  скорость producer, по умолчанию 200000
  AWS_RUNNER_WARMUP_MS     прогрев полным потоком перед измерением,
                           по умолчанию 2000 мс
  AWS_RUNNER_STAGE_TIMESTAMPS  1 добавляет диагностическую разбивку задержки
                               по этапам; по умолчанию 0
  AWS_RUNNER_DPDK_RX_HARDWARE_TIMESTAMPS  1 использует аппаратную метку ENA
                               рядом с программной; требует DPDK и stage timestamps
  AWS_RUNNER_DPDK_RX_BURST_SIZE  максимум дейтаграмм за один вызов DPDK RX,
                               от 1 до 32; по умолчанию 32
  AWS_RUNNER_DPDK_RX_FREE_THRESHOLD  сколько освобождённых RX-буферов накопить
                               до возврата карте; 0 выбирает порог ENA PMD
  AWS_RUNNER_RECEIVER_COUNT число получателей: 1, 2 или 3; по умолчанию 1
  AWS_RUNNER_MAX_CLOCK_ERROR_NS  допустимая локальная граница ошибки часов,
                                по умолчанию 150000 нс
  AWS_RUNNER_CLOCK_PROBE    1 запускает дополнительную UDP-диагностику
                            асимметрии; на PHC-результат она не влияет
  AWS_RUNNER_NETWORKING_BACKEND  socket или dpdk; по умолчанию socket
  AWS_RUNNER_BATCH_WAIT_NS  максимальное ожидание целевой пачки;
                            по умолчанию 1200 нс, при цели 1 фактически 0
  AWS_RUNNER_BATCH_TARGET_FRAMES  целевое число событий в пачке или auto;
                            auto для DPDK удерживает суммарный TX ниже бюджета,
                            а для socket выбирает 1 без ожидания
  AWS_RUNNER_BATCH_PPS_BUDGET  суммарный TX-бюджет для автоматической цели;
                            по умолчанию 2000000 пакетов/с
  AWS_RUNNER_LLQ_PROBE_MINIMAL_WIRE  1 включает диагностический wire-формат,
                            целиком помещающий одиночный пакет в 96 байт LLQ
  AWS_RUNNER_LLQ_PROBE_MIXED_WIRE  1 чередует полный и минимальный wire-формат
                            по схеме ABBA внутри одного запуска
  AWS_RUNNER_COMPACT_WIRE  1 включает рабочий lossless wire-кодек без reserved;
                            BBO/Trade/OrderBook занимают 60/76/150 байт
  AWS_RUNNER_COMPACT_WIRE_MIXED  1 чередует полный и lossless compact форматы
                            по схеме ABBA внутри одного DPDK-прогона
  AWS_RUNNER_DPDK_LLQ_POLICY  политика ENA LLQ: 0..3, по умолчанию 1
  AWS_RUNNER_RUN_ID        run для fetch; иначе выбирается последний в S3

Команды DPDK:
  dpdk-prepare  идемпотентно готовит все benchmark-узлы и привязывает data ENI
  dpdk-verify   выполняет короткий testpmd -> testpmd функциональный тест
  dpdk-ready    последовательно выполняет prepare и verify

Команды точного времени:
  phc-prepare   ставит штатное AWS-ядро и официальный ENA с поддержкой PHC
  phc-verify    проверяет PHC, chrony, границу ошибки часов и DPDK data ENI
  phc-ready     последовательно выполняет prepare, reboot и verify
USAGE
}

require_tools() {
  local tool
  for tool in aws jq terraform; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Не найдена обязательная команда: $tool" >&2
      exit 1
    fi
  done
}

validate_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name должен быть положительным целым числом: $value" >&2
    exit 2
  fi
}

state_package_path() {
  local path
  path="$(${terraform_cmd[@]} state pull 2>/dev/null | jq -r '
    .resources[]? |
    select(.type == "aws_s3_object" and .name == "package") |
    .instances[0].attributes.source // empty
  ' | head -n 1)"
  if [[ -n "$path" && -f "$path" ]]; then
    printf '%s\n' "$path"
  fi
}

resolve_package() {
  local prefer_state="${1:-1}"
  local state_path latest_path
  local -a packages
  if [[ -n "${AWS_RUNNER_PACKAGE:-}" ]]; then
    if [[ ! -f "$AWS_RUNNER_PACKAGE" ]]; then
      echo "Не найден AWS_RUNNER_PACKAGE: $AWS_RUNNER_PACKAGE" >&2
      exit 1
    fi
    realpath -- "$AWS_RUNNER_PACKAGE"
    return
  fi

  if [[ "$prefer_state" == "1" ]]; then
    state_path="$(state_package_path)"
    if [[ -n "$state_path" ]]; then
      realpath -- "$state_path"
      return
    fi
  fi

  if [[ -f "$repo_root/dist/.latest-package" ]]; then
    latest_path="$(head -n 1 "$repo_root/dist/.latest-package")"
    if [[ -f "$latest_path" ]]; then
      realpath -- "$latest_path"
      return
    fi
  fi

  shopt -s nullglob
  packages=("$repo_root"/dist/*.deb)
  shopt -u nullglob
  if (( ${#packages[@]} != 1 )); then
    echo "Нужен ровно один dist/*.deb или явный AWS_RUNNER_PACKAGE" >&2
    exit 1
  fi
  realpath -- "${packages[0]}"
}

current_runtime_minutes() {
  local value
  value="$(${terraform_cmd[@]} output -raw runtime_minutes 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$runtime_minutes"
  fi
}

current_availability_zone() {
  local value
  if [[ -n "${AWS_RUNNER_AVAILABILITY_ZONE:-}" ]]; then
    printf '%s\n' "$AWS_RUNNER_AVAILABILITY_ZONE"
    return
  fi
  value="$(${terraform_cmd[@]} output -raw availability_zone 2>/dev/null || true)"
  if [[ -n "$value" && "$value" != "null" ]]; then
    printf '%s\n' "$value"
  fi
}

current_paused() {
  local value
  value="$(${terraform_cmd[@]} output -raw cluster_paused 2>/dev/null || true)"
  if [[ "$value" == "true" ]]; then
    printf '%s\n' true
  else
    printf '%s\n' false
  fi
}

current_power_state() {
  local value
  value="$(${terraform_cmd[@]} output -raw cluster_power_state 2>/dev/null || true)"
  case "$value" in
    running|stopped) printf '%s\n' "$value" ;;
    *) printf '%s\n' running ;;
  esac
}

current_bootstrap_association_enabled() {
  local value association_id
  value="$(${terraform_cmd[@]} output -raw bootstrap_association_enabled 2>/dev/null || true)"
  association_id="$(${terraform_cmd[@]} output -raw bootstrap_association_id 2>/dev/null || true)"
  if [[ "$value" == "true" && -n "$association_id" && "$association_id" != "null" ]]; then
    printf '%s\n' true
  else
    printf '%s\n' false
  fi
}

current_ttl_association_enabled() {
  local value association_id
  value="$(${terraform_cmd[@]} output -raw ttl_association_enabled 2>/dev/null || true)"
  association_id="$(${terraform_cmd[@]} output -raw ttl_association_id 2>/dev/null || true)"
  if [[ "$value" == "true" && -n "$association_id" && "$association_id" != "null" ]]; then
    printf '%s\n' true
  else
    printf '%s\n' false
  fi
}

cluster_lifecycle_state() {
  local expected_runners expected_nodes expires_at expires_epoch now_epoch
  local describe_output state
  local -a ids states

  if ! "${terraform_cmd[@]}" output -json runner_instance_ids >/dev/null 2>&1; then
    printf '%s\n' absent
    return
  fi

  mapfile -t ids < <(all_instance_ids 2>/dev/null || true)
  expected_runners="$(${terraform_cmd[@]} output -raw benchmark_node_count 2>/dev/null || true)"
  if [[ ! "$expected_runners" =~ ^[1-9][0-9]*$ ]]; then
    echo "Не удалось определить ожидаемое число runner-узлов из Terraform state" >&2
    printf '%s\n' unknown
    return
  fi
  expected_nodes=$((expected_runners + 1))
  if (( ${#ids[@]} != expected_nodes )); then
    echo "Terraform state содержит ${#ids[@]} из $expected_nodes ожидаемых EC2" >&2
    printf '%s\n' recover
    return
  fi

  if ! describe_output="$(aws ec2 describe-instances \
      --region "$region" \
      --instance-ids "${ids[@]}" \
      --query 'Reservations[].Instances[].State.Name' \
      --output text 2>&1)"; then
    if [[ "$describe_output" == *"InvalidInstanceID.NotFound"* ]]; then
      echo "Часть EC2 из Terraform state уже удалена из AWS" >&2
      printf '%s\n' recover
    else
      echo "Не удалось проверить фактическое состояние EC2: $describe_output" >&2
      printf '%s\n' unknown
    fi
    return
  fi
  read -r -a states <<<"$describe_output"
  if (( ${#states[@]} != expected_nodes )); then
    echo "AWS вернул состояние ${#states[@]} из $expected_nodes ожидаемых EC2" >&2
    printf '%s\n' recover
    return
  fi
  for state in "${states[@]}"; do
    if [[ "$state" != "running" ]]; then
      echo "Не все EC2 из Terraform state запущены: $describe_output" >&2
      printf '%s\n' recover
      return
    fi
  done

  expires_at="$(${terraform_cmd[@]} output -raw expires_at 2>/dev/null || true)"
  if ! expires_epoch="$(date -u -d "$expires_at" +%s 2>/dev/null)"; then
    echo "Не удалось разобрать expires_at из Terraform state: $expires_at" >&2
    printf '%s\n' unknown
    return
  fi
  now_epoch="$(date -u +%s)"
  if (( expires_epoch <= now_epoch )); then
    echo "TTL стенда уже истёк: $expires_at" >&2
    printf '%s\n' recover
    return
  fi

  printf '%s\n' healthy
}

terraform_init() {
  "${terraform_cmd[@]}" init -input=true
}

run_terraform() {
  local log_dir log_path status
  if [[ "${AWS_RUNNER_COMPACT_OUTPUT:-0}" != "1" ]]; then
    "$@"
    return
  fi

  log_dir="${terraform_log_dir:-$repo_root/artifacts/aws-runner/terraform}"
  mkdir -p "$log_dir"
  log_path="$log_dir/$(date -u +%Y%m%dT%H%M%S)-$RANDOM.log"
  echo "Terraform: полный вывод сохраняется в $log_path"
  set +e
  "$@" >"$log_path" 2>&1
  status=$?
  set -e
  if (( status != 0 )); then
    echo "Terraform завершился с кодом $status; последние 120 строк:" >&2
    tail -n 120 "$log_path" >&2
    return "$status"
  fi
  tail -n 20 "$log_path"
}

terraform_apply() {
  local package_path="$1"
  local ttl="$2"
  local paused="$3"
  local power_state="$4"
  local bootstrap_enabled="$5"
  local ttl_enabled="$6"
  local availability_zone
  local -a availability_zone_args=()
  shift 6
  availability_zone="$(current_availability_zone)"
  if [[ -n "$availability_zone" ]]; then
    availability_zone_args=(-var="availability_zone=$availability_zone")
  fi
  run_terraform "${terraform_cmd[@]}" apply -no-color "${approval_args[@]}" \
    -var="package_path=$package_path" \
    -var="max_runtime_minutes=$ttl" \
    -var="cluster_paused=$paused" \
    -var="cluster_power_state=$power_state" \
    -var="bootstrap_association_enabled=$bootstrap_enabled" \
    -var="ttl_association_enabled=$ttl_enabled" \
    "${availability_zone_args[@]}" \
    "$@"
}

latest_association_execution() {
  local association_id="$1"
  aws ssm describe-association-executions \
    --region "$region" \
    --association-id "$association_id" \
    --max-results 1 \
    --query 'AssociationExecutions[0].ExecutionId' \
    --output text 2>/dev/null || true
}

wait_association_execution() {
  local association_id="$1"
  local execution_id="$2"
  local status detailed active_targets
  local attempt
  for attempt in $(seq 1 100); do
    read -r status detailed < <(
      aws ssm describe-association-executions \
        --region "$region" \
        --association-id "$association_id" \
        --max-results 20 \
        --query "AssociationExecutions[?ExecutionId=='$execution_id']|[0].[Status,DetailedStatus]" \
        --output text 2>/dev/null || true
    )
    case "$status" in
      Success)
        echo "SSM association $association_id: execution $execution_id завершён успешно"
        return 0
        ;;
      Failed|TimedOut|Cancelled)
        # Общий статус становится Failed сразу после Undeliverable на одном
        # target, хотя другие targets ещё могут выполнять длинный bootstrap.
        # Повтор поверх них ломает DKMS working directory и конфликтует с уже
        # созданным reboot timer. Сначала дожидаемся конечного состояния всех.
        active_targets="$(aws ssm describe-association-execution-targets \
          --region "$region" \
          --association-id "$association_id" \
          --execution-id "$execution_id" \
          --query "AssociationExecutionTargets[?Status=='Pending' || Status=='InProgress'].ResourceId" \
          --output text 2>/dev/null || true)"
        if [[ -n "$active_targets" && "$active_targets" != "None" ]]; then
          sleep 3
          continue
        fi
        echo "SSM association $association_id: $status ($detailed)" >&2
        aws ssm describe-association-execution-targets \
          --region "$region" \
          --association-id "$association_id" \
          --execution-id "$execution_id" \
          --output json >&2 || true
        return 1
        ;;
    esac
    sleep 3
  done
  echo "SSM association $association_id не завершился за 5 минут" >&2
  return 1
}

wait_new_association_execution() {
  local association_id="$1"
  local previous_id="${2:-}"
  local current_id=""
  local attempt

  # Любой штатный сценарий меняет параметры association через Terraform:
  # SHA пакета, абсолютный expires_at или cluster_paused. Поэтому нового
  # execution ждём, но не обходим Terraform через start-associations-once.
  for attempt in $(seq 1 100); do
    current_id="$(latest_association_execution "$association_id")"
    if [[ -n "$current_id" && "$current_id" != "None" && \
          "$current_id" != "$previous_id" ]]; then
      wait_association_execution "$association_id" "$current_id"
      return
    fi
    sleep 3
  done
  echo "У association $association_id не появился новый execution за 5 минут" >&2
  return 1
}

wait_bootstrap_execution() {
  local association_id="$1"
  local previous_id="${2:-}"
  local latest_id
  local attempt

  if wait_new_association_execution "$association_id" "$previous_id"; then
    return 0
  fi

  # S3 object и role policy меняются одним Terraform apply. IAM иногда ещё
  # несколько секунд возвращает 403 уже запущенному AWS-RunRemoteScript.
  # Association хранит точный SHA пакета, поэтому безопасно повторяем именно
  # ту же установку, не меняя желаемое состояние Terraform.
  for attempt in 1 2; do
    latest_id="$(latest_association_execution "$association_id")"
    echo "Повтор bootstrap association после неудачной доставки пакета ($attempt/2)" >&2
    aws ssm start-associations-once \
      --region "$region" --association-ids "$association_id"
    if wait_new_association_execution "$association_id" "$latest_id"; then
      return 0
    fi
  done
  return 1
}

wait_command() {
  local command_id="$1"
  local expected="$2"
  local quiet_failures="${3:-0}"
  local max_attempts="${4:-80}"
  local invocations total active failed
  local attempt
  for attempt in $(seq 1 "$max_attempts"); do
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
      if [[ "$quiet_failures" != "1" ]]; then
        jq '.CommandInvocations[] | {
          InstanceId, Status, StatusDetails,
          Plugins: [.CommandPlugins[] | {Name, Status, ResponseCode, Output}]
        }' <<<"$invocations" >&2
      fi
      return 1
    fi
    if (( total == expected && active == 0 )); then
      return 0
    fi
    sleep 2
  done
  echo "SSM command $command_id не завершилась за отведённое время" >&2
  return 1
}

runner_ids() {
  "${terraform_cmd[@]}" output -json runner_instance_ids | jq -r '.[]'
}

cmd_dpdk_prepare() {
  local params command_id instance_id output
  local -a ids

  if [[ "$(cluster_lifecycle_state)" != "healthy" ]]; then
    echo "DPDK подготавливается только на живом стенде с действующим TTL" >&2
    return 1
  fi
  wait_runners_ready
  mapfile -t ids < <(runner_ids)
  params="$(jq -Rs '{commands:[.]}' "$script_dir/dpdk-prepare.sh")"
  command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "${ids[@]}" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 900 \
    --parameters "$params" \
    --query 'Command.CommandId' --output text)"
  wait_command "$command_id" "${#ids[@]}"

  for instance_id in "${ids[@]}"; do
    output="$(aws ssm get-command-invocation \
      --region "$region" --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query StandardOutputContent --output text)"
    if ! grep -q '^dpdk_prepare_status=ready$' <<<"$output"; then
      echo "Узел $instance_id не подтвердил готовность DPDK" >&2
      return 1
    fi
    echo "DPDK ready: instance=$instance_id $(grep -E '^(data_pci|data_mac|hugepages_2m|dpdk_version)=' <<<"$output" | tr '\n' ' ')"
  done
}

cmd_dpdk_verify() {
  local receiver_params source_params receiver_command source_command
  local receiver_output source_output receiver_packets source_packets
  local receiver_binary receiver_rx_timestamp
  local -a ids data_ips data_macs

  if [[ "$(cluster_lifecycle_state)" != "healthy" ]]; then
    echo "DPDK проверяется только на живом стенде с действующим TTL" >&2
    return 1
  fi
  wait_runners_ready
  mapfile -t ids < <(runner_ids)
  mapfile -t data_ips < <("${terraform_cmd[@]}" output -json runner_data_private_ips | jq -r '.[]')
  mapfile -t data_macs < <("${terraform_cmd[@]}" output -json runner_data_mac_addresses | jq -r '.[]')
  if (( ${#ids[@]} < 2 || ${#data_ips[@]} < 2 || ${#data_macs[@]} < 2 )); then
    echo "Для DPDK self-test нужны source и хотя бы один receiver" >&2
    return 1
  fi

  receiver_params="$(jq -Rs '{commands:["export DPDK_PROBE_ROLE=receiver\n" + .]}' \
    "$script_dir/dpdk-testpmd.sh")"
  source_params="$(jq -Rs \
    --arg peer_mac "${data_macs[1]}" \
    --arg source_ip "${data_ips[0]}" \
    --arg destination_ip "${data_ips[1]}" \
    '{commands:[
      "export DPDK_PROBE_ROLE=source\n" +
      "export DPDK_PEER_MAC=" + $peer_mac + "\n" +
      "export DPDK_SOURCE_IP=" + $source_ip + "\n" +
      "export DPDK_DESTINATION_IP=" + $destination_ip + "\n" + .
    ]}' "$script_dir/dpdk-testpmd.sh")"

  receiver_command="$(aws ssm send-command \
    --region "$region" --instance-ids "${ids[1]}" \
    --document-name AWS-RunShellScript --timeout-seconds 90 \
    --parameters "$receiver_params" \
    --query 'Command.CommandId' --output text)"
  source_command="$(aws ssm send-command \
    --region "$region" --instance-ids "${ids[0]}" \
    --document-name AWS-RunShellScript --timeout-seconds 90 \
    --parameters "$source_params" \
    --query 'Command.CommandId' --output text)"

  wait_command "$source_command" 1
  wait_command "$receiver_command" 1
  source_output="$(aws ssm get-command-invocation \
    --region "$region" --command-id "$source_command" \
    --instance-id "${ids[0]}" --query StandardOutputContent --output text)"
  receiver_output="$(aws ssm get-command-invocation \
    --region "$region" --command-id "$receiver_command" \
    --instance-id "${ids[1]}" --query StandardOutputContent --output text)"
  source_packets="$(awk -F= '$1 == "dpdk_probe_packets" {print $2; exit}' <<<"$source_output")"
  receiver_packets="$(awk -F= '$1 == "dpdk_probe_packets" {print $2; exit}' <<<"$receiver_output")"
  receiver_binary="$(awk -F= '$1 == "dpdk_probe_binary" {print $2; exit}' <<<"$receiver_output")"
  receiver_rx_timestamp="$(awk -F= '$1 == "dpdk_probe_rx_timestamp_capable" {print $2; exit}' <<<"$receiver_output")"
  if [[ ! "$source_packets" =~ ^[1-9][0-9]*$ ||
        ! "$receiver_packets" =~ ^[1-9][0-9]*$ ]]; then
    echo "testpmd не подтвердил ненулевой обмен пакетами" >&2
    return 1
  fi
  if [[ "$receiver_binary" != "/usr/libexec/spectral-task/bin/dpdk-testpmd" ]]; then
    echo "DPDK-проверка использовала неожиданный testpmd: $receiver_binary" >&2
    return 1
  fi
  if [[ "$receiver_rx_timestamp" != "yes" ]]; then
    echo "DPDK testpmd не подтвердил аппаратные RX timestamps" >&2
    return 1
  fi
  echo "DPDK testpmd -> testpmd пройден: source_tx=$source_packets receiver_rx=$receiver_packets rx_timestamp=yes binary=$receiver_binary source=${data_ips[0]} receiver=${data_ips[1]}"
}

cmd_dpdk_ready() {
  cmd_dpdk_prepare
  cmd_dpdk_verify
}

wait_runners_kernel() {
  local target_kernel="$1"
  local params command_id
  local -a ids

  mapfile -t ids < <(runner_ids)
  params="$(jq -nc --arg kernel "$target_kernel" '{commands:[
    "test \"$(uname -r)\" = " + $kernel
  ]}')"
  for _ in $(seq 1 10); do
    if command_id="$(aws ssm send-command \
        --region "$region" \
        --instance-ids "${ids[@]}" \
        --document-name AWS-RunShellScript \
        --timeout-seconds 60 \
        --parameters "$params" \
        --query 'Command.CommandId' --output text 2>/dev/null)" &&
      wait_command "$command_id" "${#ids[@]}" 1; then
      echo "Все runner-узлы загрузили ядро $target_kernel"
      return 0
    fi
    sleep 3
  done
  echo "Не все runner-узлы загрузили ядро $target_kernel" >&2
  return 1
}

cmd_phc_prepare() {
  local params command_id instance_id output reboot_required=false
  local -a ids

  if [[ "$(cluster_lifecycle_state)" != "healthy" ]]; then
    echo "PHC подготавливается только на живом стенде с действующим TTL" >&2
    return 1
  fi
  mapfile -t ids < <(runner_ids)
  wait_nodes_ssm "${ids[@]}"
  params="$(jq -Rs '{commands:[
    "export PHC_SCHEDULE_REBOOT=1\n" + .
  ]}' "$script_dir/phc-prepare.sh")"
  command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "${ids[@]}" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 900 \
    --parameters "$params" \
    --query 'Command.CommandId' --output text)"
  wait_command "$command_id" "${#ids[@]}"

  for instance_id in "${ids[@]}"; do
    output="$(aws ssm get-command-invocation \
      --region "$region" --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query StandardOutputContent --output text)"
    if ! grep -q '^phc_prepare_status=ready_for_reboot$' <<<"$output"; then
      echo "Узел $instance_id не подтвердил установку ENA PHC" >&2
      return 1
    fi
    if grep -q '^phc_reboot_required=yes$' <<<"$output"; then
      reboot_required=true
    fi
    echo "PHC installed: instance=$instance_id $(grep -E '^(phc_target_kernel|phc_ena_version|phc_reboot_required)=' <<<"$output" | tr '\n' ' ')"
  done

  if [[ "$reboot_required" == "true" ]]; then
    echo "Ждём плановый reboot узлов для загрузки штатного ядра с ENA PHC"
    sleep 20
  fi
  wait_runners_kernel "6.17.0-1020-aws"
}

cmd_phc_verify() {
  local params command_id instance_id output
  local -a ids

  if [[ "$(cluster_lifecycle_state)" != "healthy" ]]; then
    echo "PHC проверяется только на живом стенде с действующим TTL" >&2
    return 1
  fi
  # После bootstrap узлы перезагружаются отложенным timer. EC2 уже running,
  # но отправленная в это окно SSM-команда будет оборвана reboot-ом.
  wait_runners_ready
  mapfile -t ids < <(runner_ids)
  params="$(jq -Rs --arg max_error_ns "$max_clock_error_ns" '{commands:[
    "export MAX_CLOCK_ERROR_NS=" + $max_error_ns + "\n" + .
  ]}' "$script_dir/phc-verify.sh")"
  command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "${ids[@]}" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 120 \
    --parameters "$params" \
    --query 'Command.CommandId' --output text)"
  wait_command "$command_id" "${#ids[@]}"

  for instance_id in "${ids[@]}"; do
    output="$(aws ssm get-command-invocation \
      --region "$region" --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query StandardOutputContent --output text)"
    if ! grep -q '^phc_verify_status=ready$' <<<"$output"; then
      echo "Узел $instance_id не подтвердил точное время" >&2
      return 1
    fi
    echo "PHC ready: instance=$instance_id $(grep -E '^(phc_kernel|phc_clock_name|phc_error_bound_ns|phc_data_driver)=' <<<"$output" | tr '\n' ' ')"
  done
}

cmd_phc_ready() {
  cmd_phc_prepare
  cmd_phc_verify
}

clock_snapshot_all() {
  local phase="$1"
  local run_id="$2"
  local bucket="$3"
  local params command_id instance_id output hostname bound status
  local -a ids

  mapfile -t ids < <(runner_ids)
  params="$(jq -Rs \
    --arg max_error_ns "$max_clock_error_ns" \
    '{commands:[
      "export MAX_CLOCK_ERROR_NS=" + $max_error_ns + "\n" +
      "export REQUIRE_PHC=1\n" + .
    ]}' "$script_dir/clock-snapshot.sh")"
  command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "${ids[@]}" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 120 \
    --output-s3-bucket-name "$bucket" \
    --output-s3-key-prefix "results/$run_id/clock-$phase" \
    --parameters "$params" \
    --query 'Command.CommandId' --output text)"

  if ! wait_command "$command_id" "${#ids[@]}"; then
    echo "Проверка часов $phase не пройдена" >&2
    return 1
  fi

  for instance_id in "${ids[@]}"; do
    output="$(aws ssm get-command-invocation \
      --region "$region" --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query StandardOutputContent --output text)"
    hostname="$(awk -F= '$1 == "hostname" {print $2; exit}' <<<"$output")"
    bound="$(awk -F= '$1 == "clock_error_bound_ns" {print $2; exit}' <<<"$output")"
    status="$(awk -F= '$1 == "clock_snapshot_status" {print $2; exit}' <<<"$output")"
    if [[ ! "$bound" =~ ^[0-9]+$ || "$status" != "valid" ]]; then
      echo "Узел $instance_id вернул некорректный clock snapshot" >&2
      return 1
    fi
    case "$phase" in
      before) clock_bounds_before["$instance_id"]="$bound" ;;
      after) clock_bounds_after["$instance_id"]="$bound" ;;
      *) echo "Неизвестная фаза clock snapshot: $phase" >&2; return 2 ;;
    esac
    echo "Часы $phase: instance=$instance_id host=$hostname bound_ns=$bound status=$status"
  done
}

write_run_manifest() {
  local run_id="$1"
  local bucket="$2"
  local message_count="$3"
  local message_rate="$4"
  local receiver_count="$5"
  local warmup_ms="$6"
  local warmup_events="$7"
  local networking_backend="$8"
  local batch_wait_ns="$9"
  local batch_wait_ns_requested="${10}"
  local batch_target_frames="${11}"
  local batch_target_frames_requested="${12}"
  local batch_target_mode="${13}"
  local batch_pps_budget="${14}"
  local commit dirty package_sha placement_group sender_assembly
  local llq_probe_minimal_wire llq_probe_mixed_wire compact_wire
  local compact_wire_mixed
  local dpdk_llq_policy
  local stage_timestamps stage_timestamps_json
  local llq_probe_minimal_wire_json llq_probe_mixed_wire_json compact_wire_json
  local compact_wire_mixed_json wire_protocol
  local dpdk_rx_hardware_timestamps dpdk_rx_hardware_timestamps_json
  local dpdk_rx_burst_size dpdk_rx_free_threshold
  local clock_probe clock_probe_json
  local ids_json ips_json control_ips_json data_macs_json

  commit="$(git -C "$repo_root" rev-parse HEAD)"
  dirty=false
  if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
    dirty=true
  fi
  package_sha="$(${terraform_cmd[@]} output -raw package_sha256)"
  sender_assembly="${AWS_RUNNER_SENDER_ASSEMBLY:-copy}"
  llq_probe_minimal_wire="${AWS_RUNNER_LLQ_PROBE_MINIMAL_WIRE:-0}"
  llq_probe_mixed_wire="${AWS_RUNNER_LLQ_PROBE_MIXED_WIRE:-0}"
  compact_wire="${AWS_RUNNER_COMPACT_WIRE:-0}"
  compact_wire_mixed="${AWS_RUNNER_COMPACT_WIRE_MIXED:-0}"
  dpdk_llq_policy="${AWS_RUNNER_DPDK_LLQ_POLICY:-1}"
  if [[ "$llq_probe_minimal_wire" == "1" ]]; then
    llq_probe_minimal_wire_json=true
    wire_protocol="compact-batch-v1-llq-probe-minimal"
  else
    llq_probe_minimal_wire_json=false
    if [[ "$llq_probe_mixed_wire" == "1" ]]; then
      wire_protocol="compact-batch-v1-llq-probe-mixed"
    elif [[ "$compact_wire" == "1" ]]; then
      wire_protocol="compact-batch-v1-lossless-reserved-elided"
    elif [[ "$compact_wire_mixed" == "1" ]]; then
      wire_protocol="compact-batch-v1-lossless-reserved-elided-mixed"
    else
      wire_protocol="compact-batch-v1"
    fi
  fi
  if [[ "$llq_probe_mixed_wire" == "1" ]]; then
    llq_probe_mixed_wire_json=true
  else
    llq_probe_mixed_wire_json=false
  fi
  if [[ "$compact_wire" == "1" ]]; then
    compact_wire_json=true
  else
    compact_wire_json=false
  fi
  if [[ "$compact_wire_mixed" == "1" ]]; then
    compact_wire_mixed_json=true
  else
    compact_wire_mixed_json=false
  fi
  if [[ "$sender_assembly" != "copy" && "$sender_assembly" != "iovec" ]]; then
    echo "AWS_RUNNER_SENDER_ASSEMBLY должен быть copy или iovec" >&2
    return 2
  fi
  stage_timestamps="${AWS_RUNNER_STAGE_TIMESTAMPS:-0}"
  if [[ "$stage_timestamps" == "1" ]]; then
    stage_timestamps_json=true
  else
    stage_timestamps_json=false
  fi
  dpdk_rx_hardware_timestamps="${AWS_RUNNER_DPDK_RX_HARDWARE_TIMESTAMPS:-0}"
  if [[ "$dpdk_rx_hardware_timestamps" == "1" ]]; then
    dpdk_rx_hardware_timestamps_json=true
  else
    dpdk_rx_hardware_timestamps_json=false
  fi
  dpdk_rx_burst_size="${AWS_RUNNER_DPDK_RX_BURST_SIZE:-32}"
  dpdk_rx_free_threshold="${AWS_RUNNER_DPDK_RX_FREE_THRESHOLD:-0}"
  clock_probe="${AWS_RUNNER_CLOCK_PROBE:-0}"
  if [[ "$clock_probe" == "1" ]]; then
    clock_probe_json=true
  else
    clock_probe_json=false
  fi
  placement_group="$(${terraform_cmd[@]} output -raw precision_time_placement_group)"
  ids_json="$(${terraform_cmd[@]} output -json runner_instance_ids)"
  control_ips_json="$(${terraform_cmd[@]} output -json runner_private_ips)"
  data_macs_json='[]'
  if [[ "$networking_backend" == "dpdk" ]]; then
    ips_json="$(${terraform_cmd[@]} output -json runner_data_private_ips)"
    data_macs_json="$(${terraform_cmd[@]} output -json runner_data_mac_addresses)"
  else
    ips_json="$control_ips_json"
  fi

  jq -nc \
    --arg run_id "$run_id" \
    --arg created_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg implementation "spectral-task" \
    --arg networking_backend "$networking_backend" \
    --arg wire_protocol "$wire_protocol" \
    --arg sender_assembly "$sender_assembly" \
    --argjson batch_wait_ns "$batch_wait_ns" \
    --argjson batch_wait_ns_requested "$batch_wait_ns_requested" \
    --argjson batch_target_frames "$batch_target_frames" \
    --arg batch_target_frames_requested "$batch_target_frames_requested" \
    --arg batch_target_mode "$batch_target_mode" \
    --argjson batch_pps_budget "$batch_pps_budget" \
    --argjson llq_probe_minimal_wire "$llq_probe_minimal_wire_json" \
    --argjson llq_probe_mixed_wire "$llq_probe_mixed_wire_json" \
    --argjson compact_wire "$compact_wire_json" \
    --argjson compact_wire_mixed "$compact_wire_mixed_json" \
    --argjson dpdk_llq_policy "$dpdk_llq_policy" \
    --argjson stage_timestamps "$stage_timestamps_json" \
    --argjson dpdk_rx_hardware_timestamps "$dpdk_rx_hardware_timestamps_json" \
    --argjson dpdk_rx_burst_size "$dpdk_rx_burst_size" \
    --argjson dpdk_rx_free_threshold "$dpdk_rx_free_threshold" \
    --argjson udp_clock_probe "$clock_probe_json" \
    --arg commit "$commit" \
    --argjson dirty "$dirty" \
    --arg package_sha256 "$package_sha" \
    --arg placement_group "$placement_group" \
    --argjson runner_instance_ids "$ids_json" \
    --argjson runner_private_ips "$ips_json" \
    --argjson runner_control_private_ips "$control_ips_json" \
    --argjson runner_data_mac_addresses "$data_macs_json" \
    --argjson message_count "$message_count" \
    --argjson message_rate "$message_rate" \
    --argjson warmup_ms "$warmup_ms" \
    --argjson warmup_events "$warmup_events" \
    --argjson receiver_count "$receiver_count" \
    --argjson max_clock_error_ns "$max_clock_error_ns" \
    '{
      run_id: $run_id,
      created_at_utc: $created_at_utc,
      implementation: $implementation,
      networking_backend: $networking_backend,
      wire_protocol: $wire_protocol,
      sender_assembly: $sender_assembly,
      batch_wait_ns: $batch_wait_ns,
      batch_wait_ns_requested: $batch_wait_ns_requested,
      batch_target_frames: $batch_target_frames,
      batch_target_frames_requested: $batch_target_frames_requested,
      batch_target_mode: $batch_target_mode,
      batch_pps_budget: $batch_pps_budget,
      llq_probe_minimal_wire: $llq_probe_minimal_wire,
      llq_probe_mixed_wire: $llq_probe_mixed_wire,
      compact_wire: $compact_wire,
      compact_wire_mixed: $compact_wire_mixed,
      dpdk_llq_policy: $dpdk_llq_policy,
      stage_timestamps: $stage_timestamps,
      dpdk_rx_hardware_timestamps: $dpdk_rx_hardware_timestamps,
      dpdk_rx_burst_size: $dpdk_rx_burst_size,
      dpdk_rx_free_threshold: $dpdk_rx_free_threshold,
      stage_receive_timestamp: "software",
      stage_hardware_receive_timestamp: (if $dpdk_rx_hardware_timestamps then "dpdk-hardware-phc-calibrated-realtime" else null end),
      clock_method: "aws_ena_phc",
      udp_clock_probe: $udp_clock_probe,
      max_udp_payload_bytes: 1472,
      receiver_busy_poll_us: (if $networking_backend == "socket" then 50 else 0 end),
      commit: $commit,
      dirty: $dirty,
      package_sha256: $package_sha256,
      placement_group: $placement_group,
      runner_instance_ids: $runner_instance_ids,
      runner_private_ips: $runner_private_ips,
      runner_control_private_ips: $runner_control_private_ips,
      runner_data_mac_addresses: $runner_data_mac_addresses,
      message_count: $message_count,
      message_rate: $message_rate,
      warmup_ms: $warmup_ms,
      warmup_events: $warmup_events,
      measurement_starts_after_seq: $warmup_events,
      receiver_count: $receiver_count,
      max_clock_error_ns: $max_clock_error_ns
    }' | aws s3 cp - \
      "s3://$bucket/results/$run_id/manifest.json" \
      --region "$region" --only-show-errors
}

clock_probe_direction() {
  local phase="$1"
  local run_id="$2"
  local bucket="$3"
  local direction="$4"
  local initiator_id="$5"
  local reflector_id="$6"
  local reflector_ip="$7"
  local port=51900 count=5000 rate=5000
  local reflector_params reflector_command_id=""
  local ready_params ready_command_id stop_params stop_command_id
  local probe_params probe_command_id output offset samples lost
  local ready=0 probe_status=0 reflector_status=0 attempt

  reflector_params="$(jq -nc \
    --arg ip "$reflector_ip" \
    --arg port "$port" \
    '{commands:[
      "set -eu",
      "if pgrep -x clock_probe >/dev/null 2>&1; then " +
      "echo residual_clock_probe >&2; exit 1; fi",
      "exec /usr/bin/taskset -c 2 /usr/libexec/spectral-task/bin/clock_probe " +
      "--reflect --bind " + $ip + " --port " + $port +
      " --core 2 --idle-ms 30000"
    ]}')"
  reflector_command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "$reflector_id" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 60 \
    --output-s3-bucket-name "$bucket" \
    --output-s3-key-prefix "results/$run_id/clock-probe-$phase/$direction/reflector" \
    --parameters "$reflector_params" \
    --query 'Command.CommandId' --output text)"

  ready_params="$(jq -nc --arg port "$port" '{commands:[
    "ss -H -lun | grep -Eq \":" + $port + "[[:space:]]\""
  ]}')"
  for attempt in $(seq 1 20); do
    ready_command_id="$(aws ssm send-command \
      --region "$region" \
      --instance-ids "$reflector_id" \
      --document-name AWS-RunShellScript \
      --timeout-seconds 30 \
      --parameters "$ready_params" \
      --query 'Command.CommandId' --output text)"
    if wait_command "$ready_command_id" 1 1; then
      ready=1
      break
    fi
    sleep 1
  done

  if (( ready == 1 )); then
    probe_params="$(jq -nc \
      --arg ip "$reflector_ip" \
      --arg port "$port" \
      --arg count "$count" \
      --arg rate "$rate" \
      '{commands:[
        "set -eu",
        "exec /usr/bin/taskset -c 2 /usr/libexec/spectral-task/bin/clock_probe " +
        "--probe --peer " + $ip + " --port " + $port +
        " --count " + $count + " --rate " + $rate + " --core 2"
      ]}')"
    probe_command_id="$(aws ssm send-command \
      --region "$region" \
      --instance-ids "$initiator_id" \
      --document-name AWS-RunShellScript \
      --timeout-seconds 60 \
      --output-s3-bucket-name "$bucket" \
      --output-s3-key-prefix "results/$run_id/clock-probe-$phase/$direction/probe" \
      --parameters "$probe_params" \
      --query 'Command.CommandId' --output text)"
    wait_command "$probe_command_id" 1 || probe_status=$?
  else
    echo "Clock probe $phase/$direction: reflector не перешёл в READY" >&2
    probe_status=1
  fi

  stop_params='{"commands":["pkill -INT -x clock_probe 2>/dev/null || true"]}'
  stop_command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "$reflector_id" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 30 \
    --parameters "$stop_params" \
    --query 'Command.CommandId' --output text)"
  wait_command "$stop_command_id" 1 1 || true
  wait_command "$reflector_command_id" 1 || reflector_status=$?

  if (( probe_status != 0 || reflector_status != 0 )); then
    return 1
  fi
  output="$(aws ssm get-command-invocation \
    --region "$region" --command-id "$probe_command_id" \
    --instance-id "$initiator_id" \
    --query StandardOutputContent --output text)"
  offset="$(awk -F= '$1 == "clock_probe_offset_p50_ns" {print $2; exit}' <<<"$output")"
  samples="$(awk -F= '$1 == "clock_probe_samples" {print $2; exit}' <<<"$output")"
  lost="$(awk -F= '$1 == "clock_probe_lost" {print $2; exit}' <<<"$output")"
  if [[ ! "$offset" =~ ^-?[0-9]+$ || ! "$samples" =~ ^[0-9]+$ ||
        ! "$lost" =~ ^[0-9]+$ ]]; then
    echo "Clock probe $phase/$direction вернул неполный итог" >&2
    return 1
  fi

  clock_probe_direction_offset_ns="$offset"
  echo "Clock probe $phase/$direction: offset_ns=$offset samples=$samples lost=$lost"
}

clock_probe_bidirectional() {
  local phase="$1"
  local run_id="$2"
  local bucket="$3"
  local source_id="$4"
  local source_ip="$5"
  local receiver_id="$6"
  local receiver_ip="$7"
  local receiver_label="${8:-receiver-1}"
  local forward reverse sum absolute_sum

  clock_probe_direction "$phase" "$run_id" "$bucket" \
    "$receiver_label/source-to-receiver" \
    "$source_id" "$receiver_id" "$receiver_ip"
  forward="$clock_probe_direction_offset_ns"
  clock_probe_direction "$phase" "$run_id" "$bucket" \
    "$receiver_label/receiver-to-source" \
    "$receiver_id" "$source_id" "$source_ip"
  reverse="$clock_probe_direction_offset_ns"

  clock_probe_offset_ns="$(((forward - reverse) / 2))"
  sum=$((forward + reverse))
  absolute_sum="$sum"
  if (( absolute_sum < 0 )); then
    absolute_sum=$((-absolute_sum))
  fi
  clock_probe_disagreement_ns=$((absolute_sum / 2))

  jq -nc \
    --arg phase "$phase" \
    --argjson source_to_receiver_offset_ns "$forward" \
    --argjson receiver_to_source_offset_ns "$reverse" \
    --argjson offset_ns "$clock_probe_offset_ns" \
    --argjson direction_disagreement_ns "$clock_probe_disagreement_ns" \
    '{
      phase: $phase,
      source_to_receiver_offset_ns: $source_to_receiver_offset_ns,
      receiver_to_source_offset_ns: $receiver_to_source_offset_ns,
      offset_ns: $offset_ns,
      direction_disagreement_ns: $direction_disagreement_ns
    }' | aws s3 cp - \
      "s3://$bucket/results/$run_id/clock-probe-$phase/$receiver_label/summary.json" \
      --region "$region" --only-show-errors

  echo "Clock probe $phase/$receiver_label: source_to_receiver_offset_ns=$clock_probe_offset_ns direction_disagreement_ns=$clock_probe_disagreement_ns"
}

write_clock_bracket() {
  local run_id="$1"
  local bucket="$2"
  local before_offset="$3"
  local before_disagreement="$4"
  local after_offset="$5"
  local after_disagreement="$6"
  local source_id="$7"
  local receiver_id="$8"
  local receiver_label="${9:-receiver-1}"
  local source_before receiver_before source_after receiver_after
  local pair_before pair_after phc_uncertainty
  local drift absolute_drift max_disagreement probe_correction
  local probe_uncertainty status

  source_before="${clock_bounds_before[$source_id]:-}"
  receiver_before="${clock_bounds_before[$receiver_id]:-}"
  source_after="${clock_bounds_after[$source_id]:-}"
  receiver_after="${clock_bounds_after[$receiver_id]:-}"
  for value in "$source_before" "$receiver_before" "$source_after" "$receiver_after"; do
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
      echo "Нет корректной PHC-границы для $receiver_label" >&2
      return 1
    fi
  done
  pair_before=$((source_before + receiver_before))
  pair_after=$((source_after + receiver_after))
  phc_uncertainty="$pair_before"
  if (( pair_after > phc_uncertainty )); then
    phc_uncertainty="$pair_after"
  fi

  drift=$((after_offset - before_offset))
  absolute_drift="$drift"
  if (( absolute_drift < 0 )); then
    absolute_drift=$((-absolute_drift))
  fi
  max_disagreement="$before_disagreement"
  if (( after_disagreement > max_disagreement )); then
    max_disagreement="$after_disagreement"
  fi
  # ВАЖНО: probe идёт через kernel UDP по управляющему ENI. В DPDK-прогоне
  # полезный трафик идёт через другой ENI и обходит kernel. Поэтому эта оценка
  # годится для диагностики остаточного сдвига/асимметрии, но не для поправки
  # основной E2E-метрики. Primary всегда остаётся raw на общей ENA PHC-шкале.
  probe_correction=$(((before_offset + after_offset) / 2))
  probe_uncertainty=$((max_disagreement + absolute_drift / 2))
  status=valid
  if (( phc_uncertainty > max_clock_error_ns ||
        probe_uncertainty > max_clock_error_ns )); then
    status=invalid
  fi

  jq -nc \
    --arg method "aws_ena_phc" \
    --argjson source_before_error_bound_ns "$source_before" \
    --argjson receiver_before_error_bound_ns "$receiver_before" \
    --argjson source_after_error_bound_ns "$source_after" \
    --argjson receiver_after_error_bound_ns "$receiver_after" \
    --argjson before_pair_error_bound_ns "$pair_before" \
    --argjson after_pair_error_bound_ns "$pair_after" \
    --argjson correction_ns 0 \
    --argjson uncertainty_ns "$phc_uncertainty" \
    --argjson before_offset_ns "$before_offset" \
    --argjson before_direction_disagreement_ns "$before_disagreement" \
    --argjson after_offset_ns "$after_offset" \
    --argjson after_direction_disagreement_ns "$after_disagreement" \
    --argjson offset_drift_ns "$drift" \
    --argjson probe_correction_ns "$probe_correction" \
    --argjson probe_uncertainty_ns "$probe_uncertainty" \
    --arg status "$status" \
    '{
      method: $method,
      source_before_error_bound_ns: $source_before_error_bound_ns,
      receiver_before_error_bound_ns: $receiver_before_error_bound_ns,
      source_after_error_bound_ns: $source_after_error_bound_ns,
      receiver_after_error_bound_ns: $receiver_after_error_bound_ns,
      before_pair_error_bound_ns: $before_pair_error_bound_ns,
      after_pair_error_bound_ns: $after_pair_error_bound_ns,
      correction_ns: $correction_ns,
      uncertainty_ns: $uncertainty_ns,
      probe_method: "udp_bidirectional_probe",
      before_offset_ns: $before_offset_ns,
      before_direction_disagreement_ns: $before_direction_disagreement_ns,
      after_offset_ns: $after_offset_ns,
      after_direction_disagreement_ns: $after_direction_disagreement_ns,
      offset_drift_ns: $offset_drift_ns,
      probe_correction_ns: $probe_correction_ns,
      probe_uncertainty_ns: $probe_uncertainty_ns,
      status: $status
    }' | aws s3 cp - \
      "s3://$bucket/results/$run_id/clock-bracket-$receiver_label.json" \
      --region "$region" --only-show-errors

  echo "Clock bracket $receiver_label: PHC correction_ns=0 uncertainty_ns=$phc_uncertainty; UDP diagnostic correction_ns=$probe_correction uncertainty_ns=$probe_uncertainty status=$status"
  [[ "$status" == "valid" ]]
}

write_phc_bracket() {
  local run_id="$1"
  local bucket="$2"
  local source_id="$3"
  local receiver_id="$4"
  local receiver_label="${5:-receiver-1}"
  local source_before receiver_before source_after receiver_after
  local pair_before pair_after uncertainty status

  source_before="${clock_bounds_before[$source_id]:-}"
  receiver_before="${clock_bounds_before[$receiver_id]:-}"
  source_after="${clock_bounds_after[$source_id]:-}"
  receiver_after="${clock_bounds_after[$receiver_id]:-}"
  for value in "$source_before" "$receiver_before" "$source_after" "$receiver_after"; do
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
      echo "Нет корректной PHC-границы для $receiver_label" >&2
      return 1
    fi
  done

  # Обе системные шкалы независимо ограничены относительно AWS PHC. Поэтому
  # консервативная ошибка их разности равна сумме границ source и receiver.
  pair_before=$((source_before + receiver_before))
  pair_after=$((source_after + receiver_after))
  uncertainty="$pair_before"
  if (( pair_after > uncertainty )); then
    uncertainty="$pair_after"
  fi
  status=valid
  if (( uncertainty > max_clock_error_ns )); then
    status=invalid
  fi

  jq -nc \
    --arg method "aws_ena_phc" \
    --argjson source_before_error_bound_ns "$source_before" \
    --argjson receiver_before_error_bound_ns "$receiver_before" \
    --argjson source_after_error_bound_ns "$source_after" \
    --argjson receiver_after_error_bound_ns "$receiver_after" \
    --argjson before_pair_error_bound_ns "$pair_before" \
    --argjson after_pair_error_bound_ns "$pair_after" \
    --argjson correction_ns 0 \
    --argjson uncertainty_ns "$uncertainty" \
    --arg status "$status" \
    '{
      method: $method,
      source_before_error_bound_ns: $source_before_error_bound_ns,
      receiver_before_error_bound_ns: $receiver_before_error_bound_ns,
      source_after_error_bound_ns: $source_after_error_bound_ns,
      receiver_after_error_bound_ns: $receiver_after_error_bound_ns,
      before_pair_error_bound_ns: $before_pair_error_bound_ns,
      after_pair_error_bound_ns: $after_pair_error_bound_ns,
      correction_ns: $correction_ns,
      uncertainty_ns: $uncertainty_ns,
      status: $status
    }' | aws s3 cp - \
      "s3://$bucket/results/$run_id/clock-bracket-$receiver_label.json" \
      --region "$region" --only-show-errors

  echo "PHC bracket $receiver_label: correction_ns=0 uncertainty_ns=$uncertainty status=$status"
  [[ "$status" == "valid" ]]
}

all_instance_ids() {
  printf '%s\n' "$("${terraform_cmd[@]}" output -raw nat_instance_id)"
  runner_ids
}

wait_nodes_ssm() {
  local -a ids=("$@")
  local params command_id
  local attempt
  params='{"commands":["true"]}'
  for attempt in $(seq 1 60); do
    if ! command_id="$(aws ssm send-command \
        --region "$region" \
        --instance-ids "${ids[@]}" \
        --document-name AWS-RunShellScript \
        --timeout-seconds 30 \
        --parameters "$params" \
        --query 'Command.CommandId' --output text 2>/dev/null)"; then
      sleep 3
      continue
    fi
    if wait_command "$command_id" "${#ids[@]}" 1 3; then
      echo "Все узлы отвечают через SSM"
      return 0
    fi
    sleep 3
  done
  echo "Не все узлы стали доступны через SSM" >&2
  return 1
}

wait_runners_ready() {
  local -a ids
  local params command_id expected_sha
  local attempt max_attempts="${1:-40}"
  mapfile -t ids < <(runner_ids)
  expected_sha="$(${terraform_cmd[@]} output -raw package_sha256)"
  params="$(jq -nc --arg expected_sha "$expected_sha" '{commands:[
    "set -eu",
    "dpkg-query -W spectral-task >/dev/null",
    "test \"$(cat /var/lib/spectral-task/package.sha256)\" = \"" + $expected_sha + "\"",
    "grep -qw nohz_full=2-3 /proc/cmdline",
    "grep -qw rcu_nocbs=2-3 /proc/cmdline",
    "grep -qw irqaffinity=0-1 /proc/cmdline",
    "test \"$(cat /sys/devices/system/cpu/isolated)\" = 2-3",
    "test \"$(uname -r)\" = 6.17.0-1020-aws",
    "test -e /dev/ptp_ena",
    "test \"$(cat /sys/module/ena/parameters/phc_enable)\" = 1",
    "systemctl is-active --quiet chrony",
    "chronyc sources | grep -Eq \"^#\\*[[:space:]]+PHC\"",
    "systemctl is-active --quiet spectral-dpdk-bind.service",
    "systemctl is-active --quiet spectral-runner-ttl.timer"
  ]}')"

  for attempt in $(seq 1 "$max_attempts"); do
    if ! command_id="$(aws ssm send-command \
        --region "$region" \
        --instance-ids "${ids[@]}" \
        --document-name AWS-RunShellScript \
        --timeout-seconds 60 \
        --parameters "$params" \
        --query 'Command.CommandId' --output text 2>/dev/null)"; then
      sleep 3
      continue
    fi
    if wait_command "$command_id" "${#ids[@]}" 1 3; then
      echo "Все runner-узлы готовы: пакет, CPU isolation, ENA PHC/chrony, DPDK data ENI и TTL проверены"
      return 0
    fi
    sleep 3
  done
  echo "Runner-узлы не перешли в готовое состояние" >&2
  return 1
}

preflight_results_boundary() {
  local account_id boundary_arn version_id policy
  account_id="$(aws sts get-caller-identity --query Account --output text)"
  boundary_arn="arn:aws:iam::$account_id:policy/spectral-workload-boundary"
  version_id="$(aws iam get-policy \
    --policy-arn "$boundary_arn" \
    --query 'Policy.DefaultVersionId' --output text)"
  policy="$(aws iam get-policy-version \
    --policy-arn "$boundary_arn" \
    --version-id "$version_id" \
    --query 'PolicyVersion.Document' --output json)"
  if ! jq -e '
    any(.Statement[];
      .Effect == "Allow" and
      ((.Action == "s3:PutObject") or
       ((.Action | type) == "array" and (.Action | index("s3:PutObject")))) and
      (.Resource | tostring | contains("/results/*")))
  ' >/dev/null <<<"$policy"; then
    echo "Permissions boundary не разрешает s3:PutObject в results/*." >&2
    echo "Сначала примените infra/bootstrap под временным root-профилем." >&2
    return 1
  fi
}

cmd_up() {
  local package_path bootstrap_id ttl_id lifecycle bootstrap_enabled ttl_enabled
  local -a ids
  package_path="$(resolve_package 0)"
  validate_positive_integer AWS_RUNNER_TTL_MINUTES "$runtime_minutes"
  terraform_init

  bootstrap_enabled="$(current_bootstrap_association_enabled)"
  ttl_enabled="$(current_ttl_association_enabled)"
  lifecycle="$(cluster_lifecycle_state)"

  # Фаза 1 создаёт только сеть, EC2 и две независимые линии аварийного TTL.
  # Для протухшего или частично удалённого стенда сначала уничтожаем старые
  # associations и заменяем expires_at. Поэтому новые EC2 не могут получить
  # bootstrap до регистрации в SSM, а Scheduler не создаётся с прошлой датой.
  case "$lifecycle" in
    absent)
      terraform_apply "$package_path" "$runtime_minutes" false running false false
      bootstrap_enabled=false
      ttl_enabled=false
      ;;
    recover)
      if [[ "$(current_paused)" == "true" ]]; then
        echo "Остановленный кластер нужно запускать через make aws-cluster-start" >&2
        return 1
      fi
      echo "Восстанавливаем протухший или частично удалённый стенд через холодные фазы"
      terraform_apply "$package_path" "$runtime_minutes" false running false false \
        -replace=time_offset.expires
      bootstrap_enabled=false
      ttl_enabled=false
      ;;
    healthy)
      if [[ "$(current_paused)" == "true" || "$(current_power_state)" != "running" ]]; then
        echo "Существующий кластер нужно запускать через make aws-cluster-start" >&2
        return 1
      fi
      ;;
    *)
      echo "Фактическое состояние AWS не подтверждено; Terraform apply не запускается" >&2
      return 1
      ;;
  esac

  mapfile -t ids < <(all_instance_ids)
  wait_nodes_ssm "${ids[@]}"

  # Фаза 2 ставит пакет и kernel config на уже доступные runner targets.
  if [[ "$bootstrap_enabled" != "true" ]]; then
    terraform_apply "$package_path" "$runtime_minutes" false running true false
    bootstrap_id="$(${terraform_cmd[@]} output -raw bootstrap_association_id)"
    wait_bootstrap_execution "$bootstrap_id" ""
    wait_runners_ready
    bootstrap_enabled=true
  else
    echo "Bootstrap уже применён; повторная установка пакета и reboot не нужны"
  fi

  # Фаза 3 после reboot выдаёт новый полный TTL и синхронизирует его на всех
  # пяти доступных targets.
  if [[ "$ttl_enabled" != "true" ]]; then
    terraform_apply "$package_path" "$runtime_minutes" false running true true \
      -replace=time_offset.expires
    ttl_id="$(${terraform_cmd[@]} output -raw ttl_association_id)"
    wait_new_association_execution "$ttl_id" ""
  else
    echo "Общий TTL уже вооружён"
  fi
  wait_runners_ready
  "${terraform_cmd[@]}" output
}

cmd_update() {
  local package_path old_id association_id ttl_old_id ttl_association_id
  local current_ttl package_sha current_sha lifecycle
  terraform_init
  if [[ "$(current_paused)" == "true" ]]; then
    echo "Сначала выполните make aws-cluster-start" >&2
    return 1
  fi
  if [[ "$(current_power_state)" != "running" ]]; then
    echo "EC2 кластера не находятся в желаемом состоянии running" >&2
    return 1
  fi
  lifecycle="$(cluster_lifecycle_state)"
  case "$lifecycle" in
    absent|recover)
      echo "Обычный update неприменим к отсутствующему или протухшему стенду; запускаем восстановление"
      cmd_up
      return
      ;;
    healthy) ;;
    *)
      echo "Фактическое состояние AWS не подтверждено; Terraform apply не запускается" >&2
      return 1
      ;;
  esac
  package_path="$(resolve_package 0)"
  package_sha="$(sha256sum "$package_path" | awk '{print $1}')"
  current_sha="$(${terraform_cmd[@]} output -raw package_sha256)"
  if [[ "$package_sha" == "$current_sha" ]]; then
    echo "Пакет SHA256=$package_sha уже описан текущим Terraform state"
    association_id="$(${terraform_cmd[@]} output -raw bootstrap_association_id)"
    old_id="$(latest_association_execution "$association_id")"
    aws ssm start-associations-once \
      --region "$region" --association-ids "$association_id"
    wait_bootstrap_execution "$association_id" "$old_id"
    wait_runners_ready
    return 0
  fi
  current_ttl="$(current_runtime_minutes)"
  association_id="$(${terraform_cmd[@]} output -raw bootstrap_association_id)"
  old_id="$(latest_association_execution "$association_id")"
  ttl_association_id="$(${terraform_cmd[@]} output -raw ttl_association_id)"
  ttl_old_id="$(latest_association_execution "$ttl_association_id")"
  # Обновление пакета может включать reboot. Выдаём ему новое полное окно TTL
  # тем же apply, чтобы старый Scheduler не сработал посередине обновления.
  terraform_apply "$package_path" "$current_ttl" false running true true \
    -replace=time_offset.expires
  wait_bootstrap_execution "$association_id" "$old_id"
  wait_new_association_execution "$ttl_association_id" "$ttl_old_id"
  wait_runners_ready
}

cmd_extend() {
  local package_path association_id old_id
  if [[ "$(current_paused)" == "true" ]]; then
    echo "Paused-кластер не продлевается; используйте make aws-cluster-start" >&2
    return 1
  fi
  if [[ "$(current_power_state)" != "running" ]]; then
    echo "EC2 кластера не находятся в желаемом состоянии running" >&2
    return 1
  fi
  package_path="$(resolve_package)"
  validate_positive_integer AWS_RUNNER_TTL_MINUTES "$runtime_minutes"
  association_id="$(${terraform_cmd[@]} output -raw ttl_association_id)"
  old_id="$(latest_association_execution "$association_id")"
  terraform_init
  terraform_apply "$package_path" "$runtime_minutes" false running true true \
    -replace=time_offset.expires
  wait_new_association_execution "$association_id" "$old_id"
  echo "Новый общий TTL: $(${terraform_cmd[@]} output -raw expires_at)"
}

ensure_run_ttl() {
  local package_path requested_sha current_sha
  local expires_at expires_epoch now_epoch run_seconds required_seconds remaining_seconds

  package_path="$(resolve_package)"
  requested_sha="$(sha256sum "$package_path" | awk '{print $1}')"
  current_sha="$(${terraform_cmd[@]} output -raw package_sha256 2>/dev/null || true)"
  if [[ "$requested_sha" != "$current_sha" ]]; then
    echo "Запрошен новый пакет SHA256=$requested_sha; устанавливаем его перед прогоном"
    cmd_update
    return
  fi

  expires_at="$(${terraform_cmd[@]} output -raw expires_at 2>/dev/null || true)"
  if ! expires_epoch="$(date -u -d "$expires_at" +%s 2>/dev/null)"; then
    echo "TTL стенда не удалось проверить; безопасно продлеваем его перед прогоном"
    cmd_extend
    return
  fi

  now_epoch="$(date -u +%s)"
  run_seconds=$(((message_count + warmup_events + message_rate - 1) / message_rate))
  # Запуск через SSM, снимки часов и выгрузка результатов обычно намного
  # длиннее самого потока. Запас в десять минут не даёт таймерам выключения
  # вмешаться в тест и не задерживает каждый соседний A/B-прогон Terraform apply.
  required_seconds=$((run_seconds + 600))
  remaining_seconds=$((expires_epoch - now_epoch))
  if (( remaining_seconds < required_seconds )); then
    echo "До TTL осталось ${remaining_seconds} с, требуется не менее ${required_seconds} с; продлеваем"
    cmd_extend
  else
    echo "До TTL осталось ${remaining_seconds} с; продление перед прогоном не требуется"
  fi
}

cmd_stop() {
  local package_path ttl association_id old_id
  if [[ "$(current_paused)" == "true" ]]; then
    # Даже если сохранённый output уже равен stopped, apply обязателен: после
    # прерванного start живой EC2 мог успеть перейти в running, а output остаться
    # от предыдущего завершённого apply. Идемпотентный apply устраняет этот drift.
    package_path="$(resolve_package)"
    ttl="$(current_runtime_minutes)"
    terraform_init
    terraform_apply "$package_path" "$ttl" true stopped true true
    echo "Кластер остановлен. Compute не тарифицируется; EBS продолжает храниться."
    return 0
  fi

  # Фаза 1: на ещё работающих узлах Terraform отключает Scheduler и через SSM
  # снимает локальные timers. Фаза 2: Terraform переводит все EC2 в stopped.
  # Свежее защитное окно не даёт старому TTL сработать между этими фазами.
  cmd_extend
  package_path="$(resolve_package)"
  ttl="$(current_runtime_minutes)"
  association_id="$(${terraform_cmd[@]} output -raw ttl_association_id)"
  old_id="$(latest_association_execution "$association_id")"
  terraform_apply "$package_path" "$ttl" true running true true
  wait_new_association_execution "$association_id" "$old_id"
  terraform_apply "$package_path" "$ttl" true stopped true true
  echo "Кластер остановлен. Compute не тарифицируется; EBS продолжает храниться."
}

cmd_start() {
  local package_path association_id old_id lifecycle
  local -a ids
  if [[ "$(current_paused)" != "true" ]]; then
    # Общий TTL останавливает EC2 с самих узлов и не может обновить Terraform
    # outputs. Поэтому сохранённое желаемое состояние ещё равно running/active,
    # хотя фактически все машины уже stopped и expires_at истёк. Сверяемся с
    # AWS, а не принимаем stale output за текущее состояние.
    lifecycle="$(cluster_lifecycle_state)"
    case "$lifecycle" in
      healthy)
        echo "Кластер уже запущен"
        return 0
        ;;
      recover)
        echo "TTL уже остановил кластер; восстанавливаем те же EC2 и новый TTL"
        cmd_up
        return
        ;;
      absent)
        echo "Кластер отсутствует; используйте make aws-cluster-up" >&2
        return 1
        ;;
      *)
        echo "Фактическое состояние AWS не подтверждено; start не выполняется" >&2
        return 1
        ;;
    esac
  fi

  package_path="$(resolve_package)"
  terraform_init
  # Фаза 1 поднимает EC2, но оставляет TTL paused: stopped targets не могут
  # выполнить SSM association. После появления всех узлов в SSM фаза 2 одним
  # apply создаёт новый expires_at и вооружает обе линии аварийного завершения.
  if [[ "$(current_power_state)" == "stopped" ]]; then
    terraform_apply "$package_path" "$runtime_minutes" true running true true
  fi
  mapfile -t ids < <(all_instance_ids)
  wait_nodes_ssm "${ids[@]}"
  association_id="$(${terraform_cmd[@]} output -raw ttl_association_id)"
  old_id="$(latest_association_execution "$association_id")"
  terraform_apply "$package_path" "$runtime_minutes" false running true true \
    -replace=time_offset.expires
  wait_new_association_execution "$association_id" "$old_id"
  wait_runners_ready
  echo "Кластер запущен. Общий TTL: $(${terraform_cmd[@]} output -raw expires_at)"
}

fetch_run_artifacts() {
  local run_id="$1"
  local bucket artifact_dir encoded_archive archive_path instance_id receiver_dir
  local -a encoded_archives

  if [[ ! "$run_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Некорректный AWS_RUNNER_RUN_ID: $run_id" >&2
    return 2
  fi

  bucket="$(${terraform_cmd[@]} output -raw artifact_bucket)"
  artifact_dir="$repo_root/artifacts/aws-runner/$run_id"
  mkdir -p "$artifact_dir"
  aws s3 cp "s3://$bucket/results/$run_id" "$artifact_dir" --recursive

  mapfile -t encoded_archives < <(
    find "$artifact_dir/artifact" -type f \
      -path '*/awsrunShellScript/0.awsrunShellScript/stdout' -print 2>/dev/null
  )
  if (( ${#encoded_archives[@]} == 0 )); then
    echo "Не найдено ни одного архива SSM для run $run_id" >&2
    return 1
  fi

  if (( ${#encoded_archives[@]} == 1 )); then
    encoded_archive="${encoded_archives[0]}"
    archive_path="$artifact_dir/results.tar.gz"
    base64 --decode "$encoded_archive" >"$archive_path"
    tar -xzf "$archive_path" -C "$artifact_dir"
  else
    for encoded_archive in "${encoded_archives[@]}"; do
      instance_id="$(basename -- "$(dirname -- "$(dirname -- "$(dirname -- "$encoded_archive")")")")"
      if [[ ! "$instance_id" =~ ^i-[0-9a-f]+$ ]]; then
        echo "Не удалось определить instance id из $encoded_archive" >&2
        return 1
      fi
      receiver_dir="$artifact_dir/receivers/$instance_id"
      mkdir -p "$receiver_dir"
      archive_path="$receiver_dir/results.tar.gz"
      base64 --decode "$encoded_archive" >"$archive_path"
      tar -xzf "$archive_path" -C "$receiver_dir"
    done
  fi
  echo "Результаты run $run_id сохранены в $artifact_dir"
}

cmd_fetch() {
  local run_id="${AWS_RUNNER_RUN_ID:-}"
  local bucket listing

  if [[ -z "$(${terraform_cmd[@]} state list)" ]]; then
    echo "Кластер отсутствует: вместе с ним удалён временный artifact bucket" >&2
    return 1
  fi

  if [[ -z "$run_id" ]]; then
    bucket="$(${terraform_cmd[@]} output -raw artifact_bucket)"
    listing="$(aws s3api list-objects-v2 \
      --region "$region" \
      --bucket "$bucket" \
      --prefix 'results/' \
      --delimiter '/' \
      --output json)"
    run_id="$(jq -r '
      [.CommonPrefixes[]?.Prefix |
       capture("^results/(?<id>[^/]+)/$").id] |
      sort | last // empty
    ' <<<"$listing")"
  fi

  if [[ -z "$run_id" ]]; then
    echo "В artifact bucket ещё нет benchmark runs" >&2
    return 1
  fi
  fetch_run_artifacts "$run_id"
}

cmd_run() {
  local message_count="${AWS_RUNNER_MESSAGE_COUNT:-1000000}"
  local message_rate="${AWS_RUNNER_MESSAGE_RATE:-200000}"
  local warmup_ms="${AWS_RUNNER_WARMUP_MS:-2000}"
  local stage_timestamps="${AWS_RUNNER_STAGE_TIMESTAMPS:-0}"
  local dpdk_rx_hardware_timestamps="${AWS_RUNNER_DPDK_RX_HARDWARE_TIMESTAMPS:-0}"
  local dpdk_rx_burst_size="${AWS_RUNNER_DPDK_RX_BURST_SIZE:-32}"
  local dpdk_rx_free_threshold="${AWS_RUNNER_DPDK_RX_FREE_THRESHOLD:-0}"
  local clock_probe="${AWS_RUNNER_CLOCK_PROBE:-0}"
  local networking_backend="${AWS_RUNNER_NETWORKING_BACKEND:-socket}"
  local batch_wait_ns_requested="${AWS_RUNNER_BATCH_WAIT_NS:-1200}"
  local batch_wait_ns="$batch_wait_ns_requested"
  local batch_target_frames_requested="${AWS_RUNNER_BATCH_TARGET_FRAMES:-auto}"
  local batch_target_frames="$batch_target_frames_requested"
  local batch_target_mode="explicit"
  local batch_pps_budget="${AWS_RUNNER_BATCH_PPS_BUDGET:-2000000}"
  local llq_probe_minimal_wire="${AWS_RUNNER_LLQ_PROBE_MINIMAL_WIRE:-0}"
  local llq_probe_mixed_wire="${AWS_RUNNER_LLQ_PROBE_MIXED_WIRE:-0}"
  local compact_wire="${AWS_RUNNER_COMPACT_WIRE:-0}"
  local compact_wire_mixed="${AWS_RUNNER_COMPACT_WIRE_MIXED:-0}"
  local dpdk_llq_policy="${AWS_RUNNER_DPDK_LLQ_POLICY:-1}"
  local warmup_events
  local receiver_count="${AWS_RUNNER_RECEIVER_COUNT:-1}"
  local source_id source_ip source_network_ip bucket run_id destinations
  local destination_macs receiver_label
  local receiver_params receiver_command_id ready_params ready_command_id
  local ready_status source_params source_command_id artifact_params
  local artifact_command_id artifact_key receiver_output
  local source_status=0 receiver_status=0 clock_after_status=0
  local clock_probe_before_status=0 clock_probe_after_status=0
  local clock_bracket_status=0
  local ready=0
  local attempt index receiver_id
  local -a ids ips network_ips data_macs receiver_ids receiver_ips
  local -a receiver_network_ips receiver_data_macs
  local -a before_offsets before_disagreements
  local -a after_offsets after_disagreements

  validate_positive_integer AWS_RUNNER_MESSAGE_COUNT "$message_count"
  validate_positive_integer AWS_RUNNER_MESSAGE_RATE "$message_rate"
  validate_positive_integer AWS_RUNNER_WARMUP_MS "$warmup_ms"
  validate_positive_integer AWS_RUNNER_RECEIVER_COUNT "$receiver_count"
  if (( receiver_count < 1 || receiver_count > 3 )); then
    echo "AWS_RUNNER_RECEIVER_COUNT должен быть равен 1, 2 или 3" >&2
    return 2
  fi
  if [[ "$stage_timestamps" != "0" && "$stage_timestamps" != "1" ]]; then
    echo "AWS_RUNNER_STAGE_TIMESTAMPS должен быть равен 0 или 1" >&2
    return 2
  fi
  if [[ "$dpdk_rx_hardware_timestamps" != "0" &&
        "$dpdk_rx_hardware_timestamps" != "1" ]]; then
    echo "AWS_RUNNER_DPDK_RX_HARDWARE_TIMESTAMPS должен быть равен 0 или 1" >&2
    return 2
  fi
  if [[ ! "$dpdk_rx_burst_size" =~ ^[0-9]+$ ]] ||
    (( dpdk_rx_burst_size < 1 || dpdk_rx_burst_size > 32 )); then
    echo "AWS_RUNNER_DPDK_RX_BURST_SIZE должен быть целым числом от 1 до 32" >&2
    return 2
  fi
  if [[ ! "$dpdk_rx_free_threshold" =~ ^[0-9]+$ ]] ||
    (( dpdk_rx_free_threshold > 1023 )); then
    echo "AWS_RUNNER_DPDK_RX_FREE_THRESHOLD должен быть целым числом от 0 до 1023" >&2
    return 2
  fi
  if [[ "$clock_probe" != "0" && "$clock_probe" != "1" ]]; then
    echo "AWS_RUNNER_CLOCK_PROBE должен быть равен 0 или 1" >&2
    return 2
  fi
  if [[ "$networking_backend" != "socket" &&
        "$networking_backend" != "dpdk" ]]; then
    echo "AWS_RUNNER_NETWORKING_BACKEND должен быть socket или dpdk" >&2
    return 2
  fi
  validate_positive_integer AWS_RUNNER_BATCH_PPS_BUDGET "$batch_pps_budget"
  if [[ "$batch_target_frames_requested" == "auto" ]]; then
    if [[ "$networking_backend" == "dpdk" ]]; then
      batch_target_frames=$((
        (message_rate * receiver_count + batch_pps_budget - 1) /
        batch_pps_budget
      ))
      (( batch_target_frames < 1 )) && batch_target_frames=1
      batch_target_mode="automatic-pps-budget"
    else
      # Kernel UDP waiting was measured to hurt the tail. Keep its automatic
      # profile opportunistic even when the generic wait setting is non-zero.
      batch_target_frames=1
      batch_target_mode="automatic-no-wait"
    fi
  fi
  if [[ "$batch_target_frames" == "1" ]]; then
    batch_wait_ns=0
  fi
  if [[ "$networking_backend" != "dpdk" &&
        ("$dpdk_rx_burst_size" != "32" ||
         "$dpdk_rx_free_threshold" != "0") ]]; then
    echo "Настройки DPDK RX требуют AWS_RUNNER_NETWORKING_BACKEND=dpdk" >&2
    return 2
  fi
  if [[ "$dpdk_rx_hardware_timestamps" == "1" &&
        ("$networking_backend" != "dpdk" || "$stage_timestamps" != "1") ]]; then
    echo "Аппаратная RX-метка требует DPDK и AWS_RUNNER_STAGE_TIMESTAMPS=1" >&2
    return 2
  fi
  if [[ ! "$batch_wait_ns" =~ ^[0-9]+$ ]] ||
    (( batch_wait_ns > 1000000 )); then
    echo "AWS_RUNNER_BATCH_WAIT_NS должен быть целым числом от 0 до 1000000" >&2
    return 2
  fi
  if [[ ! "$batch_target_frames" =~ ^[0-9]+$ ]] ||
    (( batch_target_frames < 1 || batch_target_frames > 64 )); then
    echo "AWS_RUNNER_BATCH_TARGET_FRAMES должен быть целым числом от 1 до 64" >&2
    return 2
  fi
  if [[ "$llq_probe_minimal_wire" != "0" &&
        "$llq_probe_minimal_wire" != "1" ]]; then
    echo "AWS_RUNNER_LLQ_PROBE_MINIMAL_WIRE должен быть равен 0 или 1" >&2
    return 2
  fi
  if [[ "$llq_probe_minimal_wire" == "1" &&
        "$networking_backend" != "dpdk" ]]; then
    echo "AWS_RUNNER_LLQ_PROBE_MINIMAL_WIRE требует AWS_RUNNER_NETWORKING_BACKEND=dpdk" >&2
    return 2
  fi
  if [[ "$llq_probe_mixed_wire" != "0" &&
        "$llq_probe_mixed_wire" != "1" ]]; then
    echo "AWS_RUNNER_LLQ_PROBE_MIXED_WIRE должен быть равен 0 или 1" >&2
    return 2
  fi
  if [[ "$llq_probe_mixed_wire" == "1" &&
        "$networking_backend" != "dpdk" ]]; then
    echo "AWS_RUNNER_LLQ_PROBE_MIXED_WIRE требует AWS_RUNNER_NETWORKING_BACKEND=dpdk" >&2
    return 2
  fi
  if [[ "$llq_probe_minimal_wire" == "1" &&
        "$llq_probe_mixed_wire" == "1" ]]; then
    echo "Минимальный и смешанный LLQ probe нельзя включать вместе" >&2
    return 2
  fi
  if [[ "$compact_wire" != "0" && "$compact_wire" != "1" ]]; then
    echo "AWS_RUNNER_COMPACT_WIRE должен быть равен 0 или 1" >&2
    return 2
  fi
  if [[ "$compact_wire" == "1" &&
        ("$llq_probe_minimal_wire" == "1" ||
         "$llq_probe_mixed_wire" == "1") ]]; then
    echo "Рабочий compact wire и диагностический LLQ probe нельзя включать вместе" >&2
    return 2
  fi
  if [[ "$compact_wire_mixed" != "0" && "$compact_wire_mixed" != "1" ]]; then
    echo "AWS_RUNNER_COMPACT_WIRE_MIXED должен быть равен 0 или 1" >&2
    return 2
  fi
  if [[ "$compact_wire_mixed" == "1" &&
        "$networking_backend" != "dpdk" ]]; then
    echo "AWS_RUNNER_COMPACT_WIRE_MIXED требует AWS_RUNNER_NETWORKING_BACKEND=dpdk" >&2
    return 2
  fi
  if [[ ("$compact_wire" == "1" || "$compact_wire_mixed" == "1") &&
        ("$llq_probe_minimal_wire" == "1" ||
         "$llq_probe_mixed_wire" == "1") ]]; then
    echo "Рабочий compact wire и диагностический LLQ probe нельзя включать вместе" >&2
    return 2
  fi
  if [[ "$compact_wire" == "1" && "$compact_wire_mixed" == "1" ]]; then
    echo "Постоянный и смешанный compact wire нельзя включать вместе" >&2
    return 2
  fi
  if [[ ! "$dpdk_llq_policy" =~ ^[0-3]$ ]]; then
    echo "AWS_RUNNER_DPDK_LLQ_POLICY должен быть равен 0, 1, 2 или 3" >&2
    return 2
  fi
  if [[ "$dpdk_llq_policy" != "1" &&
        "$networking_backend" != "dpdk" ]]; then
    echo "AWS_RUNNER_DPDK_LLQ_POLICY требует AWS_RUNNER_NETWORKING_BACKEND=dpdk" >&2
    return 2
  fi
  warmup_events=$(((message_rate * warmup_ms + 999) / 1000))
  preflight_results_boundary
  ensure_run_ttl
  if ! wait_runners_ready 1; then
    echo "Стенд описан в Terraform, но не готов к тесту; восстанавливаем незавершённые фазы настройки"
    cmd_up
  fi

  mapfile -t ids < <(runner_ids)
  mapfile -t ips < <("${terraform_cmd[@]}" output -json runner_private_ips | jq -r '.[]')
  if [[ "$networking_backend" == "dpdk" ]]; then
    mapfile -t network_ips < <("${terraform_cmd[@]}" output -json runner_data_private_ips | jq -r '.[]')
    mapfile -t data_macs < <("${terraform_cmd[@]}" output -json runner_data_mac_addresses | jq -r '.[]')
  else
    network_ips=("${ips[@]}")
  fi
  if (( ${#ids[@]} < receiver_count + 1 || ${#ips[@]} < receiver_count + 1 )); then
    echo "В кластере недостаточно runner-узлов для $receiver_count получателей" >&2
    return 1
  fi
  if (( ${#network_ips[@]} < receiver_count + 1 )); then
    echo "В кластере недостаточно сетевых адресов для $receiver_count получателей" >&2
    return 1
  fi
  if [[ "$networking_backend" == "dpdk" ]] &&
    (( ${#data_macs[@]} < receiver_count + 1 )); then
    echo "В кластере недостаточно MAC-адресов data ENI" >&2
    return 1
  fi
  source_id="${ids[0]}"
  source_ip="${ips[0]}"
  source_network_ip="${network_ips[0]}"
  receiver_ids=("${ids[@]:1:receiver_count}")
  receiver_ips=("${ips[@]:1:receiver_count}")
  receiver_network_ips=("${network_ips[@]:1:receiver_count}")
  destinations="${receiver_network_ips[*]}"
  destination_macs=""
  if [[ "$networking_backend" == "dpdk" ]]; then
    receiver_data_macs=("${data_macs[@]:1:receiver_count}")
    destination_macs="${receiver_data_macs[*]}"
  fi
  bucket="$(${terraform_cmd[@]} output -raw artifact_bucket)"
  run_id="fanout-${networking_backend}-n${receiver_count}-$(date -u +%Y%m%dT%H%M%SZ)"
  write_run_manifest "$run_id" "$bucket" "$message_count" "$message_rate" \
    "$receiver_count" "$warmup_ms" "$warmup_events" "$networking_backend" \
    "$batch_wait_ns" "$batch_wait_ns_requested" "$batch_target_frames" \
    "$batch_target_frames_requested" "$batch_target_mode" "$batch_pps_budget"
  clock_snapshot_all before "$run_id" "$bucket"
  if [[ "$clock_probe" == "1" ]]; then
    for ((index = 0; index < receiver_count; ++index)); do
      receiver_label="receiver-$((index + 1))"
      if clock_probe_bidirectional before "$run_id" "$bucket" \
          "$source_id" "$source_ip" "${receiver_ids[index]}" \
          "${receiver_ips[index]}" "$receiver_label"; then
        before_offsets[index]="$clock_probe_offset_ns"
        before_disagreements[index]="$clock_probe_disagreement_ns"
      else
        clock_probe_before_status=1
      fi
    done
  fi

  receiver_params="$(jq -Rs \
    --arg count "$message_count" \
    --arg warmup "$warmup_events" \
    --arg stage_timestamps "$stage_timestamps" \
    --arg dpdk_rx_hardware_timestamps "$dpdk_rx_hardware_timestamps" \
    --arg dpdk_rx_burst_size "$dpdk_rx_burst_size" \
    --arg dpdk_rx_free_threshold "$dpdk_rx_free_threshold" \
    --arg networking_backend "$networking_backend" \
    '{commands:[
      "export MESSAGE_COUNT=" + $count + "\n" +
      "export WARMUP_EVENTS=" + $warmup + "\n" +
      "export STAGE_TIMESTAMPS=" + $stage_timestamps + "\n" +
      "export DPDK_RX_HARDWARE_TIMESTAMPS=" + $dpdk_rx_hardware_timestamps + "\n" +
      "export DPDK_RX_BURST_SIZE=" + $dpdk_rx_burst_size + "\n" +
      "export DPDK_RX_FREE_THRESHOLD=" + $dpdk_rx_free_threshold + "\n" +
      "export NETWORKING_BACKEND=" + $networking_backend + "\n" + .
    ]}' "$script_dir/unicast-receiver.sh")"
  receiver_command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "${receiver_ids[@]}" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 120 \
    --output-s3-bucket-name "$bucket" \
    --output-s3-key-prefix "results/$run_id/receiver" \
    --parameters "$receiver_params" \
    --query 'Command.CommandId' --output text)"

  trap 'if [[ -n "${receiver_command_id:-}" ]]; then
    aws ssm cancel-command --region "$region" \
      --command-id "$receiver_command_id" >/dev/null 2>&1 || true
  fi' EXIT

  ready_params='{"commands":["test -s /tmp/spectral-unicast/READY && cat /tmp/spectral-unicast/READY"]}'
  for attempt in $(seq 1 20); do
    ready_command_id="$(aws ssm send-command \
      --region "$region" \
      --instance-ids "${receiver_ids[@]}" \
      --document-name AWS-RunShellScript \
      --timeout-seconds 30 \
      --parameters "$ready_params" \
      --query 'Command.CommandId' --output text)"
    if wait_command "$ready_command_id" "$receiver_count" 1; then
      ready=1
      break
    fi
    sleep 1
  done
  if (( ready != 1 )); then
    echo "Receiver и consumer не перешли в READY" >&2
    return 1
  fi

  source_params="$(jq -Rs \
    --arg destinations "$destinations" \
    --arg destination_macs "$destination_macs" \
    --arg count "$message_count" \
    --arg rate "$message_rate" \
    --arg warmup "$warmup_events" \
    --arg networking_backend "$networking_backend" \
    --arg batch_wait_ns "$batch_wait_ns" \
    --arg batch_target_frames "$batch_target_frames" \
    --arg llq_probe_minimal_wire "$llq_probe_minimal_wire" \
    --arg llq_probe_mixed_wire "$llq_probe_mixed_wire" \
    --arg compact_wire "$compact_wire" \
    --arg compact_wire_mixed "$compact_wire_mixed" \
    --arg dpdk_llq_policy "$dpdk_llq_policy" \
    '{commands:[
      "export DESTINATIONS=\u0027" + $destinations + "\u0027\n" +
      "export DESTINATION_MACS=\u0027" + $destination_macs + "\u0027\n" +
      "export NETWORKING_BACKEND=" + $networking_backend + "\n" +
      "export BATCH_WAIT_NS=" + $batch_wait_ns + "\n" +
      "export BATCH_TARGET_FRAMES=" + $batch_target_frames + "\n" +
      "export LLQ_PROBE_MINIMAL_WIRE=" + $llq_probe_minimal_wire + "\n" +
      "export LLQ_PROBE_MIXED_WIRE=" + $llq_probe_mixed_wire + "\n" +
      "export COMPACT_WIRE=" + $compact_wire + "\n" +
      "export COMPACT_WIRE_MIXED=" + $compact_wire_mixed + "\n" +
      "export DPDK_LLQ_POLICY=" + $dpdk_llq_policy + "\n" +
      "export MESSAGE_COUNT=" + $count + "\n" +
      "export MESSAGE_RATE=" + $rate + "\n" +
      "export WARMUP_EVENTS=" + $warmup + "\n" + .
    ]}' "$script_dir/unicast-source.sh")"
  source_command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "$source_id" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 120 \
    --output-s3-bucket-name "$bucket" \
    --output-s3-key-prefix "results/$run_id/source" \
    --parameters "$source_params" \
    --query 'Command.CommandId' --output text)"

  wait_command "$source_command_id" 1 || source_status=$?
  wait_command "$receiver_command_id" "$receiver_count" || receiver_status=$?
  clock_snapshot_all after "$run_id" "$bucket" || clock_after_status=$?
  for ((index = 0; index < receiver_count; ++index)); do
    receiver_label="receiver-$((index + 1))"
    if [[ "$clock_probe" == "1" ]] &&
      clock_probe_bidirectional after "$run_id" "$bucket" \
        "$source_id" "$source_ip" "${receiver_ids[index]}" \
        "${receiver_ips[index]}" "$receiver_label"; then
      after_offsets[index]="$clock_probe_offset_ns"
      after_disagreements[index]="$clock_probe_disagreement_ns"
    elif [[ "$clock_probe" == "1" ]]; then
      clock_probe_after_status=1
    fi
    if [[ "$clock_probe" == "1" &&
          "${before_offsets[index]:-}" =~ ^-?[0-9]+$ &&
          "${before_disagreements[index]:-}" =~ ^[0-9]+$ &&
          "${after_offsets[index]:-}" =~ ^-?[0-9]+$ &&
          "${after_disagreements[index]:-}" =~ ^[0-9]+$ ]]; then
      if ! write_clock_bracket "$run_id" "$bucket" \
          "${before_offsets[index]}" "${before_disagreements[index]}" \
          "${after_offsets[index]}" "${after_disagreements[index]}" \
          "$source_id" "${receiver_ids[index]}" "$receiver_label"; then
        clock_bracket_status=1
      fi
    else
      if [[ "$clock_probe" == "1" ]]; then
        clock_bracket_status=1
      fi
      if ! write_phc_bracket "$run_id" "$bucket" \
          "$source_id" "${receiver_ids[index]}" "$receiver_label"; then
        clock_bracket_status=1
      fi
    fi
  done

  for ((index = 0; index < receiver_count; ++index)); do
    receiver_id="${receiver_ids[index]}"
    echo "--- receiver-$((index + 1)) instance=$receiver_id control_ip=${receiver_ips[index]} network_ip=${receiver_network_ips[index]} ---"
    receiver_output="$(aws ssm get-command-invocation \
      --region "$region" --command-id "$receiver_command_id" \
      --instance-id "$receiver_id" \
      --query StandardOutputContent --output text)"
    printf '%s\n' "$receiver_output"
  done
  echo "--- source ---"
  aws ssm get-command-invocation \
    --region "$region" --command-id "$source_command_id" \
    --instance-id "$source_id" \
    --query StandardOutputContent --output text
  receiver_command_id=""

  artifact_params='{"commands":["tar -C /tmp -czf - spectral-unicast | base64 -w 76"]}'
  artifact_command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "${receiver_ids[@]}" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 120 \
    --output-s3-bucket-name "$bucket" \
    --output-s3-key-prefix "results/$run_id/artifact" \
    --parameters "$artifact_params" \
    --query 'Command.CommandId' --output text)"
  wait_command "$artifact_command_id" "$receiver_count"

  for receiver_id in "${receiver_ids[@]}"; do
    artifact_key="results/$run_id/artifact/$artifact_command_id/$receiver_id/awsrunShellScript/0.awsrunShellScript/stdout"
    for attempt in $(seq 1 30); do
      if aws s3api head-object --region "$region" \
        --bucket "$bucket" --key "$artifact_key" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    if ! aws s3api head-object --region "$region" \
      --bucket "$bucket" --key "$artifact_key" >/dev/null 2>&1; then
      echo "SSM не записал benchmark-артефакт в s3://$bucket/$artifact_key" >&2
      return 1
    fi
  done

  fetch_run_artifacts "$run_id"
  python3 "$repo_root/scripts/summarize-fanout.py" \
    "$repo_root/artifacts/aws-runner/$run_id"
  trap - EXIT

  if (( source_status != 0 || receiver_status != 0 || clock_after_status != 0 ||
        clock_bracket_status != 0 )); then
    echo "Прогон $run_id невалиден: source=$source_status receiver=$receiver_status clock_after=$clock_after_status bracket=$clock_bracket_status" >&2
    return 1
  fi
  if (( clock_probe_before_status != 0 || clock_probe_after_status != 0 )); then
    echo "Запрошенный UDP clock-probe завершился с ошибкой: before=$clock_probe_before_status after=$clock_probe_after_status" >&2
    return 1
  fi
}

cmd_status() {
  local state resources
  state="$(${terraform_cmd[@]} state list)"
  if [[ -z "$state" ]]; then
    echo "Кластер отсутствует: Terraform state пуст"
    return
  fi
  "${terraform_cmd[@]}" output
  resources="$(aws ec2 describe-instances \
    --region "$region" \
    --filters \
      Name=tag:Project,Values=spectral-task \
      Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
    --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output json)"
  jq . <<<"$resources"
}

cmd_audit() {
  local account_id bucket_name live volumes buckets schedules associations
  local role role_json roles='[]'

  account_id="$(aws sts get-caller-identity --query Account --output text)"
  bucket_name="spectral-runner-source-$account_id-$region"
  live="$(aws ec2 describe-instances \
    --region "$region" \
    --filters \
      Name=tag:Project,Values=spectral-task \
      Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
    --query 'Reservations[].Instances[].InstanceId' --output json)"
  volumes="$(aws ec2 describe-volumes \
    --region "$region" \
    --filters Name=tag:Project,Values=spectral-task \
    --query 'Volumes[?State!=`deleted`].VolumeId' --output json)"
  buckets="$(aws s3api list-buckets --query \
    "Buckets[?Name=='$bucket_name'].Name" --output json)"
  schedules="$(aws scheduler list-schedules \
    --region "$region" \
    --name-prefix spectral-runner-expiry- \
    --query 'Schedules[].Name' --output json)"
  associations="$(aws ssm list-associations \
    --region "$region" --output json | jq '[
      .Associations[]? |
      select((.AssociationName // "") | startswith("spectral-runner-")) |
      .AssociationId
    ]')"

  for role in spectral-runner spectral-runner-nat spectral-runner-expiry; do
    if role_json="$(aws iam get-role --role-name "$role" \
        --query 'Role.RoleName' --output json 2>/dev/null)"; then
      roles="$(jq --argjson role "$role_json" '. + [$role]' <<<"$roles")"
    fi
  done

  if jq -e -n \
      --argjson live "$live" \
      --argjson volumes "$volumes" \
      --argjson buckets "$buckets" \
      --argjson schedules "$schedules" \
      --argjson associations "$associations" \
      --argjson roles "$roles" \
      '([$live, $volumes, $buckets, $schedules, $associations, $roles] |
        map(length) | add) == 0' >/dev/null; then
    echo "AWS audit чист: EC2, EBS, S3, Scheduler, SSM Associations и runner IAM roles отсутствуют"
    return 0
  fi

  echo "После destroy найдены AWS-хвосты" >&2
  jq -n \
    --argjson instances "$live" \
    --argjson volumes "$volumes" \
    --argjson buckets "$buckets" \
    --argjson schedules "$schedules" \
    --argjson associations "$associations" \
    --argjson roles "$roles" \
    '{instances:$instances, volumes:$volumes, buckets:$buckets,
      schedules:$schedules, associations:$associations, roles:$roles}' >&2
  return 1
}

cmd_down() {
  local package_path ttl paused power_state bootstrap_enabled ttl_enabled
  local availability_zone
  local -a availability_zone_args=()
  local state
  package_path="$(resolve_package)"
  ttl="$(current_runtime_minutes)"
  paused="$(current_paused)"
  power_state="$(current_power_state)"
  bootstrap_enabled="$(current_bootstrap_association_enabled)"
  ttl_enabled="$(current_ttl_association_enabled)"
  availability_zone="$(current_availability_zone)"
  if [[ -n "$availability_zone" ]]; then
    availability_zone_args=(-var="availability_zone=$availability_zone")
  fi
  run_terraform "${terraform_cmd[@]}" destroy -no-color "${approval_args[@]}" \
    -var="package_path=$package_path" \
    -var="max_runtime_minutes=$ttl" \
    -var="cluster_paused=$paused" \
    -var="cluster_power_state=$power_state" \
    -var="bootstrap_association_enabled=$bootstrap_enabled" \
    -var="ttl_association_enabled=$ttl_enabled" \
    "${availability_zone_args[@]}"

  state="$(${terraform_cmd[@]} state list)"
  if [[ -n "$state" ]]; then
    echo "Terraform state после destroy не пуст:" >&2
    printf '%s\n' "$state" >&2
    return 1
  fi
  cmd_audit
  echo "Кластер и все проверяемые AWS-ресурсы уничтожены"
}

measure_e2e_phase() {
  local label="$1"
  shift
  local started_at finished_at start_ns finish_ns duration_seconds

  started_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  start_ns="$(date +%s%N)"
  "$@"
  finish_ns="$(date +%s%N)"
  finished_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  duration_seconds="$(awk -v start="$start_ns" -v finish="$finish_ns" \
    'BEGIN { printf "%.3f", (finish - start) / 1000000000 }')"
  printf '%s\t%s\t%s\t%s\n' \
    "$label" "$started_at" "$finished_at" "$duration_seconds" \
    >>"$e2e_timings_path"
  echo "E2E $label: ${duration_seconds}s"
}

cmd_e2e() {
  local scenario_id
  scenario_id="e2e-$(date -u +%Y%m%dT%H%M%SZ)"
  e2e_timings_path="$repo_root/artifacts/aws-runner/$scenario_id/timings.tsv"
  terraform_log_dir="$repo_root/artifacts/aws-runner/$scenario_id/terraform"
  mkdir -p "$(dirname "$e2e_timings_path")"
  printf 'phase\tstarted_at\tfinished_at\tduration_seconds\n' \
    >"$e2e_timings_path"

  # Cold create измеряется с уже собранным .deb: Make выполняет prerequisite
  # deb до входа сюда. Второй fetch доказывает доступность S3 при stopped EC2.
  measure_e2e_phase down cmd_down
  measure_e2e_phase cold_create cmd_up
  measure_e2e_phase benchmark cmd_run
  measure_e2e_phase first_stop cmd_stop
  measure_e2e_phase stopped_fetch cmd_fetch
  measure_e2e_phase warm_start cmd_start
  measure_e2e_phase final_stop cmd_stop
  cmd_status
  echo "Тайминги E2E сохранены в $e2e_timings_path"
}

require_tools
validate_positive_integer AWS_RUNNER_TTL_MINUTES "$runtime_minutes"
validate_positive_integer AWS_RUNNER_MAX_CLOCK_ERROR_NS "$max_clock_error_ns"

case "${1:-}" in
  up) cmd_up ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  update) cmd_update ;;
  extend) cmd_extend ;;
  run) cmd_run ;;
  fetch) cmd_fetch ;;
  status) cmd_status ;;
  dpdk-prepare) cmd_dpdk_prepare ;;
  dpdk-verify) cmd_dpdk_verify ;;
  dpdk-ready) cmd_dpdk_ready ;;
  phc-prepare) cmd_phc_prepare ;;
  phc-verify) cmd_phc_verify ;;
  phc-ready) cmd_phc_ready ;;
  audit) cmd_audit ;;
  down) cmd_down ;;
  e2e) cmd_e2e ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
